package Comserv::Util::Inventory::Purchasing;

use strict;
use warnings;
use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use Comserv::Util::Logging;

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
    my @t = localtime;
    return sprintf('%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3]);
}

sub _now {
    my @t = localtime;
    return sprintf('%04d-%02d-%02d %02d:%02d:%02d',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
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
                sitename      => $sitename,
                status        => 'active',
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

__PACKAGE__->meta->make_immutable;
1;
