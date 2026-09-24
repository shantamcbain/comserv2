package Comserv::Util::Inventory::Purchasing;

use strict;
use warnings;
use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use Comserv::Util::Logging;
use Comserv::Util::AppTime;

=head1 NAME

Comserv::Util::Inventory::Purchasing - need list + purchase orders

=head1 DESCRIPTION

BOM shortfall → buy vs print. Purchase-order rows live in
InventoryPurchaseOrder (schema-compare). Does not grow Controller::Inventory.

=cut

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub _now_date {
    return Comserv::Util::AppTime->today_utc_ymd;
}

sub _now {
    return Comserv::Util::AppTime->now_utc;
}

# Returns { ok, parent_sku, buy => [], print => [], unassigned => [] }
sub need_list {
    my ($self, $c, $p) = @_;
    $p ||= {};
    my $inv = $c->controller('Inventory');
    my $bom = $inv->_list_bom_lines($c, $p);
    return $bom unless $bom->{ok};

    my $schema = $c->model('DBEncy');
    my (@buy, @print);
    for my $line (@{ $bom->{lines} || [] }) {
        my $need = ($line->{quantity} || 0) * (1 + ($line->{scrap_factor} || 0));
        my $avail = $line->{available} || 0;
        my $short = $need - $avail;
        next if $short <= 0 && !$line->{is_optional};

        my $origin = lc($line->{item_origin} || '');
        my $bucket = ($origin =~ /print/) ? 'print' : 'buy';
        my $row = {
            %$line,
            need      => $need,
            shortfall => $short > 0 ? $short : 0,
            bucket    => $bucket,
        };

        if ($bucket eq 'buy' && $line->{component_item_id}) {
            my $link;
            try {
                $link = $schema->resultset('Accounting::InventoryItemSupplier')->search(
                    { item_id => $line->{component_item_id} },
                    { order_by => { -desc => 'is_preferred' }, rows => 1, prefetch => 'supplier' }
                )->first;
            } catch {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'need_list',
                    "item_supplier lookup failed item=$line->{component_item_id}: $_");
            };
            if ($link) {
                $row->{supplier_id}   = $link->supplier_id;
                $row->{supplier_name} = eval { $link->supplier->name } || undef;
                $row->{supplier_sku}  = $link->supplier_sku;
                $row->{unit_cost}     = $link->unit_cost;
                $row->{is_preferred}  = $link->is_preferred ? 1 : 0;
            }
        }

        if ($bucket eq 'print') {
            push @print, $row;
        } else {
            push @buy, $row;
        }
    }

    my %by_sup;
    my @unassigned;
    for my $row (@buy) {
        if ($row->{supplier_id}) {
            push @{ $by_sup{ $row->{supplier_id} }{lines} }, $row;
            $by_sup{ $row->{supplier_id} }{supplier_id}   = $row->{supplier_id};
            $by_sup{ $row->{supplier_id} }{supplier_name} = $row->{supplier_name};
        } else {
            push @unassigned, $row;
        }
    }

    return {
        ok          => 1,
        parent_id   => $bom->{parent_id},
        parent_sku  => $bom->{parent_sku},
        parent_name => $bom->{parent_name},
        buy         => \@buy,
        print       => \@print,
        by_supplier => [ values %by_sup ],
        unassigned  => \@unassigned,
    };
}

