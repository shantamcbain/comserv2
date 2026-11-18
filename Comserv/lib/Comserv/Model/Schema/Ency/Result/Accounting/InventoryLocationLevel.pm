package Comserv::Model::Schema::Ency::Result::Accounting::InventoryLocationLevel;
use strict;
use warnings;
use base 'DBIx::Class::Core';

# Replenishment policy per container. A min belongs to a location, not to an item
# globally: the coop container and the warehouse rack hold the same SKU for different
# reasons and can carry different minimums. Stock level stays the sum of locations;
# this table only says how much must be sitting in *this* one.
__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('inventory_location_levels');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    item_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    location_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    min_level => {
        data_type     => 'decimal',
        size          => [12, 3],
        is_nullable   => 0,
        default_value => '0.000',
    },
    max_level => {
        data_type   => 'decimal',
        size          => [12, 3],
        is_nullable   => 1,
    },
    is_active => {
        data_type     => 'integer',
        size          => 1,       # integer(1), not integer(1,0) — MariaDB takes no scale on int
        is_nullable   => 0,
        default_value => 1,
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
__PACKAGE__->add_unique_constraint(['item_id', 'location_id']);

__PACKAGE__->belongs_to(
    'item' => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    { 'foreign.id' => 'self.item_id' }
);

__PACKAGE__->belongs_to(
    'location' => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryLocation',
    { 'foreign.id' => 'self.location_id' }
);

1;
