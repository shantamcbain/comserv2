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
    item_origin => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 0,
        default_value => 'purchased',
    },
    is_assemblable => {
        data_type     => 'tinyint',
        is_nullable   => 0,
        default_value => 0,
    },
    inventory_accno_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    income_accno_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    expense_accno_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    returns_accno_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    unit_of_measure => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 0,
        default_value => 'each',
    },
    unit_cost => {
        data_type   => 'decimal',
        size        => [10, 2],
        is_nullable => 1,
    },
    unit_price => {
        data_type   => 'decimal',
        size        => [10, 2],
        is_nullable => 1,
    },
    barcode => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    reorder_point => {
        data_type     => 'integer',
        is_nullable   => 1,
        default_value => 0,
    },
    maximum_stock => {
        data_type     => 'integer',
        is_nullable   => 1,
        default_value => 0,
    },
    reorder_quantity => {
        data_type     => 'integer',
        is_nullable   => 1,
        default_value => 0,
    },
    is_consumable => {
        data_type     => 'tinyint',
        is_nullable   => 0,
        default_value => 0,
    },
    is_reusable => {
        data_type     => 'tinyint',
        is_nullable   => 0,
        default_value => 1,
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
    condition => {
        data_type     => 'varchar',
        size          => 20,
        is_nullable   => 1,
        default_value => 'new',
    },
    purchase_date => {
        data_type   => 'date',
        is_nullable => 1,
    },
    warranty_expiry => {
        data_type   => 'date',
        is_nullable => 1,
    },
    created_by => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    updated_by => {
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
__PACKAGE__->add_unique_constraint(unique_sku => ['sku']);

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

__PACKAGE__->belongs_to(
    'inventory_account',
    'Comserv::Model::Schema::Ency::Result::CoaAccount',
    { 'foreign.id' => 'self.inventory_accno_id' },
    { join_type => 'LEFT', on_delete => 'SET NULL' }
);

__PACKAGE__->belongs_to(
    'income_account',
    'Comserv::Model::Schema::Ency::Result::CoaAccount',
    { 'foreign.id' => 'self.income_accno_id' },
    { join_type => 'LEFT', on_delete => 'SET NULL' }
);

__PACKAGE__->belongs_to(
    'expense_account',
    'Comserv::Model::Schema::Ency::Result::CoaAccount',
    { 'foreign.id' => 'self.expense_accno_id' },
    { join_type => 'LEFT', on_delete => 'SET NULL' }
);

__PACKAGE__->belongs_to(
    'returns_account',
    'Comserv::Model::Schema::Ency::Result::CoaAccount',
    { 'foreign.id' => 'self.returns_accno_id' },
    { join_type => 'LEFT', on_delete => 'SET NULL' }
);

__PACKAGE__->has_many(
    'bom_components' => 'Comserv::Model::Schema::Ency::Result::InventoryItemBOM',
    { 'foreign.parent_item_id' => 'self.id' },
    { cascade_delete => 1 }
);

__PACKAGE__->has_many(
    'bom_used_in' => 'Comserv::Model::Schema::Ency::Result::InventoryItemBOM',
    { 'foreign.component_item_id' => 'self.id' },
    { cascade_delete => 0 }
);

1;