sub create_po {
    my ($self, $c, $p) = @_;
    $p ||= {};
    my $schema   = $c->model('DBEncy');
    my $sitename = $p->{sitename} or return { ok => 0, error => 'sitename required' };
    my $supplier_id = $p->{supplier_id} or return { ok => 0, error => 'supplier_id required' };
    my $lines = $p->{lines};
    return { ok => 0, error => 'lines required' } unless $lines && ref($lines) eq 'ARRAY' && @$lines;

    my $fail;
    my $po;
    try {
        $schema->txn_do(sub {
            $po = $schema->resultset('Accounting::InventoryPurchaseOrder')->create({
                sitename              => $sitename,
                supplier_id           => $supplier_id,
                status                => 'draft',
                origin                => $p->{origin} || 'internal',
                source_parent_item_id => $p->{source_parent_item_id} || undef,
                order_date            => $p->{order_date} || _now_date(),
                notes                 => $p->{notes},
                created_by            => $c->session->{username} || 'hermes-agent',
                created_at            => _now(),
                updated_at            => _now(),
            });
            my $num = $p->{po_number} || sprintf('PO-%s-%04d', uc(substr($sitename, 0, 4)), $po->id);
            $po->update({ po_number => $num });
            for my $ln (@$lines) {
                next unless $ln->{item_id};
                $schema->resultset('Accounting::InventoryPurchaseOrderLine')->create({
                    po_id             => $po->id,
                    item_id           => $ln->{item_id},
                    quantity_ordered  => $ln->{quantity} || $ln->{quantity_ordered} || 1,
                    quantity_received => 0,
                    unit_cost         => $ln->{unit_cost},
                    supplier_sku      => $ln->{supplier_sku},
                    notes             => $ln->{notes},
                });
            }
        });
    } catch {
        my $err = "$_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_po',
            "PO create failed: $err");
        if ($err =~ /doesn't exist|Unknown table|Can't find table|no such table/i) {
            $fail = {
                ok => 0,
                error => 'Purchase order tables are not on the live DB yet. Apply InventoryPurchaseOrder (+ Line) via schema-compare.',
                need_schema_compare => 1,
            };
        } else {
            $fail = { ok => 0, error => "PO create failed: $err" };
        }
    };
    return $fail if $fail;

    return { ok => 0, error => 'PO create returned no row' } unless $po;
    return {
        ok        => 1,
        po_id     => $po->id,
        po_number => $po->po_number,
        status    => $po->status,
    };
}

=head2 stock_reorder_list

Return low-stock items (total on_hand <= reorder_point) grouped by preferred supplier.
Used for stock-sheet -> PO flow. Independent of BOM needs.

=cut
sub stock_reorder_list {
    my ($self, $c, $p) = @_;
    $p ||= {};
    my $sitename = $p->{sitename} || $c->session->{SiteName} || 'default';
    my $schema   = $c->model('DBEncy');

    my @low_items;
    eval {
        my @items = $schema->resultset('Accounting::InventoryItem')->search(
            {
                'me.sitename' => $sitename,
                'me.status'   => 'active',
            },
            {
                prefetch => [ 'stock_levels', { item_suppliers => 'supplier' } ],
                order_by => ['category', 'name'],
            }
        )->all;

        for my $item (@items) {
            my $total = 0;
            for my $sl ($item->stock_levels->all) {
                $total += $sl->quantity_on_hand || 0;
            }
            # Include items that are below reorder point OR have never been
            # received (missing stock — total 0 and no stock_level rows).
            my $reorder = $item->reorder_point || 0;
            my $has_stock = $item->stock_levels->count ? 1 : 0;
            next if $has_stock && $total > $reorder;
            next if !$has_stock && $reorder > 0 && $total > $reorder;

            my $short = ($item->reorder_point || 0) - $total;
            my $qty   = $item->reorder_quantity || $short || 1;

            # Preferred supplier (or first linked)
            my $pref = undef;
            my @links = $item->item_suppliers->all;
            for my $l (@links) {
                if ($l->is_preferred) { $pref = $l; last; }
            }
            $pref ||= $links[0] if @links;

            my $row = {
                item_id           => $item->id,
                sku               => $item->sku,
                name              => $item->name,
                category          => $item->category,
                current_stock     => $total,
                reorder_point     => $item->reorder_point || 0,
                reorder_quantity  => $item->reorder_quantity || 0,
                shortfall         => $short > 0 ? $short : 0,
                suggested_qty     => $qty,
                unit_cost         => $item->unit_cost,
                unit_of_measure   => $item->unit_of_measure,
                item_origin       => $item->item_origin,
            };
            if ($pref) {
                $row->{supplier_id}   = $pref->supplier_id;
                $row->{supplier_name} = eval { $pref->supplier->name } || 'Unknown';
                $row->{supplier_sku}  = $pref->supplier_sku;
                $row->{unit_cost}     = $pref->unit_cost || $item->unit_cost;
                $row->{is_preferred}  = $pref->is_preferred ? 1 : 0;
            }
            push @low_items, $row;
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'stock_reorder_list',
            "Failed to compute reorder list: $@");
        return { ok => 0, error => "DB error computing low stock: $@" };
    }

    # Group by supplier
    my %by_sup;
    my @unassigned;
    for my $row (@low_items) {
        if ($row->{supplier_id}) {
            my $sid = $row->{supplier_id};
            push @{ $by_sup{$sid}{items} }, $row;
            $by_sup{$sid}{supplier_id}   = $sid;
            $by_sup{$sid}{supplier_name} = $row->{supplier_name};
        } else {
            push @unassigned, $row;
        }
    }

    return {
        ok           => 1,
        sitename     => $sitename,
        by_supplier  => [ sort { $a->{supplier_name} cmp $b->{supplier_name} } values %by_sup ],
        unassigned   => \@unassigned,
        total_low    => scalar(@low_items),
    };
}

