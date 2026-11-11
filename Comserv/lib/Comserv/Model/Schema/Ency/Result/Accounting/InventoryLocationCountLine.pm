package Comserv::Model::Schema::Ency::Result::Accounting::InventoryLocationCountLine;
use strict;
use warnings;
use base 'DBIx::Class::Core';

# One colour row of a location count.
#   qty_expected = what we maintain there (from the placement target)
#   qty_counted  = what the verified text says is physically there
#   qty_delta    = counted - expected  (negative = units left the location = sold)

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('inventory_location_count_lines');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    count_id => {
        data_type      => 'integer',
        is_nullable    => 0,
        is_foreign_key => 1,
    },
    item_id => {
        data_type      => 'integer',
        is_nullable    => 1,
        is_foreign_key => 1,
    },
    colour => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 0,
    },
    qty_expected => {
        data_type     => 'decimal',
        size          => [12, 3],
        is_nullable   => 0,
        default_value => 0,
    },
    qty_counted => {
        data_type     => 'decimal',
        size          => [12, 3],
        is_nullable   => 0,
        default_value => 0,
    },
    qty_delta => {
        data_type     => 'decimal',
        size          => [12, 3],
        is_nullable   => 0,
        default_value => 0,
    },
    # Filament colour the top-up print job should use (defaults to `colour`)
    filament_color => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    sort_order => {
        data_type     => 'integer',
        is_nullable   => 1,
        default_value => 0,
    },
    notes => {
        data_type   => 'text',
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
    'count' => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryLocationCount',
    { 'foreign.id' => 'self.count_id' }
);

__PACKAGE__->belongs_to(
    'item' => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    { 'foreign.id' => 'self.item_id' }
);

# Units short of the maintained target (what the top-up traveller must replace).
sub qty_short {
    my ($self) = @_;
    my $short = ($self->qty_expected + 0) - ($self->qty_counted + 0);
    return $short > 0 ? $short : 0;
}

sub is_sold { return (($_[0]->qty_delta // 0) < 0) ? 1 : 0 }

1;
