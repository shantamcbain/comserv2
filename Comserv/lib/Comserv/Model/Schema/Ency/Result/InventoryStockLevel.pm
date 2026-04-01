package Comserv::Model::Schema::Ency::Result::InventoryStockLevel;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('inventory_stock_levels');

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
    quantity_on_hand => {
        data_type     => 'decimal',
        size          => [12, 3],
        is_nullable   => 0,
        default_value => '0.000',
    },
    quantity_reserved => {
        data_type     => 'decimal',
        size          => [12, 3],
        is_nullable   => 0,
        default_value => '0.000',
    },
    quantity_on_order => {
        data_type     => 'decimal',
        size          => [12, 3],
        is_nullable   => 0,
        default_value => '0.000',
    },
    last_count_date => {
        data_type   => 'datetime',
        is_nullable => 1,
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
    'item' => 'Comserv::Model::Schema::Ency::Result::InventoryItem',
    { 'foreign.id' => 'self.item_id' }
);

__PACKAGE__->belongs_to(
    'location' => 'Comserv::Model::Schema::Ency::Result::InventoryLocation',
    { 'foreign.id' => 'self.location_id' }
);

1;