# Orders-only view of the low/missing stock set. Unlike stock_reorder_list this:
#  - excludes non-orderable items: overhead/cost/3d_printed origins, and Equipment/
#    3d_printer categories (printers + capital gear are not restock-purchased);
#  - expands any selected BOM parent recursively to its short LEAF components
#    (BOMs-within-BOMs), so ticking a kit orders the parts it needs, not the kit;
#  - groups the resulting leaf lines by preferred supplier (same grouping as
#    stock_reorder_list).
#
# Params: sitename, selected_ids? (array of item_ids to restrict to; omit = all
# orderable low/missing), expand_bom? (default 1).
sub orderable_low_list {
    my ($self, $c, $p) = @_;
    $p ||= {};
    my $sitename   = $p->{sitename} || $c->session->{SiteName} || 'default';
    my $schema     = $c->model('DBEncy');
    my $expand_bom = defined $p->{expand_bom} ? $p->{expand_bom} : 1;

    # Origins/categories that are NEVER purchase-ordered.
    my %skip_origin = map { $_ => 1 } qw(overhead cost 3d_printed);
    my %skip_cat    = map { $_ => 1 } qw(Equipment 3d_printer);

    my @candidates;
    eval {
        my @items = $schema->resultset('Accounting::InventoryItem')->search(
            { sitename => $sitename, status => 'active' },
            { prefetch => [ 'stock_levels', { item_suppliers => 'supplier' } ] },
        )->all;

        my %selected = map { $_ => 1 } @{ $p->{selected_ids} || [] };
        for my $item (@items) {
            my $origin = lc($item->item_origin || '');
            my $cat    = $item->category || '';
            next if $skip_origin{$origin};
            next if $skip_cat{$cat};
            if (%selected) {
                next unless $selected{ $item->id };
            }
            my $total = 0;
            my $has   = 0;
            for my $sl ($item->stock_levels->all) { $total += $sl->quantity_on_hand || 0; $has = 1; }
            my $reorder = $item->reorder_point || 0;
            my $is_low = ($reorder > 0 && $total <= $reorder) || !$has;
            next unless $is_low;
            push @candidates, $item;
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'orderable_low_list',
            "Failed: $@");
        return { ok => 0, error => "DB error: $@" };
    }

    my $traveler = eval { Comserv::Util::Manufacturing::Traveler->new };
    my %leaf_acc;
    for my $item (@candidates) {
        my @leaves;
        if ($expand_bom && $item->is_assemblable) {
            eval {
                my @raw = $traveler->_explode_to_leaves($c, $item->id, $item->sku, 1, {});
                for my $L (@raw) {
                    next unless $L->{component_item_id};
                    my $li = $schema->resultset('Accounting::InventoryItem')->find($L->{component_item_id});
                    next unless $li;
                    my $lo = lc($li->item_origin || '');
                    next if $skip_origin{$lo} || $skip_cat{ $li->category || '' };
                    push @leaves, {
                        item_id   => $li->id,
                        sku       => $li->sku,
                        name      => $li->name,
                        qty       => $L->{quantity} || 1,
                        reorder_point => $li->reorder_point || 0,
                    };
                }
            };
        }
        if (@leaves) {
            for my $L (@leaves) {
                my $k = $L->{item_id};
                $leaf_acc{$k}{qty}            += $L->{qty};
                $leaf_acc{$k}{sku}             = $L->{sku};
                $leaf_acc{$k}{name}            = $L->{name};
                $leaf_acc{$k}{reorder_point}   = $L->{reorder_point};
            }
        } else {
            my $k = $item->id;
            $leaf_acc{$k}{qty}            += 1;
            $leaf_acc{$k}{sku}             = $item->sku;
            $leaf_acc{$k}{name}            = $item->name;
            $leaf_acc{$k}{reorder_point}   = $item->reorder_point || 0;
        }
    }

    my (@rows, %by_sup, @unassigned);
    for my $k (keys %leaf_acc) {
        my $li = $schema->resultset('Accounting::InventoryItem')->find($k);
        next unless $li;
        my $row = {
            item_id           => $k,
            sku               => $leaf_acc{$k}{sku},
            name              => $leaf_acc{$k}{name},
            category          => $li->category,
            current_stock     => 0,
            reorder_point     => $leaf_acc{$k}{reorder_point},
            suggested_qty     => $leaf_acc{$k}{qty},
            unit_cost         => $li->unit_cost,
            unit_of_measure   => $li->unit_of_measure,
            item_origin       => $li->item_origin,
        };
        my $pref;
        eval {
            my @links = $li->item_suppliers->all;
            for my $l (@links) { if ($l->is_preferred) { $pref = $l; last; } }
            $pref ||= $links[0] if @links;
        };
        if ($pref) {
            $row->{supplier_id}   = $pref->supplier_id;
            $row->{supplier_name} = eval { $pref->supplier->name } || 'Unknown';
            $row->{supplier_sku}  = $pref->supplier_sku;
            $row->{unit_cost}     = $pref->unit_cost || $li->unit_cost;
            $by_sup{ $row->{supplier_id} }{supplier_id}   = $row->{supplier_id};
            $by_sup{ $row->{supplier_id} }{supplier_name} = $row->{supplier_name};
            push @{ $by_sup{ $row->{supplier_id} }{items} }, $row;
        } else {
            push @unassigned, $row;
        }
    }

    return {
        ok          => 1,
        sitename    => $sitename,
        by_supplier => [ sort { $a->{supplier_name} cmp $b->{supplier_name} } values %by_sup ],
        unassigned  => \@unassigned,
        total_low   => scalar(keys %leaf_acc),
    };
}

