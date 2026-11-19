package Comserv::Controller::Accounting::Recurring;

use Moose;
use namespace::autoclean;
use DateTime;
use Comserv::Util::Logging;
use Comserv::Util::AppTime;
use Comserv::Util::Accounting::RecurringInvoice;

BEGIN { extends 'Catalyst::Controller'; }

__PACKAGE__->config(namespace => 'Accounting/recurring');

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

=head1 NAME

Comserv::Controller::Accounting::Recurring - recurring supplier invoice schedules (INV-R1 #2190)

=head1 DESCRIPTION

Thin controller: the arithmetic and generation live in
L<Comserv::Util::Accounting::RecurringInvoice>. Pages/actions here:

  GET  /Accounting/recurring              schedule list + add/edit form
  POST /Accounting/recurring/run_due      generate every due schedule as a DRAFT bill
  POST /Accounting/recurring/save         create / update a schedule
  POST /Accounting/recurring/pause/:id    stop generating (keeps history)
  POST /Accounting/recurring/resume/:id   start again
  POST /Accounting/recurring/delete/:id   remove the schedule (never the bills it made)
  POST /Accounting/recurring/from_invoice/:id  turn an existing bill into a schedule

Admin-only, same gate as Controller::Inventory.

=cut

# -------------------------------------------------------------------------
# Admin gate - mirrors Controller::Inventory::auto so both pages behave alike
# -------------------------------------------------------------------------

sub auto :Private {
    my ($self, $c) = @_;

    my $roles    = $c->session->{roles} // [];
    my $is_admin = 0;
    if (ref($roles) eq 'ARRAY') {
        $is_admin = grep { lc($_) eq 'admin' } @$roles;
    } elsif (!ref($roles) && $roles) {
        $is_admin = ($roles =~ /\badmin\b/i) ? 1 : 0;
    }
    $is_admin = 1 if $c->session->{is_admin};

    unless ($is_admin) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto',
            'Recurring invoices: access denied for user ' . ($c->session->{username} || 'guest'));
        $c->flash->{error_msg} = 'Recurring supplier invoices are restricted to administrators.';
        $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
        return 0;
    }

    # Every state-changing call here (save / run_due / pause / resume / delete /
    # from_invoice) is a plain form POST with no token, so it must be same-origin.
    # Comserv::Util::OriginCheck is the app's CSRF convention (same helper the
    # HealthKitchen POSTs use); it fails closed on absent/null/malformed Origin.
    if (($c->req->method // '') eq 'POST') {
        require Comserv::Util::OriginCheck;
        unless (Comserv::Util::OriginCheck->request_ok($c)) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto',
                'Recurring invoices: refused cross-origin POST ' . ($c->req->path // ''));
            $c->response->status(403);
            $c->res->content_type('text/plain; charset=utf-8');
            $c->res->body('Request refused (cross-site).');
            return 0;
        }
    }

    return 1;
}

# -------------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------------

sub _sitename {
    my ($self, $c) = @_;

    # The session's site is authoritative and the caller NEVER gets to choose a site.
    # A request param or X-Sitename header may only confirm it: a mismatch is logged
    # and ignored. With no session site we fall back to the site this app instance
    # runs as (config), never to client input.
    my $session_site = $c->session->{SiteName};
    $session_site = undef unless defined $session_site && length $session_site;

    my $sent = eval { $c->req->params->{sitename} } || eval { $c->req->header('X-Sitename') };
    if (defined $sent && $sent =~ /\S/) {
        $sent =~ s/^\s+|\s+$//g;
        $sent =~ s/[^A-Za-z0-9._ -]//g;
        if (length $sent && $session_site && lc $sent ne lc $session_site) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_sitename',
                "recurring invoices: site mismatch (request '$sent' vs session "
                . "'$session_site') - using the session site");
        }
    }

    return $session_site
        || $c->config->{sitename}
        || $c->config->{SiteName}
        || 'default';
}

sub _schema { return $_[1]->model('DBEncy') }

sub _now { return Comserv::Util::AppTime->now_utc }

sub _util { return Comserv::Util::Accounting::RecurringInvoice->new(logging => $_[0]->logging) }

