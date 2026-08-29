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

__PACKAGE__->meta->make_immutable;
1;