sub _stock_location {
    my ($self, $c, $schema, $sitename, $now) = @_;
    my $loc = $schema->resultset('Accounting::InventoryLocation')->search(
        { sitename => $sitename, status => 'active' },
        { order_by => 'id', rows => 1 },
    )->first;
    return $loc if $loc;
    return $schema->resultset('Accounting::InventoryLocation')->create({
        sitename      => $sitename,
        name          => 'Stock',
        location_type => 'warehouse',
        status        => 'active',
        notes         => 'Auto-created for PO receive',
        created_by    => ($c->session->{username} || 'hermes-agent'),
        created_at    => $now,
        updated_at    => $now,
    });
}

# delta +1 on send, -1 on receive. Applies remaining (ordered-received) * sign.
sub adjust_on_order_for_po {
    my ($self, $c, $po, $sign) = @_;
    return unless $po && $sign;
    my $schema = $c->model('DBEncy');
    my $now    = _now();
    my $sitename = $po->sitename;
    my $loc;
    eval { $loc = $self->_stock_location($c, $schema, $sitename, $now) };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'adjust_on_order_for_po',
            "location: $@");
        return;
    }
    for my $ln ($po->lines) {
        my $remain = ($ln->quantity_ordered || 0) - ($ln->quantity_received || 0);
        next if $remain <= 0;
        my $delta = $sign * $remain;
        my $stock = $schema->resultset('Accounting::InventoryStockLevel')->find_or_create(
            { item_id => $ln->item_id, location_id => $loc->id },
            { default => { quantity_on_hand => 0, quantity_reserved => 0, quantity_on_order => 0, updated_at => $now } },
        );
        my $oo = ($stock->quantity_on_order || 0) + $delta;
        $oo = 0 if $oo < 0;
        $stock->update({ quantity_on_order => $oo, updated_at => $now });
    }
}