# CoA accounts visible to this site, labelled for a <select>.
sub _account_options {
    my ($self, $c, $sitename) = @_;

    my @rows;
    eval {
        @rows = $self->_schema($c)->resultset('Accounting::CoaAccount')->search(
            [
                { sitename => $sitename, obsolete => 0 },
                { sitename => undef,     obsolete => 0 },
                { sitename => '',        obsolete => 0 },
            ],
            { order_by => 'accno' }
        )->all;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_account_options',
            "COA lookup failed: $@");
        return ();
    }

    return map { { id => $_->id, label => ($_->accno . ' ' . ($_->description // '')), category => $_->category } } @rows;
}

sub _supplier_options {
    my ($self, $c, $sitename) = @_;

    my @rows;
    eval {
        # Scoped exactly like save()'s supplier check, so the dropdown cannot offer a
        # supplier the save would then reject (and cannot leak other sites' names).
        @rows = $self->_schema($c)->resultset('Accounting::InventorySupplier')->search(
            [
                { 'me.sitename' => $sitename },
                { 'me.sitename' => undef },
                { 'me.sitename' => '' },
            ],
            { order_by => 'me.name' }
        )->all;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_supplier_options',
            "Supplier lookup failed: $@");
        return ();
    }

    return map { { id => $_->id, name => $_->name } } @rows;
}

# Is this CoA account id real, still open, and visible to this site?
sub _account_visible {
    my ($self, $c, $schema, $sitename, $id) = @_;
    return 0 unless defined $id && $id =~ /^\d+$/ && $id > 0;

    my $acc = eval {
        $schema->resultset('Accounting::CoaAccount')->search(
            [
                { 'me.id' => $id, 'me.sitename' => $sitename, 'me.obsolete' => 0 },
                { 'me.id' => $id, 'me.sitename' => undef,     'me.obsolete' => 0 },
                { 'me.id' => $id, 'me.sitename' => '',        'me.obsolete' => 0 },
            ]
        )->single;
    };
    return $acc ? 1 : 0;
}

# A real calendar date, not merely the shape of one: '2026-13-45' passes the regex
# but DateTime->new dies on it later, at generation time, leaving a schedule that
# fails on every single run.
sub _valid_ymd {
    my ($self, $v) = @_;

    return 0 unless defined $v && $v =~ /^(\d{4})-(\d{2})-(\d{2})$/;
    my ($y, $m, $d) = ($1 + 0, $2 + 0, $3 + 0);
    return 0 unless $y >= 1970 && $y <= 2200 && $m >= 1 && $m <= 12 && $d >= 1 && $d <= 31;

    my $ok = eval { DateTime->new(year => $y, month => $m, day => $d); 1 };
    return $ok ? 1 : 0;
}

# Line row indexes the form actually posted. Driving the loop from the request (not
# a hardcoded 0..2) means a schedule copied from an invoice keeps every line, and
# the editor is not capped at three.
sub _line_indexes {
    my ($self, $p) = @_;

    my %seen;
    for my $k (keys %$p) {
        $seen{$1} = 1
            if $k =~ /^line_(?:id|item_id|location_id|description|quantity|unit_cost|account_id)_(\d+)$/;
    }
    return sort { $a <=> $b } keys %seen;
}

# Build the add/edit form hash for the template.
# Every field save() persists must be here: anything missing from the form hash gets
# re-written as 0/undef on the next edit, silently changing what the schedule bills.
sub _blank_form {
    return {
        schedule_id           => '',
        name                  => '',
        supplier_id           => '',
        recurrence_unit       => 'month',
        recurrence_interval   => 1,
        recurrence_start_date => '',
        recurrence_next_date  => '',
        recurrence_end_date   => '',
        payment_account_id    => '',
        ap_account_id         => '',
        expense_account_id    => '',
        tax_account_id        => '',
        tax_amount            => '',
        shipping_amount       => '',
        auto_pay              => 0,
        auto_pay_method       => '',
        notes                 => '',
        lines                 => [ map { _blank_line() } 1 .. 3 ],
    };
}

sub _blank_line {
    return {
        line_id       => '',
        item_id       => '',
        location_id   => '',
        description   => '',
        item_quantity => '',
        unit_cost     => '',
        account_id    => '',
    };
}

sub _form_from_schedule {
    my ($self, $sub) = @_;

    my @lines = $sub->lines->search({}, { order_by => 'sort_order' })->all;
    my @rows  = map {
        {
            line_id       => $_->id,
            item_id       => $_->item_id     // '',
            location_id   => $_->location_id // '',
            description   => $_->description // '',
            item_quantity => $_->quantity    // '',
            unit_cost     => $_->unit_cost   // '',
            account_id    => $_->account_id  // '',
        }
    } @lines;
    push @rows, map { _blank_line() } (scalar(@rows) + 1) .. 3 if @rows < 3;

    return {
        schedule_id           => $sub->id,
        name                  => $sub->name // '',
        supplier_id           => $sub->supplier_id // '',
        recurrence_unit       => $sub->recurrence_unit // 'month',
        recurrence_interval   => $sub->recurrence_interval || 1,
        recurrence_start_date => $sub->recurrence_start_date // '',
        recurrence_next_date  => $sub->recurrence_next_date // '',
        recurrence_end_date   => $sub->recurrence_end_date // '',
        payment_account_id    => $sub->payment_account_id // '',
        ap_account_id         => $sub->ap_account_id // '',
        expense_account_id    => $sub->expense_account_id // '',
        tax_account_id        => $sub->tax_account_id // '',
        tax_amount            => $sub->tax_amount // '',
        shipping_amount       => $sub->shipping_amount // '',
        auto_pay              => $sub->auto_pay ? 1 : 0,
        auto_pay_method       => $sub->auto_pay_method // '',
        notes                 => $sub->notes // '',
        lines                 => \@rows,
    };
}

# -------------------------------------------------------------------------
# GET /Accounting/recurring
# -------------------------------------------------------------------------

sub index :Path('/Accounting/recurring') :Args(0) {
    my ($self, $c) = @_;

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);
    my $util     = $self->_util;
    my $today    = Comserv::Util::AppTime->today_utc_ymd;

    my (@subs, @schedules);
    eval { @subs = $util->all_for_site($schema, $sitename) };
    if (my $err = $@) {
        # Capture $@ before logging: log_with_details runs its own evals and
        # would otherwise clobber it, leaving a blank error on the page.
        $err =~ s/\s+/ /g;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index',
            'Schedule lookup failed: ' . substr($err, 0, 400));
        $c->stash->{error_msg} = 'Could not load recurring schedules. If this is a fresh '
            . 'install, create the recurring invoice tables from Admin > Schema Compare first.';
    }

    my $due_count = 0;

    # One grouped count for the whole page instead of a lines->count per schedule
    # (the list was issuing an extra query for every row).
    my %line_counts;
    if (@subs) {
        eval {
            my $rs = $schema->resultset('Accounting::InventoryRecurringInvoiceLine')->search(
                { 'me.recurring_invoice_id' => { -in => [ map { $_->id } @subs ] } },
                {
                    select   => [ 'me.recurring_invoice_id', { count => 'me.id' } ],
                    as       => [ 'rid', 'cnt' ],
                    group_by => 'me.recurring_invoice_id',
                }
            );
            %line_counts = map { $_->rid => $_->cnt } $rs->all;
        };
    }

    for my $sub (@subs) {
        my $next = $sub->recurrence_next_date || '';
        my $end  = $sub->recurrence_end_date  || '';
        my $is_due = ($sub->is_active && $next && $next le $today
            && (!$end || $end ge $today)) ? 1 : 0;
        $due_count++ if $is_due;

        my $payment_label = '';
        if (my $pa = eval { $sub->payment_account }) {
            $payment_label = join(' ', grep { defined && length } $pa->accno, $pa->description);
        }

        my $supplier_name = '';
        if (my $sup = eval { $sub->supplier }) {
            $supplier_name = $sup->name // '';
        }

        push @schedules, {
            id              => $sub->id,
            name            => $sub->name // '',
            supplier_name   => $supplier_name,
            cadence         => $sub->cadence_label,
            next_date       => $next,
            next_preview    => $util->preview_next($sub) // '',
            end_date        => $end,
            is_active       => $sub->is_active ? 1 : 0,
            is_due          => $is_due,
            auto_pay        => $sub->auto_pay ? 1 : 0,
            auto_pay_method => $sub->auto_pay_method // '',
            payment_label   => $payment_label,
            next_amount     => $sub->next_amount // '',
            line_count      => $line_counts{ $sub->id } || 0,
            last_invoice_id => $sub->last_invoice_id // '',
            last_run_date   => $sub->last_run_date // '',
            notes           => $sub->notes // '',
        };
    }

    my $form    = $self->_blank_form;
    # save() sets stash->{editing} before re-rendering a failed validation; keep it.
    my $editing = defined $c->stash->{editing} ? $c->stash->{editing} : 0;
    if (my $edit_id = $c->req->query_parameters->{edit}) {
        my $sub;
        eval {
            $sub = $schema->resultset('Accounting::InventoryRecurringInvoice')
                ->search({ id => $edit_id, sitename => $sitename })->single;
        };
        if ($sub) {
            $form    = $self->_form_from_schedule($sub);
            $editing = 1;
        } else {
            $c->stash->{error_msg} = "Recurring schedule $edit_id not found for this site.";
        }
    }

    # A validation failure re-renders with the submitted values instead of the blank form.
    if ($c->stash->{submitted_form}) {
        $form = $c->stash->{submitted_form};
    }

    $c->stash(
        schedules   => \@schedules,
        due_count   => $due_count,
        today       => $today,
        accounts    => [ $self->_account_options($c, $sitename) ],
        suppliers   => [ $self->_supplier_options($c, $sitename) ],
        form        => $form,
        editing     => $editing,
        sitename    => $sitename,
        template    => 'Accounting/recurring/index.tt',
    );
}

