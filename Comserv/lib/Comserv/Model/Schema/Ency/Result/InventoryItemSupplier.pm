package Comserv::Model::Schema::Ency::Result::InventoryItemSupplier;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('inventory_item_suppliers');

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
    supplier_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    supplier_sku => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    unit_cost => {
        data_type   => 'decimal',
        size        => [10, 2],
        is_nullable => 1,
    },
    is_preferred => {
        data_type     => 'tinyint',
        is_nullable   => 0,
        default_value => 0,
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['item_id', 'supplier_id']);

__PACKAGE__->belongs_to(
    'item' => 'Comserv::Model::Schema::Ency::Result::InventoryItem',
    { 'foreign.id' => 'self.item_id' }
);

__PACKAGE__->belongs_to(
    'supplier' => 'Comserv::Model::Schema::Ency::Result::InventorySupplier',
    { 'foreign.id' => 'self.supplier_id' }
);

1;