# Receive against a PO. Params: sitename, po_id, lines? [{line_id|item_id, quantity}],
# receive_all? (default 1 if no lines). Does not post GL.
sub receive_po {
    my ($self, $c, $p) = @_;
    $p ||= {};
    my $schema   = $c->model('DBEncy');
    my $sitename = $p->{sitename} or return { ok => 0, error => 'sitename required' };
    my $po_id    = $p->{po_id}    or return { ok => 0, error => 'po_id required' };

    my $po = eval {
        $schema->resultset('Accounting::InventoryPurchaseOrder')->find({ id => $po_id, sitename => $sitename });
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'receive_po', "find PO: $@");
        return { ok => 0, error => "PO lookup failed: $@" };
    }
    return { ok => 0, error => 'PO not found' } unless $po;
    my $st = lc($po->status || '');
    return { ok => 0, error => "PO status '$st' cannot receive" }
        if $st eq 'cancelled' || $st eq 'received';

    my %want;
    my $lines_in = $p->{lines};
    if ($lines_in && ref($lines_in) eq 'ARRAY' && @$lines_in) {
        for my $row (@$lines_in) {
            next unless $row && ref($row) eq 'HASH';
            my $key = $row->{line_id} || $row->{item_id} or next;
            my $q   = 0 + ($row->{quantity} || $row->{qty} || 0);
            next unless $q > 0;
            $want{$key} = $q;
        }
        return { ok => 0, error => 'no positive quantities' } unless %want;
    }

    my $fail;
    my @received;
    my $now = _now();
    try {
        $schema->txn_do(sub {
            my $loc = $self->_stock_location($c, $schema, $sitename, $now);
            for my $ln ($po->lines) {
                my $ordered = 0 + ($ln->quantity_ordered || 0);
                my $already = 0 + ($ln->quantity_received || 0);
                my $open    = $ordered - $already;
                next if $open <= 0;
                my $qty;
                if (%want) {
                    $qty = $want{ $ln->id } || $want{ $ln->item_id } || 0;
                } else {
                    $qty = $open;    # receive_all remaining
                }
                next unless $qty > 0;
                $qty = $open if $qty > $open;

                $ln->update({ quantity_received => $already + $qty });

                my $stock = $schema->resultset('Accounting::InventoryStockLevel')->find_or_create(
                    { item_id => $ln->item_id, location_id => $loc->id },
                    { default => {
                        quantity_on_hand  => 0,
                        quantity_reserved => 0,
                        quantity_on_order => 0,
                        updated_at        => $now,
                    } },
                );
                my $hand = 0 + ($stock->quantity_on_hand || 0) + $qty;
                my $oo   = 0 + ($stock->quantity_on_order || 0) - $qty;
                $oo = 0 if $oo < 0;
                $stock->update({
                    quantity_on_hand  => $hand,
                    quantity_on_order => $oo,
                    updated_at        => $now,
                });

                if (($ln->unit_cost || 0) > 0) {
                    my $it = $schema->resultset('Accounting::InventoryItem')->find($ln->item_id);
                    if ($it && !(($it->unit_cost || 0) > 0)) {
                        $it->update({ unit_cost => $ln->unit_cost, updated_at => $now });
                    }
                }

                eval {
                    $schema->resultset('Accounting::InventoryTransaction')->create({
                        item_id          => $ln->item_id,
                        location_id      => $loc->id,
                        transaction_type => 'receive',
                        quantity         => $qty,
                        unit_cost        => $ln->unit_cost,
                        reference_number => $po->po_number || ('PO-' . $po->id),
                        sitename         => $sitename,
                        notes            => 'PO receive line ' . $ln->id,
                        performed_by     => $c->session->{username} || 'hermes-agent',
                        transaction_date => $now,
                        created_at       => $now,
                    });
                };
                if ($@) {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'receive_po',
                        "transaction row skipped: $@");
                }

                push @received, {
                    line_id  => $ln->id,
                    item_id  => $ln->item_id,
                    quantity => $qty,
                    on_hand  => $hand,
                };
            }

            my ($any_recv, $any_open) = (0, 0);
            for my $ln ($po->lines) {
                $any_recv = 1 if ($ln->quantity_received || 0) > 0;
                $any_open = 1 if ($ln->quantity_received || 0) < ($ln->quantity_ordered || 0);
            }
            my $new_st = (!$any_open && $any_recv) ? 'received' : ($any_recv ? 'partial' : $po->status);
            my $notes  = $po->notes || '';
            $notes .= "\n[$now] Received " . scalar(@received) . " line(s) by "
                . ($c->session->{username} || 'hermes-agent');
            $po->update({ status => $new_st, notes => $notes, updated_at => $now });
        });
    } catch {
        my $err = "$_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'receive_po',
            "PO $po_id receive failed: $err");
        $fail = { ok => 0, error => "PO receive failed: $err" };
    };
    return $fail if $fail;
    return { ok => 0, error => 'nothing to receive' } unless @received;
    $po->discard_changes;
    return {
        ok       => 1,
        po_id    => $po->id,
        po_number => $po->po_number,
        status   => $po->status,
        received => \@received,
    };
}

