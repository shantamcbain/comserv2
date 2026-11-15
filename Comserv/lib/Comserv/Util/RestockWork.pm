package Comserv::Util::RestockWork;
use strict;
use warnings;

# One replenishment path for both tracks.
#
# A direct sale and a consignment delivery are the same event for stock: units leave a
# location. Only an invoice *removes* stock; a consignment form *moves* it (warehouse or
# printer outfeed -> coop container) and records the delivery. Either way the rule is the
# same: replenish the location that was drawn from back up to its own minimum.
#
#   min is per (item, location) in inventory_location_levels
#   stock level is the sum of inventory_stock_levels across locations
#   a transfer is a move (two rows in inventory_transactions, no GL, total unchanged)
#   a removal below min produces print jobs (3d_printed) or an order need (bought)

my $TOLERANCE = 0.0005;

sub new {
    my ($class, %a) = @_;
    return bless { logging => $a{logging} }, $class;
}

sub _now { my @t = localtime; sprintf '%04d-%02d-%02d %02d:%02d:%02d', $t[5] + 1900, $t[4] + 1, @t[3, 2, 1, 0] }
sub _today { my @t = localtime; sprintf '%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3] }

# Minimum for this item in this container. Falls back to the item's reorder_point so a
# site that has not set per-location levels yet keeps working as it did.
sub min_for {
    my ($self, $schema, $item, $location_id) = @_;
    my $lvl = eval {
        $schema->resultset('Accounting::InventoryLocationLevel')->search(
            { item_id => $item->id, location_id => $location_id, is_active => 1 })->first;
    };
    return $lvl->min_level if $lvl;
    return $item->reorder_point || 0;
}

sub on_hand {
    my ($self, $schema, $item_id, $location_id) = @_;
    my $row = eval {
        $schema->resultset('Accounting::InventoryStockLevel')
            ->search({ item_id => $item_id, location_id => $location_id })->first;
    };
    return $row ? ($row->quantity_on_hand || 0) : 0;
}

# Surplus in other containers, above each container's own minimum — that is what may be
# pulled before anything is printed.
sub surplus_elsewhere {
    my ($self, $schema, $item, $location_id) = @_;
    my @out;
    my @rows = eval {
        $schema->resultset('Accounting::InventoryStockLevel')
            ->search({ item_id => $item->id, 'me.location_id' => { '!=' => $location_id } })->all;
    };
    for my $row (@rows) {
        my $have = $row->quantity_on_hand || 0;
        next if $have <= 0;
        my $keep = $self->min_for($schema, $item, $row->location_id);
        my $spare = $have - $keep;
        push @out, { location_id => $row->location_id, spare => $spare } if $spare > $TOLERANCE;
    }
    return sort { $b->{spare} <=> $a->{spare} } @out;
}

# What is missing in this container, and where it can come from. Pure: no writes.
sub plan {
    my ($self, $schema, $item, $location_id) = @_;
    my $min   = $self->min_for($schema, $item, $location_id);
    my $on    = $self->on_hand($schema, $item->id, $location_id);
    my $gap   = $min - $on;
    $gap = 0 if $gap < 0;

    my @pulls;
    my $left = $gap;
    if ($left > $TOLERANCE) {
        for my $s ($self->surplus_elsewhere($schema, $item, $location_id)) {
            last if $left <= $TOLERANCE;
            my $take = $s->{spare} < $left ? $s->{spare} : $left;
            push @pulls, { location_id => $s->{location_id}, qty => $take };
            $left -= $take;
        }
    }

    my $printed = (($item->item_origin || '') eq '3d_printed') ? 1 : 0;
    return {
        min        => $min,
        on_hand    => $on,
        gap        => $gap,
        pulls      => \@pulls,
        to_print   => $printed ? $left : 0,
        to_order   => $printed ? 0 : $left,
        printed    => $printed,
    };
}

# Move stock between containers. Total on hand is unchanged and no GL is written: this is
# the same physical units sitting somewhere else.
sub transfer {
    my ($self, $c, $schema, %a) = @_;
    my ($item_id, $from, $to, $qty) = @a{qw(item_id from_location_id to_location_id quantity)};
    return { ok => 0, error => 'quantity must be positive' } unless $qty && $qty > 0;
    return { ok => 0, error => 'source and destination are the same' } if $from == $to;

    my $sitename = $a{sitename} || '';
    my $now      = $self->_now;
    my $user     = $a{performed_by} || 'system';

    my $move = sub {
        my ($loc, $delta, $type) = @_;
        my $row = $schema->resultset('Accounting::InventoryStockLevel')->search(
            { item_id => $item_id, location_id => $loc })->first;
        $row ||= $schema->resultset('Accounting::InventoryStockLevel')->new({
            item_id    => $item_id,
            location_id=> $loc,
        });
        $row->quantity_on_hand(($row->quantity_on_hand || 0) + $delta);
        $row->quantity_reserved(0) unless defined $row->quantity_reserved;
        $row->quantity_on_order(0) unless defined $row->quantity_on_order;
        $row->updated_at($now);
        $row->update_or_insert;
        $schema->resultset('Accounting::InventoryTransaction')->create({
            item_id          => $item_id,
            location_id      => $loc,
            transaction_type => $type,
            quantity         => $delta,
            sitename         => $sitename,
            notes            => $a{notes} || sprintf('Transfer %s -> %s', $from, $to),
            performed_by     => $user,
            reference_number => $a{reference_number},
            transaction_date => $now,
            created_at       => $now,
        });
    };

    my $ok = eval { $move->($from, -$qty, 'transfer_out'); $move->($to, $qty, 'transfer_in'); 1 };
    return { ok => 0, error => $@ } unless $ok;
    return { ok => 1, from => $from, to => $to, quantity => $qty };
}

# Queue printed parts for the shortfall. Mirrors the shape the count apply already uses so
# the queue page, traveller and cost code see the same rows.
sub queue_prints {
    my ($self, $c, $schema, %a) = @_;
    my @jobs;
    my $now = $self->_now;
    for my $want (@{ $a{wants} || [] }) {   # [{ colour => 'blue', qty => 2 }, ...]
        next unless $want->{qty} && $want->{qty} > $TOLERANCE;
        my $job = $schema->resultset('Printing3dJob')->create({
            sitename            => $a{sitename},
            model_id            => undef,
            consignment_id      => $a{consignment_id},
            consignment_line_id => undef,
            item_name           => $a{item_name},
            user_id             => ($c->session->{user_id} || 0),
            username            => ($c->session->{username} || 'system'),
            status              => 'queued',
            quantity            => $want->{qty},
            filament_color      => $want->{colour},
            notes               => $a{notes} || 'Restock to minimum',
            inventory_reserved  => 0,
            created_at          => $now,
        });
        push @jobs, { colour => $want->{colour}, qty => $want->{qty}, job_id => $job->id };
    }
    return \@jobs;
}

# Replenish a container after units left it. Pull from other containers first, print or
# order the remainder. Colour hints (from a count) are used when present, otherwise the
# shortfall goes on one line.
sub replenish {
    my ($self, $c, $schema, %a) = @_;
    my $item = $a{item} || $schema->resultset('Accounting::InventoryItem')->find($a{item_id});
    return { ok => 0, error => 'item not found' } unless $item;

    my $p    = $self->plan($schema, $item, $a{location_id});
    my @pulls;

    if (@{ $p->{pulls} }) {
        for my $pull (@{ $p->{pulls} }) {
            my $r = $self->transfer($c, $schema,
                item_id          => $item->id,
                from_location_id => $pull->{location_id},
                to_location_id   => $a{location_id},
                quantity         => $pull->{qty},
                sitename         => $a{sitename},
                performed_by     => $a{performed_by},
                reference_number => $a{reference_number},
                notes            => $a{notes} || 'Restock from another container');
            push @pulls, $r;
        }
    }

    my @jobs;
    my $to_print = $p->{to_print};
    if ($to_print > $TOLERANCE) {
        my @wants;
        if ($a{colours} && @{ $a{colours} }) {
            # Spread the shortfall over the colours the count saw short, largest first.
            my $total = 0;
            $total += $_->{qty} for grep { $_->{qty} > 0 } @{ $a{colours} };
            if ($total > $TOLERANCE) {
                for my $hint (sort { $b->{qty} <=> $a->{qty} } grep { $_->{qty} > 0 } @{ $a{colours} }) {
                    my $share = sprintf('%.3f', $to_print * $hint->{qty} / $total);
                    push @wants, { colour => $hint->{colour}, qty => $share } if $share > $TOLERANCE;
                }
            }
        }
        @wants = ({ colour => $a{colour}, qty => $to_print }) unless @wants;
        @jobs = @{ $self->queue_prints($c, $schema,
            wants          => \@wants,
            sitename       => $a{sitename},
            item_name      => $item->name,
            consignment_id => $a{consignment_id},
            notes          => $a{notes},
        ) };
    }

    return {
        ok         => 1,
        item_id    => $item->id,
        location_id=> $a{location_id},
        min        => $p->{min},
        on_hand    => $p->{on_hand},
        gap        => $p->{gap},
        pulled     => \@pulls,
        printed    => \@jobs,
        to_order   => $p->{to_order},
    };
}

1;
