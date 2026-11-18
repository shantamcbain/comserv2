package Comserv::Model::Schema::Ency::Result::Accounting::InventoryConsignmentPlacement;
use strict;
use warnings;
use base 'DBIx::Class::Core';

# A consignment PLACEMENT: one partner's stock of one item standing in one
# storage location (e.g. Monashee Community Co-op / Sprouting Lid / "Co-op
# Sprouting Lids"). It is the join that makes a photo count meaningful:
#   * which location is being photographed
#   * which consignor owns what is standing there
#   * what quantity of each colour we MAINTAIN there (the top-up target)
#   * which customer the sale is invoiced to
#
# Colour lives here and on the count lines (NOT as separate inventory items):
# filament consumption is tracked per print job (printing_3d_jobs.filament_*),
# so a colour SKU would add BOM/stock/shop rows without improving filament
# accuracy. See .hermes/plans/2026-11-05-consignment-location-count-photo.md §3.1

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('inventory_consignment_placements');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    location_id => {
        data_type      => 'integer',
        is_nullable    => 0,
        is_foreign_key => 1,
    },
    partner_id => {
        data_type      => 'integer',
        is_nullable    => 0,
        is_foreign_key => 1,
    },
    item_id => {
        data_type      => 'integer',
        is_nullable    => 0,
        is_foreign_key => 1,
    },
    # Customer the sale is invoiced to (partner name != invoice customer name,
    # e.g. "Monashee Community Co-op" invoices as "MCoop"). NULL => use partner name.
    invoice_customer_name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    # Per-placement override of the partner's commission (percent). NULL => partner's.
    commission_percent => {
        data_type   => 'decimal',
        size        => [5, 2],
        is_nullable => 1,
    },
    # Maintained quantity per colour, JSON: {"blue":2,"yellow":2,"red":2,"green":2}
    target_counts => {
        data_type   => 'text',
        is_nullable => 1,
    },
    # Colour order/labels used by the count screen, CSV: "blue,yellow,red,green"
    colours => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    status => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 0,
        default_value => 'active',
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    created_by => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'datetime',
        is_nullable   => 1,
        set_on_create => 1,
    },
    updated_at => {
        data_type     => 'datetime',
        is_nullable   => 1,
        set_on_create => 1,
        set_on_update => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'location' => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryLocation',
    { 'foreign.id' => 'self.location_id' }
);

__PACKAGE__->belongs_to(
    'partner' => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryConsignmentPartner',
    { 'foreign.id' => 'self.partner_id' }
);

__PACKAGE__->belongs_to(
    'item' => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    { 'foreign.id' => 'self.item_id' }
);

__PACKAGE__->has_many(
    'counts' => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryLocationCount',
    { 'foreign.placement_id' => 'self.id' }
);

# Decoded target map, e.g. { blue => 2, yellow => 2, ... }. Always a hashref.
sub target_map {
    my ($self) = @_;
    my $raw = $self->target_counts // '';
    return {} unless length $raw;
    my $decoded = eval { require JSON; JSON::decode_json($raw) };
    return (ref $decoded eq 'HASH') ? $decoded : {};
}

sub target_for {
    my ($self, $colour) = @_;
    my $map = $self->target_map;
    return $map->{ lc($colour // '') } // 0;
}

sub colour_list {
    my ($self) = @_;
    my @from_csv = grep { length } split /\s*,\s*/, ($self->colours // '');
    return @from_csv if @from_csv;
    return sort keys %{ $self->target_map };
}

# Effective commission: placement override, else the partner's rate.
sub effective_commission_percent {
    my ($self) = @_;
    return $self->commission_percent + 0 if defined $self->commission_percent;
    my $partner = $self->partner;
    return ($partner && defined $partner->commission_percent) ? $partner->commission_percent + 0 : 0;
}

1;