# Explode parent BOM, reserve on-hand against quantity_reserved, return buy vs print shortfall.
# Does not post GL. dry_run=1 computes without writing.
# Params: sitename, parent_item_id|parent_sku, quantity (default 1), customer_order_id?, dry_run?
sub reserve_bom {
    my ($self, $c, $p) = @_;
    $p ||= {};
    my $sitename = $p->{sitename} or return { ok => 0, error => 'sitename required' };
    my $qty      = 0 + ($p->{quantity} || 1);
    return { ok => 0, error => 'quantity must be > 0' } unless $qty > 0;
    my $schema   = $c->model('DBEncy');
    my $dry      = $p->{dry_run} ? 1 : 0;

    my $parent;
    eval {
        if ($p->{parent_item_id}) {
            $parent = $schema->resultset('Accounting::InventoryItem')->find($p->{parent_item_id});
        } elsif ($p->{parent_sku}) {
            $parent = $schema->resultset('Accounting::InventoryItem')->search({
                sitename => $sitename, sku => $p->{parent_sku},
            }, { rows => 1 })->first;
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'reserve_bom', "find parent: $@");
        return { ok => 0, error => "parent lookup failed: $@" };
    }
    return { ok => 0, error => 'parent_item_id or parent_sku required' }
        unless $p->{parent_item_id} || $p->{parent_sku};
    return { ok => 0, error => 'parent item not found' } unless $parent;

    require Comserv::Util::Manufacturing::Traveler;
    my $traveler = Comserv::Util::Manufacturing::Traveler->new;
    my @leaves = $traveler->_merge_leaves(
        $traveler->_explode_to_leaves($c, $parent->id, $parent->sku, $qty, {})
    );
    return { ok => 0, error => 'BOM has no leaf components' } unless @leaves;

    my $ref = sprintf('RSV-%s-x%s', $parent->id, $qty);
    $ref .= '-o' . $p->{customer_order_id} if $p->{customer_order_id};
    unless ($dry || $p->{force}) {
        my $prior = eval {
            $schema->resultset('Accounting::InventoryTransaction')->search({
                sitename         => $sitename,
                reference_number => $ref,
                transaction_type => 'reserve',
            })->first;
        };
        if ($prior) {
            return { ok => 0, error => "already reserved ($ref); pass force=1 to skip this guard", already => 1 };
        }
    }

    my $now = _now();
    my (@reserved, @buy, @print);
    my $fail;
    my $work = sub {
        for my $L (@leaves) {
            my $item_id = $L->{component_item_id} or next;
            my $need    = 0 + ($L->{quantity} || 0);
            next unless $need > 0;
            my $origin  = lc($L->{item_origin} || '');
            my @sl = $schema->resultset('Accounting::InventoryStockLevel')->search(
                { item_id => $item_id }, { order_by => 'id' }
            )->all;
            my $avail = 0;
            for my $s (@sl) {
                $avail += (($s->quantity_on_hand || 0) - ($s->quantity_reserved || 0));
            }
            $avail = 0 if $avail < 0;
            my $take = $avail < $need ? $avail : $need;
            if ($take > 0 && !$dry) {
                my $left = $take;
                for my $s (@sl) {
                    last if $left <= 0;
                    my $row_av = ($s->quantity_on_hand || 0) - ($s->quantity_reserved || 0);
                    next if $row_av <= 0;
                    my $chunk = $row_av < $left ? $row_av : $left;
                    $s->update({
                        quantity_reserved => ($s->quantity_reserved || 0) + $chunk,
                        updated_at        => $now,
                    });
                    eval {
                        $schema->resultset('Accounting::InventoryTransaction')->create({
                            item_id          => $item_id,
                            location_id      => $s->location_id,
                            transaction_type => 'reserve',
                            quantity         => $chunk,
                            reference_number => $ref,
                            sitename         => $sitename,
                            notes            => sprintf('BOM reserve parent=%s sku=%s', $parent->sku, $L->{sku} || ''),
                            performed_by     => $c->session->{username} || 'hermes-agent',
                            transaction_date => $now,
                            created_at       => $now,
                        });
                    };
                    if ($@) {
                        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'reserve_bom',
                            "txn skip item=$item_id: $@");
                    }
                    $left -= $chunk;
                }
            }
            my $short = $need - $take;
            my $row = {
                item_id   => $item_id,
                sku       => $L->{sku},
                name      => $L->{name},
                need      => $need,
                reserved  => $take,
                shortfall => $short > 0 ? $short : 0,
                item_origin => $origin,
            };
            push @reserved, $row if $take > 0;
            if ($short > 0) {
                if ($origin =~ /print/) {
                    push @print, $row;
                } else {
                    push @buy, $row;
                }
            }
        }
    };

    if ($dry) {
        eval { $work->() };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'reserve_bom', "dry: $@");
            return { ok => 0, error => "$@" };
        }
    } else {
        try {
            $schema->txn_do($work);
        } catch {
            my $err = "$_";
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'reserve_bom', $err);
            $fail = { ok => 0, error => "reserve failed: $err" };
        };
        return $fail if $fail;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'reserve_bom',
        sprintf('parent=%s qty=%s reserved=%d buy=%d print=%d dry=%d',
            $parent->sku, $qty, scalar(@reserved), scalar(@buy), scalar(@print), $dry));
    return {
        ok            => 1,
        dry_run       => $dry,
        parent_id     => $parent->id,
        parent_sku    => $parent->sku,
        quantity      => $qty,
        reference     => $ref,
        reserved      => \@reserved,
        buy           => \@buy,
        print         => \@print,
    };
}