# -------------------------------------------------------------------------
# POST /Accounting/recurring/save
# -------------------------------------------------------------------------

sub save :Path('/Accounting/recurring/save') :Args(0) {
    my ($self, $c) = @_;

    unless (($c->req->method // '') eq 'POST') {
        return $c->response->redirect($c->uri_for('/Accounting/recurring'));
    }

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);
    my $p        = $c->req->body_parameters;
    my $now      = $self->_now;

    my @errors;
    push @errors, 'A name is required.'    unless ($p->{name} // '') =~ /\S/;
    push @errors, 'A supplier is required.' unless ($p->{supplier_id} // '') =~ /^\d+$/;

    my $unit = $p->{recurrence_unit} || 'month';
    push @errors, "Unknown cadence unit '$unit'."
        unless $unit =~ /^(?:day|week|month|year)$/;

    my $interval = $p->{recurrence_interval} || 1;
    push @errors, 'Interval must be a whole number between 1 and 99.'
        unless $interval =~ /^\d+$/ && $interval >= 1 && $interval <= 99;

    my $start_date = $p->{recurrence_start_date} || '';
    push @errors, 'Start date must be a real date (YYYY-MM-DD).'
        if length $start_date && !$self->_valid_ymd($start_date);

    my $next_date = $p->{recurrence_next_date} || $start_date || '';
    push @errors, 'A next generate date is required.' unless length $next_date;
    push @errors, 'Next generate date must be a real date (YYYY-MM-DD).'
        if length $next_date && !$self->_valid_ymd($next_date);

    my $end_date = $p->{recurrence_end_date} || '';
    push @errors, 'End date must be a real date (YYYY-MM-DD).'
        if length $end_date && !$self->_valid_ymd($end_date);
    push @errors, 'End date cannot be before the next generate date.'
        if length $end_date && $self->_valid_ymd($end_date)
            && $self->_valid_ymd($next_date) && $end_date lt $next_date;

    # The payment source must be a REAL asset account (bank / credit card) that is
    # visible to this site - same rule the other accounts go through, so a schedule
    # cannot point at another site's bank account.
    my $payment_account_id = $p->{payment_account_id} || undef;
    if ($payment_account_id) {
        if (!$self->_account_visible($c, $schema, $sitename, $payment_account_id)) {
            push @errors, 'Payment source account is not a valid account for this site.';
        } else {
            my $pa = eval {
                $schema->resultset('Accounting::CoaAccount')->find($payment_account_id);
            };
            push @errors, 'Payment source must be an asset account (bank or credit card), not '
                . (($pa && ($pa->category_label // $pa->category)) || 'that category') . '.'
                unless $pa && ($pa->category // '') eq 'A';
        }
    }

    # Money fields are numbers, not free text: they are summed into next_amount below.
    for my $field (qw(tax_amount shipping_amount)) {
        my $v = $p->{$field};
        next unless defined $v && $v =~ /\S/;
        unless ($v =~ /^\d{1,9}(?:\.\d{1,4})?$/) {
            (my $label = $field) =~ s/_/ /g;
            push @errors, ucfirst($label) . ' must be a number, e.g. 12.34.';
        }
    }

    # The supplier and the accounting accounts must exist and be visible to this
    # site - an id from the form is untrusted input, not a guarantee.
    if (($p->{supplier_id} // '') =~ /^\d+$/) {
        my $sup = eval {
            $schema->resultset('Accounting::InventorySupplier')->search(
                [
                    { 'me.id' => $p->{supplier_id}, 'me.sitename' => $sitename },
                    { 'me.id' => $p->{supplier_id}, 'me.sitename' => undef },
                    { 'me.id' => $p->{supplier_id}, 'me.sitename' => '' },
                ]
            )->single;
        };
        push @errors, 'Supplier not found for this site.' unless $sup;
    }

    for my $field (qw(expense_account_id ap_account_id tax_account_id)) {
        my $v = $p->{$field};
        next unless defined $v && $v =~ /\S/;
        next if $self->_account_visible($c, $schema, $sitename, $v);
        (my $label = $field) =~ s/_/ /g;
        push @errors, ucfirst($label) . ' is not a valid account for this site.';
    }

    for my $i ($self->_line_indexes($p)) {
        my $acc = $p->{"line_account_id_$i"};
        next unless defined $acc && $acc =~ /\S/;
        next if $self->_account_visible($c, $schema, $sitename, $acc);
        push @errors, 'Line account is not a valid account for this site.';
        last;
    }

    if (@errors) {
        $c->stash->{error_msg} = join(' ', @errors);
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'save',
            'recording schedule rejected: ' . join(' ', @errors));

        my $form = $self->_blank_form;
        for my $k (qw(schedule_id name supplier_id recurrence_unit recurrence_interval
                      recurrence_start_date recurrence_next_date recurrence_end_date
                      payment_account_id ap_account_id expense_account_id tax_account_id
                      tax_amount shipping_amount auto_pay auto_pay_method notes)) {
            $form->{$k} = $p->{$k} if defined $p->{$k};
        }
        my @line_rows = map {
            {
                line_id       => $p->{"line_id_$_"}          // '',
                item_id       => $p->{"line_item_id_$_"}     // '',
                location_id   => $p->{"line_location_id_$_"} // '',
                description   => $p->{"line_description_$_"} // '',
                item_quantity => $p->{"line_quantity_$_"}    // '',
                unit_cost     => $p->{"line_unit_cost_$_"}   // '',
                account_id    => $p->{"line_account_id_$_"}  // '',
            }
        } $self->_line_indexes($p);
        $form->{lines} = \@line_rows if @line_rows;
        $c->stash->{submitted_form} = $form;
        $c->stash->{editing}        = $p->{schedule_id} ? 1 : 0;

        return $self->index($c);
    }

    my ($saved, $err);
    eval {
        $schema->txn_do(sub {
            my %attrs = (
                sitename              => $sitename,
                supplier_id           => $p->{supplier_id},
                name                  => $p->{name},
                notes                 => $p->{notes},
                expense_account_id    => $p->{expense_account_id} || undef,
                ap_account_id         => $p->{ap_account_id}      || undef,
                payment_account_id    => $payment_account_id,
                tax_account_id        => $p->{tax_account_id}     || undef,
                tax_amount            => $p->{tax_amount}         || 0,
                shipping_amount       => $p->{shipping_amount}    || 0,
                recurrence_unit       => $unit,
                recurrence_interval   => $interval,
                recurrence_start_date => $p->{recurrence_start_date} || $next_date,
                recurrence_next_date  => $next_date,
                recurrence_end_date   => length $end_date ? $end_date : undef,
                auto_pay              => $p->{auto_pay} ? 1 : 0,
                auto_pay_method       => $p->{auto_pay_method} || undef,
                updated_at            => $now,
            );

            # is_active is only touched when the form sends it: editing a paused
            # schedule must not silently resume it (Resume is its own action).
            $attrs{is_active} = ($p->{is_active} ? 1 : 0) if defined $p->{is_active};

            my $rs = $schema->resultset('Accounting::InventoryRecurringInvoice');
            my $sub;
            if ($p->{schedule_id} && $p->{schedule_id} =~ /^\d+$/) {
                $sub = $rs->search({ id => $p->{schedule_id}, sitename => $sitename })->single;
                die "Schedule $p->{schedule_id} not found for site $sitename\n" unless $sub;
                $sub->update(\%attrs);
            } else {
                $attrs{is_active} = 1 unless defined $attrs{is_active};
                $sub = $rs->create({ %attrs, created_by => $c->session->{username} || 'system', created_at => $now });
            }

            # The form owns the line text, but a row it re-sends keeps the item and
            # location it points at (hidden fields), and only rows the form no longer
            # carries are deleted: an invoice copied in by from_invoice must not lose
            # its items or its 4th+ lines just because somebody edited the schedule.
            my @idx      = $self->_line_indexes($p);
            my %keep;
            my $line_sum = 0;
            my $sort     = 1;
            for my $i (@idx) {
                my $desc = $p->{"line_description_$i"} // '';
                my $qty  = $p->{"line_quantity_$i"}    // '';
                my $cost = $p->{"line_unit_cost_$i"}   // '';
                next unless $desc =~ /\S/ || $cost =~ /\d/;

                $qty  = 1 unless $qty  =~ /^\d+(?:\.\d+)?$/;
                $cost = 0 unless $cost =~ /^\d+(?:\.\d+)?$/;
                $line_sum += $qty * $cost;

                my %line = (
                    description => $desc,
                    quantity    => $qty,
                    unit_cost   => $cost,
                    account_id  => $p->{"line_account_id_$i"} || undef,
                    sort_order  => $sort++,
                );
                for my $f (qw(item_id location_id)) {
                    my $v = $p->{"line_${f}_$i"};
                    $line{$f} = ($v // '') =~ /^\d+$/ ? $v + 0 : undef;
                }

                my $line_id  = $p->{"line_id_$i"} // '';
                my $existing = $line_id =~ /^\d+$/
                    ? $sub->lines->search({ id => $line_id })->single
                    : undef;
                if ($existing) {
                    $existing->update(\%line);
                    $keep{ $existing->id } = 1;
                } else {
                    my $created = $sub->create_related('lines', \%line);
                    $keep{ $created->id } = 1;
                }
            }

            my @gone = grep { !$keep{$_} } map { $_->id } $sub->lines->all;
            $sub->lines->search({ id => { -in => \@gone } })->delete if @gone;

            $sub->update({
                next_amount => sprintf('%.2f',
                    $line_sum + ($p->{tax_amount} || 0) + ($p->{shipping_amount} || 0)),
            });

            $saved = $sub;
        });
    };
    $err = $@;

    if ($err) {
        $err =~ s/\s+/ /g;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'save',
            "saving recurring schedule failed: " . substr($err, 0, 400));
        $c->flash->{error_msg} = 'Could not save the recurring schedule - see the error log '
            . '(system_log) for details.';
    } else {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'save',
            sprintf('recurring schedule #%d saved for site %s (cadence %s %s, next %s, payment_account %s)',
                $saved->id, $sitename, $unit, $interval, $next_date, $payment_account_id // 'none'));
        $c->flash->{success_msg} = sprintf('Recurring schedule #%d saved (%s, next generate %s).',
            $saved->id, $saved->cadence_label, $next_date);
    }

    $c->response->redirect($c->uri_for('/Accounting/recurring'));
}

# -------------------------------------------------------------------------
# POST /Accounting/recurring/run_due
# -------------------------------------------------------------------------

sub run_due :Path('/Accounting/recurring/run_due') :Args(0) {
    my ($self, $c) = @_;

    unless (($c->req->method // '') eq 'POST') {
        return $c->response->redirect($c->uri_for('/Accounting/recurring'));
    }

    my $sitename = $self->_sitename($c);
    my $res;

    eval { $res = $self->_util->run_due($self->_schema($c), $sitename) };
    if ($@) {
        my $err = "$@";
        $err =~ s/\s+/ /g;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'run_due',
            "run_due aborted: " . substr($err, 0, 400));
        $c->flash->{error_msg} = 'Run Due failed - see the error log (system_log) for details.';
        return $c->response->redirect($c->uri_for('/Accounting/recurring'));
    }

    my $created = scalar @{ $res->{created} || [] };
    my $failed  = scalar @{ $res->{failed}  || [] };

    if ($created) {
        $c->flash->{success_msg} = sprintf(
            'Generated %d draft invoice%s: %s. Review and post them in %s.',
            $created,
            $created == 1 ? '' : 's',
            join(', ', map { $_->{invoice_number} } @{ $res->{created} }),
            '/Inventory/invoice',
        );
    } else {
        $c->flash->{success_msg} = 'Nothing was due.';
    }

    if ($failed) {
        $c->flash->{error_msg} = sprintf(
            '%d schedule%s failed to generate - see the error log (system_log) for details.',
            $failed, $failed == 1 ? '' : 's',
        );
    }

    $c->response->redirect($c->uri_for('/Accounting/recurring'));
}

# -------------------------------------------------------------------------
# POST /Accounting/recurring/pause|resume|delete/:id, from_invoice/:id
# -------------------------------------------------------------------------

sub _load_schedule {
    my ($self, $c, $id) = @_;

    my $sitename = $self->_sitename($c);
    my $sub = eval {
        $self->_schema($c)->resultset('Accounting::InventoryRecurringInvoice')
            ->search({ id => $id, sitename => $sitename })->single;
    };

    unless ($sub) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_load_schedule',
            "schedule $id not found for site $sitename");
        $c->flash->{error_msg} = "Recurring schedule $id not found for this site.";
        return;
    }
    return $sub;
}

sub pause :Path('/Accounting/recurring/pause') :Args(1) {
    my ($self, $c, $id) = @_;
    return $c->response->redirect($c->uri_for('/Accounting/recurring'))
        unless ($c->req->method // '') eq 'POST';

    my $sub = $self->_load_schedule($c, $id) or return $c->response->redirect($c->uri_for('/Accounting/recurring'));

    eval { $sub->update({ is_active => 0, updated_at => $self->_now }) };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'pause', "pause #$id failed: $@");
        $c->flash->{error_msg} = "Could not pause schedule $id.";
    } else {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'pause', "schedule #$id paused");
        $c->flash->{success_msg} = "Schedule #$id paused - no further invoices will be generated.";
    }
    $c->response->redirect($c->uri_for('/Accounting/recurring'));
}

sub resume :Path('/Accounting/recurring/resume') :Args(1) {
    my ($self, $c, $id) = @_;
    return $c->response->redirect($c->uri_for('/Accounting/recurring'))
        unless ($c->req->method // '') eq 'POST';

    my $sub = $self->_load_schedule($c, $id) or return $c->response->redirect($c->uri_for('/Accounting/recurring'));

    my $today = Comserv::Util::AppTime->today_utc_ymd;
    my %set   = (is_active => 1, updated_at => $self->_now);
    # A schedule resumed with no next date has nowhere to run from - start today.
    $set{recurrence_next_date} = $today
        unless ($sub->recurrence_next_date // '') =~ /^\d{4}-\d{2}-\d{2}$/;

    eval { $sub->update(\%set) };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'resume', "resume #$id failed: $@");
        $c->flash->{error_msg} = "Could not resume schedule $id.";
    } else {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'resume',
            "schedule #$id resumed, next_date=" . ($set{recurrence_next_date} // $sub->recurrence_next_date));
        $c->flash->{success_msg} = "Schedule #$id resumed.";
    }
    $c->response->redirect($c->uri_for('/Accounting/recurring'));
}

sub delete_schedule :Path('/Accounting/recurring/delete') :Args(1) {
    my ($self, $c, $id) = @_;
    return $c->response->redirect($c->uri_for('/Accounting/recurring'))
        unless ($c->req->method // '') eq 'POST';

    my $sub = $self->_load_schedule($c, $id) or return $c->response->redirect($c->uri_for('/Accounting/recurring'));

    # Only the schedule and its line templates go. Invoices it already created
    # are real AP history and must survive - last_invoice_id is informational.
    eval {
        $self->_schema($c)->txn_do(sub { $sub->delete });
    };
    if ($@) {
        my $err = "$@";
        $err =~ s/\s+/ /g;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'delete_schedule',
            "delete #$id failed: " . substr($err, 0, 300));
        $c->flash->{error_msg} = "Could not delete schedule $id.";
    } else {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete_schedule',
            "schedule #$id deleted (generated invoices kept)");
        $c->flash->{success_msg} = "Schedule #$id deleted. Invoices it already generated are untouched.";
    }
    $c->response->redirect($c->uri_for('/Accounting/recurring'));
}

# Turn an existing supplier invoice into a schedule: copies supplier, accounts,
# lines and auto-pay so the first generated bill matches the one on screen.
sub from_invoice :Path('/Accounting/recurring/from_invoice') :Args(1) {
    my ($self, $c, $invoice_id) = @_;
    return $c->response->redirect($c->uri_for('/Accounting/recurring'))
        unless ($c->req->method // '') eq 'POST';

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);
    my $util     = $self->_util;

    # No prefetch here: prefetching the has_many 'lines' makes single() die with
    # "resultsets collapsing a has_many" - load the invoice, then its lines lazily.
    my $invoice = eval {
        $schema->resultset('Accounting::InventorySupplierInvoice')
            ->search({ id => $invoice_id, sitename => $sitename })->single;
    };
    if (my $err = $@) {
        $err =~ s/\s+/ /g;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'from_invoice',
            "invoice $invoice_id lookup failed: " . substr($err, 0, 300));
    }
    unless ($invoice) {
        $c->flash->{error_msg} = "Invoice $invoice_id not found for this site.";
        return $c->response->redirect($c->uri_for('/Accounting/recurring'));
    }

    my $created;
    eval {
        $schema->txn_do(sub {
            my $start = $invoice->invoice_date
                || Comserv::Util::AppTime->today_utc_ymd;
            my $next = $util->advance_ymd($start, 'month', 1);

            my $sub = $schema->resultset('Accounting::InventoryRecurringInvoice')->create({
                sitename             => $sitename,
                supplier_id          => $invoice->supplier_id,
                name                 => 'Recurring: ' . ($invoice->invoice_number || ('invoice #' . $invoice->id)),
                notes                => 'Created from supplier invoice #' . $invoice->id,
                ap_account_id        => $invoice->ap_account_id,
                tax_account_id       => $invoice->tax_account_id,
                tax_amount           => $invoice->tax_amount || 0,
                shipping_amount      => $invoice->shipping_amount || 0,
                currency             => $invoice->currency || 'CAD',
                recurrence_unit      => 'month',
                recurrence_interval  => 1,
                recurrence_start_date => $start,
                recurrence_next_date => $next,
                is_active            => 1,
                auto_pay             => $invoice->auto_pay ? 1 : 0,
                auto_pay_method      => $invoice->auto_pay_method,
                created_by           => $c->session->{username} || 'system',
                created_at           => $self->_now,
                updated_at           => $self->_now,
            });

            my $sum  = 0;
            my $sort = 1;
            for my $line ($invoice->lines->all) {
                $sum += $line->line_total || 0;
                $sub->create_related('lines', {
                    item_id     => $line->item_id,
                    description => $line->description,
                    quantity    => $line->quantity  || 1,
                    unit_cost   => $line->unit_cost || 0,
                    account_id  => $line->account_id,
                    location_id => $line->location_id,
                    sort_order  => $sort++,
                });
            }
            $sub->update({ next_amount => sprintf('%.2f', $sum + ($invoice->tax_amount || 0) + ($invoice->shipping_amount || 0)) });
            $created = $sub;
        });
    };

    if ($@) {
        my $err = "$@";
        $err =~ s/\s+/ /g;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'from_invoice',
            "from_invoice $invoice_id failed: " . substr($err, 0, 400));
        $c->flash->{error_msg} = 'Could not create the schedule from this invoice.';
    } else {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'from_invoice',
            "schedule #" . $created->id . " created from invoice #$invoice_id");
        $c->flash->{success_msg} = "Schedule #" . $created->id
            . " created from invoice " . ($invoice->invoice_number || $invoice_id)
            . " - set the payment source, then review the cadence.";
    }

    $c->response->redirect($c->uri_for('/Accounting/recurring'));
}

1;
