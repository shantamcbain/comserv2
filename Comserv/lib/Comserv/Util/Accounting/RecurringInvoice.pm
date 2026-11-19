package Comserv::Util::Accounting::RecurringInvoice;

use strict;
use warnings;
use utf8;

use Comserv::Util::Logging;
use Comserv::Util::AppTime;
use DateTime;

=head1 NAME

Comserv::Util::Accounting::RecurringInvoice - recurring supplier invoice schedule (INV-R1 #2190)

=head1 DESCRIPTION

A I<subscription> is a row on C<inventory_recurring_invoices> (the schedule:
supplier, line templates, cadence, payment source). When its
C<recurrence_next_date> is reached, L</run_due> clones it into a real B<draft>
row on C<inventory_supplier_invoices> (the bill) and advances the schedule.

Design notes that matter:

=over 4

=item * The generated bill is a I<draft>. Posting and GL stay a human action, exactly
like a hand-entered invoice (the user's decision on #2190).

=item * Generation is idempotent per period. C<recurrence_next_date> is advanced inside
the same transaction that creates the invoice, so a second Run Due cannot double-bill.
A schedule that is paused, ended, or has no future date generates nothing.

=item * Date arithmetic is calendar-correct: month/year steps clamp to the last day of
the target month (Jan 31 + 1 month = Feb 28/29), never roll into March.

=item * C<payment_account_id> on the schedule is the CoA account the charge is paid
FROM (bank / credit card). The generated bill records that source in its C<notes>
("paid from <accno> <description>") so accounting can see it before posting;
C<auto_pay> and C<auto_pay_method> are copied from the schedule as-is. It is a real
account id, never free text.

=back

=head1 SYNOPSIS

    my $util = Comserv::Util::Accounting::RecurringInvoice->new;

    my @subs = $util->due($schema, 'CSC');           # schedules with a date reached today
    my $res  = $util->run_due($schema, 'CSC');       # { created => [...], skipped => [...] }

=cut

sub new {
    my ($class, %args) = @_;
    return bless { %args }, $class;
}

sub logging {
    my ($self) = @_;
    return $self->{logging} ||= Comserv::Util::Logging->instance;
}

# ---------------------------------------------------------------------------
# Date arithmetic
# ---------------------------------------------------------------------------

=head2 advance_ymd

    my $next = $util->advance_ymd('2026-01-31', 'month', 1);             # 2026-02-28
    my $back = $util->advance_ymd('2026-02-28', 'month', 1, 31);         # 2026-03-31

Adds C<$interval> C<$unit>s to a C<YYYY-MM-DD> string and returns
C<YYYY-MM-DD>. Day/week steps use plain seconds; month/year steps clamp to the
last valid day of the target month. An unknown unit dies (a silent no-op here
would freeze a schedule forever).

C<$anchor_day> (optional) is the day-of-month the schedule is anchored to. Pass
it whenever you are stepping an already-clamped date: without it a 31st
schedule that clamped to Feb 28 would stay on the 28th for every later month.
With it, February clamps while longer months snap back to the 31st.

=cut

sub advance_ymd {
    my ($self, $ymd, $unit, $interval, $anchor_day) = @_;

    $ymd      = '' unless defined $ymd;
    $unit     = 'month' unless defined $unit && length $unit;
    $interval = 1 unless defined $interval && $interval =~ /^\d+$/ && $interval > 0;

    return undef unless $ymd =~ /^(\d{4})-(\d{2})-(\d{2})$/;
    my ($y, $m, $d) = ($1 + 0, $2 + 0, $3 + 0);

    if ($unit eq 'day' || $unit eq 'week') {
        my $days = $unit eq 'week' ? 7 * $interval : $interval;
        my $dt   = DateTime->new(year => $y, month => $m, day => $d, time_zone => 'UTC')
            ->add(days => $days);
        return $dt->strftime('%Y-%m-%d');
    }

    if ($unit eq 'month' || $unit eq 'year') {
        my $months = $unit eq 'year' ? 12 * $interval : $interval;
        my $want   = ($anchor_day && $anchor_day =~ /^\d+$/ && $anchor_day >= 1 && $anchor_day <= 31)
            ? $anchor_day + 0 : $d;
        my $dt = DateTime->new(year => $y, month => $m, day => 1, time_zone => 'UTC')
            ->add(months => $months);
        my $last = $dt->clone->set_day(1)->add(months => 1)->subtract(days => 1)->day;
        $dt->set_day($want > $last ? $last : $want);
        return $dt->strftime('%Y-%m-%d');
    }

    die "RecurringInvoice: unknown recurrence_unit '$unit' (expected day|week|month|year)\n";
}

=head2 today_ymd

C<YYYY-MM-DD> in UTC - the same day bucket the invoices table uses.

=cut

sub today_ymd {
    my ($self) = @_;
    return Comserv::Util::AppTime->today_utc_ymd;
}

# ---------------------------------------------------------------------------
# Query
# ---------------------------------------------------------------------------

=head2 due

    my @subs = $util->due($schema, $sitename, $as_of_ymd);

Schedules for C<$sitename> that are active, have a C<recurrence_next_date> on or
before C<$as_of> (default today), and are not past C<recurrence_end_date>.

=cut

sub due {
    my ($self, $schema, $sitename, $as_of) = @_;

    $as_of = $self->today_ymd unless defined $as_of && length $as_of;
    return () unless $schema && defined $sitename;

    my @subs = $schema->resultset('Accounting::InventoryRecurringInvoice')->search(
        {
            sitename             => $sitename,
            is_active            => 1,
            recurrence_next_date => { '<=' => $as_of },
            -or                  => [
                { recurrence_end_date => undef },
                { recurrence_end_date => { '>=' => $as_of } },
            ],
        },
        { order_by => [ 'recurrence_next_date', 'id' ] }
    )->all;

    # A schedule whose next date is past its end date is finished, not due.
    return grep {
        my $end = $_->recurrence_end_date;
        !defined($end) || $end eq '' || $end ge $as_of
    } @subs;
}

=head2 all_for_site

Every schedule for a site (active and paused), active schedules first, then by
next generate date - the list view.

=cut

sub all_for_site {
    my ($self, $schema, $sitename) = @_;
    return () unless $schema && defined $sitename;

    # 'me.sitename' is required: the prefetch joins coa_accounts and
    # inventory_suppliers, which both carry a sitename column, so a bare
    # sitename key dies with "Column 'sitename' in WHERE is ambiguous".
    return $schema->resultset('Accounting::InventoryRecurringInvoice')->search(
        { 'me.sitename' => $sitename },
        { order_by => [ { -desc => 'me.is_active' }, 'me.recurrence_next_date', 'me.id' ],
          prefetch => [ 'supplier', 'payment_account' ] }
    )->all;
}

# ---------------------------------------------------------------------------
# Generation
# ---------------------------------------------------------------------------

# Invoice number for a generated bill: "<schedule label or supplier>-YYYYMM", with
# a -2, -3 suffix if that number is already taken for the site. The unique
# constraint on inventory_supplier_invoices is (sitename, invoice_number), so a
# collision would otherwise abort the whole run.
sub _invoice_number {
    my ($self, $schema, $sitename, $sub, $ymd) = @_;

    (my $period = $ymd) =~ s/-//g;
    $period = substr($period, 0, 6);

    my $base = $sub->name || ('RECUR-' . $sub->id);
    $base =~ s/[^A-Za-z0-9._-]+/-/g;
    $base =~ s/^-+|-+$//g;
    $base = 'RECUR' unless length $base;
    $base = substr($base, 0, 40);

    my $candidate = "$base-$period";
    my $rs = $schema->resultset('Accounting::InventorySupplierInvoice');
    my $n  = 1;
    while ($rs->search({ sitename => $sitename, invoice_number => $candidate })->count) {
        $n++;
        $candidate = "$base-$period-$n";
        last if $n > 50;
    }
    return $candidate;
}

sub _line_total {
    my ($qty, $cost) = @_;
    $qty  = 0 unless defined $qty;
    $cost = 0 unless defined $cost;
    return sprintf('%.2f', $qty * $cost);
}

=head2 generate

    my $invoice = $util->generate($schema, $sub, $as_of_ymd);

Clones a schedule into one draft C<inventory_supplier_invoices> row (with its
lines) and advances the schedule. Returns the created invoice row.
Dies on any failure - the caller wraps it in a transaction.

=cut

sub generate {
    my ($self, $schema, $sub, $as_of) = @_;

    die "RecurringInvoice: no schedule given\n" unless $sub && ref $sub;
    die "RecurringInvoice: schedule has no supplier_id\n" unless $sub->supplier_id;

    my $sitename = $sub->sitename;
    my $run_date = $sub->recurrence_next_date || $as_of || $self->today_ymd;

    my $now    = Comserv::Util::AppTime->now_utc;
    my $number = $self->_invoice_number($schema, $sitename, $sub, $run_date);

    my $tax      = $sub->tax_amount      || 0;
    my $shipping = $sub->shipping_amount || 0;

    my $payment_label = '';
    if (my $pa = $sub->payment_account) {
        $payment_label = sprintf(' - paid from %s %s',
            $pa->accno // '', $pa->description // '');
    }

    my $notes = sprintf('Auto-generated by recurring schedule #%d (%s, %s)%s%s',
        $sub->id,
        $sub->name || 'subscription',
        $sub->cadence_label,
        $payment_label,
        ($sub->notes && length $sub->notes) ? "\n" . $sub->notes : '',
    );

    my $invoice = $schema->resultset('Accounting::InventorySupplierInvoice')->create({
        sitename            => $sitename,
        supplier_id         => $sub->supplier_id,
        invoice_number      => $number,
        invoice_date        => $run_date,
        due_date            => $run_date,
        ap_account_id       => $sub->ap_account_id       || undef,
        tax_account_id      => $sub->tax_account_id      || undef,
        tax_amount          => $tax,
        shipping_amount     => $shipping,
        currency            => $sub->currency || 'CAD',
        status              => 'draft',
        notes               => $notes,
        auto_pay            => $sub->auto_pay ? 1 : 0,
        auto_pay_method     => $sub->auto_pay_method || undef,
        created_by          => 'recurring-schedule#' . $sub->id,
        created_at          => $now,
        updated_at          => $now,
    });

    my $line_sum = 0;
    my $sort     = 1;
    for my $tpl ($sub->lines->all) {
        my $qty  = $tpl->quantity  || 0;
        my $cost = $tpl->unit_cost || 0;
        next unless $qty || $cost || $tpl->description;

        my $total = _line_total($qty, $cost);
        $line_sum += $total;

        $invoice->create_related('lines', {
            item_id     => $tpl->item_id     || undef,
            description => $tpl->description || undef,
            quantity    => $qty,
            unit_cost   => $cost,
            line_total  => $total,
            account_id  => $tpl->account_id  || $sub->expense_account_id || undef,
            location_id => $tpl->location_id || undef,
        });
    }

    $invoice->update({ total_amount => sprintf('%.2f', $line_sum + $tax + $shipping) });

    # Advance the schedule AFTER the invoice exists; same transaction, so a
    # failure above leaves next_date untouched and the period retryable.
    my $next = $self->advance_ymd(
        $run_date,
        $sub->recurrence_unit || 'month',
        $sub->recurrence_interval || 1,
        $self->anchor_day($sub),
    );

    $sub->update({
        recurrence_next_date => $next,
        last_run_date        => $run_date,
        last_invoice_id      => $invoice->id,
        next_amount          => sprintf('%.2f', $line_sum + $tax + $shipping),
        updated_at           => $now,
    });

    # Logging must never abort the caller's transaction: a logger die here would
    # roll back an invoice that was generated successfully.
    eval {
        $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'generate',
            sprintf('recurring #%d (%s) generated invoice id=%d number=%s for %s, next=%s',
                $sub->id, $sub->name // '', $invoice->id, $number, $run_date, $next // 'none'));
    };

    return $invoice;
}

=head2 run_due

    my $result = $util->run_due($schema, $sitename, $as_of_ymd);
    # { created => [ { schedule_id, invoice_id, invoice_number, for_date } ],
    #   skipped => [ { schedule_id, reason } ],
    #   failed  => [ { schedule_id, error } ] }

Generates every due schedule for the site, each in its own transaction so one
bad schedule cannot abort the rest of the run.

=cut

sub run_due {
    my ($self, $schema, $sitename, $as_of) = @_;

    $as_of = $self->today_ymd unless defined $as_of && length $as_of;
    my %out = (created => [], skipped => [], failed => []);

    for my $sub ($self->due($schema, $sitename, $as_of)) {
        my $guard = eval {
            $schema->txn_do(sub {
                # Re-read the schedule under a row lock before generating. Two Run Due
                # runs in flight together (the web button and the cron script) would
                # otherwise both see the same next_date and bill the period twice:
                # whoever wins the lock advances next_date, and the loser re-checks
                # against it here and skips.
                my $fresh = $schema->resultset('Accounting::InventoryRecurringInvoice')
                    ->search({ 'me.id' => $sub->id }, { for => 'update' })->single;
                die "recurring schedule " . $sub->id . " no longer exists\n" unless $fresh;
                die "recurring schedule " . $sub->id
                    . " is no longer due (another run already billed it)\n"
                    unless $fresh->is_active
                        && ($fresh->recurrence_next_date // '') le $as_of;

                my $invoice = $self->generate($schema, $fresh, $as_of);
                push @{ $out{created} }, {
                    schedule_id    => $fresh->id,
                    invoice_id     => $invoice->id,
                    invoice_number => $invoice->invoice_number,
                    for_date       => $invoice->invoice_date,
                };
            });
            1;
        };

        next if $guard;

        my $err = "$@";
        $err =~ s/\s+/ /g;
        push @{ $out{failed} }, { schedule_id => $sub->id, error => substr($err, 0, 300) };
        # log_with_details is called without a Catalyst context here (the cron script
        # has none): keep it inside an eval so a logger failure cannot abort the rest
        # of the run and leave the remaining schedules unbilled.
        eval {
            $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'run_due',
                "recurring schedule #" . $sub->id . " failed: " . substr($err, 0, 300));
        };
    }

    return \%out;
}

=head2 anchor_day

    my $day = $util->anchor_day($sub);

The day-of-month the schedule is pinned to, taken from C<recurrence_start_date>
(falling back to C<recurrence_next_date>). Stepping from an already-clamped date
without this anchor makes a 31st schedule drift to the 28th forever after its
first February.

=cut

sub anchor_day {
    my ($self, $sub) = @_;

    return undef unless $sub;
    for my $ymd ($sub->recurrence_start_date, $sub->recurrence_next_date) {
        next unless defined $ymd && $ymd =~ /^\d{4}-\d{2}-(\d{2})$/;
        return $1 + 0;
    }
    return undef;
}

=head2 preview_next

    my $ymd = $util->preview_next($sub);   # date after the pending one, for the UI

=cut

sub preview_next {
    my ($self, $sub) = @_;
    return undef unless $sub && $sub->recurrence_next_date;
    return $self->advance_ymd(
        $sub->recurrence_next_date,
        $sub->recurrence_unit || 'month',
        $sub->recurrence_interval || 1,
        $self->anchor_day($sub),
    );
}

1;