# Reverse a reserve_bom for the same RSV-{parent}-x{qty}[-o{order}] ref. No GL.
# Idempotent: existing unreserve txn → already=1 success.
sub unreserve_bom {
    my ($self, $c, $p) = @_;
    $p ||= {};
    my $sitename = $p->{sitename} or return { ok => 0, error => 'sitename required' };
    my $qty      = 0 + ($p->{quantity} || 1);
    return { ok => 0, error => 'quantity must be > 0' } unless $qty > 0;
    my $schema   = $c->model('DBEncy');

    my $parent;
    eval {
        if ($p->{parent_item_id}) {
            $parent = $schema->resultset('Accounting::InventoryItem')->find($p->{parent_item_id});
        } elsif ($p->{parent_sku}) {
            $parent = $schema->resultset('Accounting::InventoryItem')->search({
                sitename => $sitename, sku => $p->{parent_sku},
            }, { rows => 1 })->first;
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'unreserve_bom', "find parent: $@");
        return { ok => 0, error => "parent lookup failed: $@" };
    }
    return { ok => 0, error => 'parent_item_id or parent_sku required' }
        unless $p->{parent_item_id} || $p->{parent_sku};
    return { ok => 0, error => 'parent item not found' } unless $parent;

    my $ref = sprintf('RSV-%s-x%s', $parent->id, $qty);
    $ref .= '-o' . $p->{customer_order_id} if $p->{customer_order_id};

    my $prior_un = eval {
        $schema->resultset('Accounting::InventoryTransaction')->search({
            sitename         => $sitename,
            reference_number => $ref,
            transaction_type => 'unreserve',
        })->first;
    };
    if ($prior_un && !$p->{force}) {
        return { ok => 1, already => 1, reference => $ref, parent_sku => $parent->sku, released => [] };
    }

    my @txns = eval {
        $schema->resultset('Accounting::InventoryTransaction')->search({
            sitename         => $sitename,
            reference_number => $ref,
            transaction_type => 'reserve',
        })->all;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'unreserve_bom', "find txns: $@");
        return { ok => 0, error => "reservation lookup failed: $@" };
    }
    return { ok => 0, error => "no reservation found ($ref)", missing => 1 } unless @txns;

    my $now = _now();
    my @released;
    my $fail;
    try {
        $schema->txn_do(sub {
            for my $txn (@txns) {
                my $q = 0 + ($txn->quantity || 0);
                next unless $q > 0 && $txn->item_id;
                my $stock = $schema->resultset('Accounting::InventoryStockLevel')->search({
                    item_id     => $txn->item_id,
                    location_id => $txn->location_id,
                }, { rows => 1 })->first;
                next unless $stock;
                my $new = ($stock->quantity_reserved || 0) - $q;
                $new = 0 if $new < 0;
                $stock->update({ quantity_reserved => $new, updated_at => $now });
                eval {
                    $schema->resultset('Accounting::InventoryTransaction')->create({
                        item_id          => $txn->item_id,
                        location_id      => $txn->location_id,
                        transaction_type => 'unreserve',
                        quantity         => $q,
                        reference_number => $ref,
                        sitename         => $sitename,
                        notes            => sprintf('BOM unreserve parent=%s', $parent->sku),
                        performed_by     => $c->session->{username} || 'hermes-agent',
                        transaction_date => $now,
                        created_at       => $now,
                    });
                };
                if ($@) {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'unreserve_bom',
                        "txn skip item=" . $txn->item_id . ": $@");
                }
                push @released, { item_id => $txn->item_id, quantity => $q, reserved_now => $new };
            }
        });
    } catch {
        my $err = "$_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'unreserve_bom', $err);
        $fail = { ok => 0, error => "unreserve failed: $err" };
    };
    return $fail if $fail;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'unreserve_bom',
        sprintf('parent=%s qty=%s released=%d ref=%s', $parent->sku, $qty, scalar(@released), $ref));
    return {
        ok         => 1,
        parent_id  => $parent->id,
        parent_sku => $parent->sku,
        quantity   => $qty,
        reference  => $ref,
        released   => \@released,
    };
}

__PACKAGE__->meta->make_immutable;
1;
