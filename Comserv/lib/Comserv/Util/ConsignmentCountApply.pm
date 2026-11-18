package Comserv::Util::ConsignmentCountApply;

# Apply a VERIFIED consignment count to the world.
#
# One place, one transaction, four effects (in this order so a failure rolls all back):
#   1. inventory_stock_levels at the placement's location is SET to the counted total
#      (a count is a physical truth, not an increment) + last_count_date.
#   2. inventory_transactions gets a 'count_adjust' row carrying the difference, so the
#      movement is auditable against the old on-hand.
#   3. the units that left (expected - counted) become a DRAFT customer (AR) sales
#      invoice to the placement's invoice customer, at retail, less the partner's
#      commission as its own line. Never posted here - accounting posts at /Inventory/sales.
#   4. the shortfall (what must be restored to the maintained target) becomes a top-up:
#      other locations that hold the item are listed as picks, and the rest is queued as
#      Printing3dJob rows (one per colour, filament_color set).
#
# The photo is evidence only: it is deleted here once the text is applied
# (image_deleted_at records that it was removed on purpose).
#
# Colour is an attribute (count line / print job), never a separate item - see
# .hermes/plans/2026-11-05-consignment-location-count-photo.md §3.1

use strict;
use warnings;
use Try::Tiny;
use Comserv::Util::AppTime;
use Comserv::Util::ConsignmentCount qw(format_text expected_map);

our $VERSION = '1.00';

sub new {
    my ($class, %args) = @_;
    my $self = {
        logging => $args{logging} || eval { require Comserv::Util::Logging; Comserv::Util::Logging->instance },
    };
    return bless $self, $class;
}

sub _log {
    my ($self, $c, $level, $msg) = @_;
    eval {
        $self->{logging}->log_with_details($c, $level, __FILE__, __LINE__,
            'ConsignmentCountApply', $msg);
    };
    return;
}

sub _schema { my ($self, $c) = @_; return $c->model('DBEncy') }

sub _now { return Comserv::Util::AppTime->now_utc }

