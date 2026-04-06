package Comserv::Model::Schema::Ency::Result::InventoryItem;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('inventory_items');

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
    sku => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 0,
    },
    name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    description => {
        data_type   => 'text',
        is_nullable => 1,
    },
    category => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    unit_of_measure => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 0,
        default_value => 'each',
    },
    unit_cost => {
        data_type     => 'decimal',
        size          => [10, 2],
        is_nullable   => 1,
    },
    reorder_point => {
        data_type     => 'integer',
        is_nullable   => 1,
        default_value => 0,
    },
    reorder_quantity => {
        data_type     => 'integer',
        is_nullable   => 1,
        default_value => 0,
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
__PACKAGE__->add_unique_constraint(['sku']);

__PACKAGE__->has_many(
    'stock_levels' => 'Comserv::Model::Schema::Ency::Result::InventoryStockLevel',
    { 'foreign.item_id' => 'self.id' },
    { cascade_delete => 1 }
);

__PACKAGE__->has_many(
    'transactions' => 'Comserv::Model::Schema::Ency::Result::InventoryTransaction',
    { 'foreign.item_id' => 'self.id' },
    { cascade_delete => 0 }
);

__PACKAGE__->has_many(
    'assignments' => 'Comserv::Model::Schema::Ency::Result::InventoryAssignment',
    { 'foreign.item_id' => 'self.id' },
    { cascade_delete => 0 }
);

__PACKAGE__->has_many(
    'item_suppliers' => 'Comserv::Model::Schema::Ency::Result::InventoryItemSupplier',
    { 'foreign.item_id' => 'self.id' },
    { cascade_delete => 1 }
);

__PACKAGE__->many_to_many(
    'suppliers' => 'item_suppliers', 'supplier'
);

1;