sub _date_today {
    my @t = localtime;
    return sprintf('%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3]);
}

sub _invoice_number {
    my ($self, $schema, $sitename) = @_;
    my $count = eval {
        $schema->resultset('Accounting::InventoryCustomerInvoice')->search({ sitename => $sitename })->count
    } || 0;
    return sprintf('INV-%s-%04d', uc(substr($sitename, 0, 4)), $count + 1);
}

# Stock available at OTHER locations for this item (for the pick-first hint).
sub other_location_stock {
    my ($self, $c, $item_id, $exclude_location_id) = @_;
    my $schema = $self->_schema($c) or return [];
    my $rows = eval {
        $schema->storage->dbh->selectall_arrayref(
            'SELECT l.id, l.name, sl.quantity_on_hand
               FROM inventory_stock_levels sl
               JOIN inventory_locations l ON l.id = sl.location_id
              WHERE sl.item_id = ? AND sl.location_id <> ?
                AND sl.quantity_on_hand > 0
              ORDER BY sl.quantity_on_hand DESC',
            { Slice => {} }, $item_id, ($exclude_location_id || 0));
    } || [];
    return [ map { { location_id => $_->{id}, name => $_->{name}, qty => $_->{quantity_on_hand} + 0 } } @$rows ];
}

# apply($c, $count_id, confirmed_text => '...' (optional re-parse), queue_prints => 1)
sub apply {
    my ($self, $c, $count_id, %opts) = @_;
    return { ok => 0, error => 'count_id required' } unless $count_id;

    my $schema = $self->_schema($c) or return { ok => 0, error => 'Database not available' };
    my $user   = $c->session->{username} || 'system';

    # NOTE: do NOT prefetch 'lines' - the relationship name collides with the SQL
    # reserved word LINES and DBIC emits an unquoted alias ("JOIN ... lines ON ..."),
    # which MariaDB rejects. Fetch the lines separately below.
    my $count = eval {
        $schema->resultset('Accounting::InventoryLocationCount')->find(
            { 'me.id' => $count_id },
            { prefetch => [qw(placement partner item)] });
    };
    return { ok => 0, error => "Count #$count_id not found" } unless $count;
    return { ok => 0, error => 'Count has already been applied' } if ($count->status // '') eq 'applied';
    return { ok => 0, error => 'Count was voided' } if ($count->status // '') eq 'void';

    my @lines = $count->lines->all;
    return { ok => 0, error => 'Count has no lines' } unless @lines;

    my $placement = $count->placement;
    my $item      = $count->item or return { ok => 0, error => 'Item missing on this count' };
    my $item_id   = $count->item_id;
    my $loc_id    = $count->location_id;
    my $sitename  = $count->sitename
                 || ($placement ? $placement->sitename : undef)
                 || eval { $c->stash->{SiteName} } || eval { $c->session->{SiteName} };
    return { ok => 0, error => 'Count has no sitename' } unless $sitename;

    my @sold  = grep { ($_->qty_delta // 0) < 0 } @lines;
    my @short = grep { ($_->qty_expected // 0) > ($_->qty_counted // 0) } @lines;
    my @pulled;   # transfers from other containers' surplus
    my $counted_total = 0;
    $counted_total += $_->qty_counted + 0 for @lines;
    my $sold_total = 0;
    $sold_total += abs($_->qty_delta) for @sold;

    my $retail = $item->unit_price || 0;
    my $commission_pct = $placement ? $placement->effective_commission_percent : 0;
    my $invoice_customer = ($placement && $placement->invoice_customer_name)
        || ($count->partner ? $count->partner->name : 'Consignment customer');

    my ($old_qty, $invoice, $invoice_number, $net_total) = (0);
    my $repl;   # replacement consignment created for the units that sold
    my (@queued, @txns);

    my $err;
    try {
        $schema->txn_do(sub {
            # ---- 1/2. stock level = counted total, auditable adjustment
            my $sl = $schema->resultset('Accounting::InventoryStockLevel')->find(
                { item_id => $item_id, location_id => $loc_id });
            if ($sl) {
                $old_qty = $sl->quantity_on_hand + 0;
                $sl->update({ quantity_on_hand => $counted_total, last_count_date => $self->_now });
            }
            else {
                $sl = $schema->resultset('Accounting::InventoryStockLevel')->create({
                    item_id           => $item_id,
                    location_id       => $loc_id,
                    quantity_on_hand  => $counted_total,
                    quantity_reserved => 0,
                    last_count_date   => $self->_now,
                });
                $old_qty = 0;
            }

            my $diff = $counted_total - $old_qty;
            if ($diff != 0) {
                my $txn = $schema->resultset('Accounting::InventoryTransaction')->create({
                    sitename         => $sitename,
                    item_id          => $item_id,
                    location_id      => $loc_id,
                    transaction_type => 'count_adjust',
                    quantity         => $diff,
                    reference_number => 'COUNT-' . $count->id,
                    notes            => sprintf('Location count #%d (%s): %s',
                                          $count->id, ($count->raw_text // 'no text'),
                                          ($count->location ? $count->location->name : "location $loc_id")),
                    performed_by     => $user,
                    transaction_date => $self->_now,
                });
                push @txns, $txn->id;
            }

            # ---- 3. draft sales invoice for the units that left
            if ($sold_total > 0 && $retail > 0) {
                $invoice_number = $self->_invoice_number($schema, $sitename);
                $invoice = $schema->resultset('Accounting::InventoryCustomerInvoice')->create({
                    sitename      => $sitename,
                    customer_name => $invoice_customer,
                    invoice_number=> $invoice_number,
                    invoice_date  => $self->_date_today,
                    tax_amount    => 0,
                    status        => 'draft',
                    notes         => sprintf('Consignment sale from location count #%d at %s (partner %s)',
                                        $count->id,
                                        ($count->location ? $count->location->name : "location $loc_id"),
                                        ($count->partner  ? $count->partner->name  : 'unknown')),
                    created_by    => $user,
                    created_at    => $self->_now,
                    updated_at    => $self->_now,
                });

                my $gross = 0;
                my $sort  = 0;
                for my $l (@sold) {
                    my $qty = abs($l->qty_delta) + 0;
                    next unless $qty > 0;
                    my $lt = $qty * $retail;
                    $gross += $lt;
                    $schema->resultset('Accounting::InventoryCustomerInvoiceLine')->create({
                        invoice_id  => $invoice->id,
                        item_id     => $item_id,
                        sku         => $item->sku,
                        item_name   => $item->name,
                        description => sprintf('%s — %s filament (consignment sale)', $item->name, $l->colour),
                        options     => sprintf('filament: %s', $l->colour),
                        quantity    => $qty,
                        unit_price  => $retail,
                        line_total  => $lt,
                        notes       => 'Count #' . $count->id,
                        sort_order  => ++$sort,
                    });
                }
                my $commission = $gross * ($commission_pct / 100);
                if ($commission > 0) {
                    $schema->resultset('Accounting::InventoryCustomerInvoiceLine')->create({
                        invoice_id  => $invoice->id,
                        item_name   => 'Consignment commission',
                        description => sprintf('%s commission at %s%%', $invoice_customer, $commission_pct),
                        quantity    => 1,
                        unit_price  => -sprintf('%.2f', $commission),
                        line_total  => -sprintf('%.2f', $commission),
                        notes       => 'Count #' . $count->id,
                        sort_order  => ++$sort,
                    });
                }
                $net_total = $gross - $commission;
                $invoice->update({ total_amount => sprintf('%.2f', $net_total) });
            }

            # ---- 3b. the sold units must go back on the shelf, so the sale opens a
            # replacement consignment. Without this the count billed the partner and
            # left consignment_id NULL: nothing to pull, print or put on a traveler.
            if ($sold_total > 0) {
                $repl = $schema->resultset('Accounting::InventoryConsignment')->create({
                    sitename         => $sitename,
                    partner_id       => $count->partner_id,
                    reference_number => sprintf('REPL-%s-%d', uc(substr($sitename, 0, 4)), $count->id),
                    date_sent        => $self->_date_today,
                    status           => 'open',
                    notes            => sprintf(
                        'Replacement after count #%d: %s %s sold at %s. Pull from stock or print, then refill the container.',
                        $count->id, $sold_total, ($item->name // 'item'),
                        ($count->location ? $count->location->name : "location $loc_id")),
                    created_by       => $user,
                    created_at       => $self->_now,
                    updated_at       => $self->_now,
                });
                $schema->resultset('Accounting::InventoryConsignmentLine')->create({
                    consignment_id    => $repl->id,
                    item_id           => $item_id,
                    quantity_sent     => $sold_total,   # units to restore to the container
                    quantity_sold     => 0,
                    quantity_returned => 0,
                    retail_price      => $retail,
                    notes             => 'Replaces stock sold in count #' . $count->id,
                    created_at        => $self->_now,
                    updated_at        => $self->_now,
                });
            }

            # ---- 4. top-up: put this container back to its own minimum.
            # The trigger is the location's minimum, not the count shortfall — a correct
            # count can still leave the container under min, and that is still work to do.
            # Units come from other containers' surplus first, then the printer. When no
            # level is configured yet the count shortfall is used, so nothing regresses.
            if ($opts{queue_prints} // 1) {
                require Comserv::Util::RestockWork;
                my $restock = Comserv::Util::RestockWork->new(logging => $self->{logging});
                my $plan    = $restock->plan($schema, $item, $loc_id);

                my @hints = map { {
                    colour => ($_->filament_color || $_->colour),
                    qty    => (($_->qty_expected + 0) - ($_->qty_counted + 0)),
                } } @short;

                if (($plan->{gap} || 0) > 0) {
                    my $rs = $restock->replenish($c, $schema,
                        item             => $item,
                        item_id          => $item_id,
                        location_id      => $loc_id,
                        sitename         => $sitename,
                        colours          => \@hints,
                        consignment_id   => ($repl ? $repl->id : $count->consignment_id),
                        performed_by     => $user,
                        reference_number => $invoice_number,
                        notes            => sprintf('Restock %s to min %s after count #%d',
                            ($count->location ? $count->location->name : "location $loc_id"),
                            $plan->{min}, $count->id),
                    );
                    push @queued, @{ $rs->{printed} || [] };
                    push @pulled, @{ $rs->{pulled} || [] };
                }
                elsif (@short) {
                    # No minimum set for this container yet: fall back to what the count missed.
                    for my $l (@short) {
                        my $qty = ($l->qty_expected + 0) - ($l->qty_counted + 0);
                        next unless $qty > 0;
                        my $job = $schema->resultset('Printing3dJob')->create({
                            sitename           => $sitename,
                            model_id           => undef,
                            consignment_id     => ($repl ? $repl->id : $count->consignment_id),
                            consignment_line_id=> undef,
                            item_name          => $item->name,
                            user_id            => $c->session->{user_id} || 0,
                            username           => $user,
                            status             => 'queued',
                            quantity           => $qty,
                            filament_color     => $l->filament_color || $l->colour,
                            notes              => sprintf('Top-up for %s after count #%d (expected %s, counted %s)',
                                                   ($count->location ? $count->location->name : "location $loc_id"),
                                                   $count->id, $l->qty_expected, $l->qty_counted),
                            inventory_reserved => 0,
                            created_at         => $self->_now,
                        });
                        push @queued, { colour => $l->colour, qty => $qty, job_id => $job->id };
                    }
                }
            }

            # ---- finish: mark applied, delete the photo (text is the record now)
            my %upd = (
                status     => 'applied',
                applied_at => $self->_now,
                invoice_id => $invoice ? $invoice->id : undef,
                updated_at => $self->_now,
            );
            $upd{consignment_id} = $repl->id if $repl;
            if (my $path = $count->image_path) {
                unlink $path if (defined $path && length $path && -f $path);
                $upd{image_deleted_at} = $self->_now;
            }
            $count->update(\%upd);
        });
    }
    catch {
        $err = $_;
    };
    if ($err) {
        $self->_log($c, 'error', "count #$count_id apply failed: $err");
        return { ok => 0, error => "Apply failed: $err" };
    }

    $self->_log($c, 'info', sprintf('count #%d applied: stock %s -> %s, sold %s, invoice %s, %d print job(s)',
        $count_id, $old_qty, $counted_total, $sold_total, ($invoice_number // '-'), scalar(@queued)));

    # Applying must not wait for someone to notice a new batch exists: the replacement
    # is work to be done, so it lands in the todo list as well as on the traveler.
    my $notify_todo = ($repl && $sold_total > 0)
        ? $self->_notify_replacement($c, $repl, $count, $item, $sold_total)
        : undef;

    return {
        ok             => 1,
        count_id       => $count_id,
        consignment_id => ($repl ? $repl->id : undef),
        todo_id        => $notify_todo,
        stock_before   => $old_qty,
        stock_after    => $counted_total,
        sold_total     => $sold_total,
        sold_lines     => [ map { { colour => $_->colour, qty => abs($_->qty_delta) } } @sold ],
        invoice_id     => $invoice ? $invoice->id : undef,
        invoice_number => $invoice_number,
        invoice_net    => $net_total,
        commission_pct => $commission_pct,
        invoice_customer => $invoice_customer,
        queued         => \@queued,
        pulled         => \@pulled,
        picks          => $self->other_location_stock($c, $item_id, $loc_id),
        message        => sprintf(
            'Count #%d applied: %s now %s (was %s).%s%s',
            $count_id,
            ($count->location ? $count->location->name : "location $loc_id"),
            $counted_total, $old_qty,
            ($sold_total ? sprintf(' %s unit(s) sold -> draft invoice %s for %s ($%.2f net after %s%% commission).',
                            $sold_total, ($invoice_number // '?'), $invoice_customer,
                            ($net_total || 0), $commission_pct) : ''),
            (@queued ? sprintf(' Top-up queued: %s.', join('; ', map { "$_->{qty} x $_->{colour}" } @queued)) : ''),
        ),
    };
}

# A replacement batch only helps if somebody acts on it. The app has no notification
# table, so the work queue is the todo list: one todo, assigned to whoever ran the
# count, that says which batch to open and where the traveler is.
sub _notify_replacement {
    my ($self, $c, $consignment, $count, $item, $qty) = @_;
    my $schema = $self->_schema($c) or return undef;
    my $todo;
    eval {
        my $project = $schema->resultset('Project')->search({ project_code => 'MCoop' })->first;
        my $next    = ($schema->resultset('Todo')->get_column('record_id')->max || 0) + 1;
        my $today   = $self->_date_today;
        my $user    = $c->session->{username} || 'system';
        # todo.user_id has an FK to users.id - a 0 or a stale session id aborts the insert.
        my $owner   = $schema->resultset('User')->search({ username => $user })->first
                   || $schema->resultset('User')->search({ username => ucfirst($user) })->first;
        die "no users row for '$user'; cannot assign the replacement todo\n" unless $owner;
        $todo = $schema->resultset('Todo')->create({
            record_id          => $next,
            sitename           => ($project ? $project->sitename : 'CSC'),
            start_date         => $today,
            due_date           => $today,
            parent_todo        => '',
            subject            => sprintf('Replace sold stock - consignment #%d', $consignment->id),
            description        => sprintf(
                "Count #%d sold %s x %s.\n\nOpen consignment #%d, pull from stock or print, then refill the container.\nTraveler: /Accounting/manufacturing/traveler_view/consignment-%d",
                $count->id, $qty, ($item ? $item->name : 'item'), $consignment->id, $consignment->id),
            estimated_man_hours => 0,
            project_code        => ($project ? $project->project_code : 'MCoop'),
            project_id          => ($project ? $project->id : 185),
            status              => 2,
            priority            => 2,
            share               => 0,
            last_mod_by         => $user,
            last_mod_date       => $today,
            group_of_poster     => ($c->session->{group} || 'admin'),
            user_id             => $owner->id,
            developer           => $user,
            username_of_poster  => $user,
            date_time_posted    => $self->_now,
        });
    };
    if ($@) {
        $self->_log($c, 'warn', 'replacement consignment #' . $consignment->id
            . ' created but the todo was not: ' . $@);
        return undef;
    }
    return $todo ? $todo->record_id : undef;
}

1;
