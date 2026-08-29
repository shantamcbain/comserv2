package Comserv::Model::Schema::Ency::Result::Accounting::InventoryPurchaseOrder;
use strict;
use warnings;
use base 'DBIx::Class::Core';

# Result is source of truth. Apply via in-app schema-compare — never hand DDL.
# Purchase order (send to supplier) is NOT a supplier invoice (receive after buy).

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('inventory_purchase_orders');

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
    supplier_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    po_number => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    status => {
        data_type     => 'varchar',
        size          => 30,
        is_nullable   => 0,
        default_value => 'draft',
        comment       => 'draft | sent | partial | received | cancelled',
    },
    origin => {
        data_type     => 'varchar',
        size          => 30,
        is_nullable   => 0,
        default_value => 'internal',
        comment       => 'internal (shop as customer, cost GL) | customer (tied to a sale)',
    },
    source_parent_item_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'Assembly SKU whose BOM shortfall created this PO',
    },
    order_date => {
        data_type        => 'date',
        is_nullable      => 1,
        inflate_datetime => 0,
    },
    expected_date => {
        data_type        => 'date',
        is_nullable      => 1,
        inflate_datetime => 0,
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
__PACKAGE__->add_unique_constraint(po_number_sitename => [qw/sitename po_number/]);

__PACKAGE__->belongs_to(
    'supplier',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventorySupplier',
    { 'foreign.id' => 'self.supplier_id' },
    { join_type => 'LEFT' }
);

__PACKAGE__->belongs_to(
    'source_parent',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    { 'foreign.id' => 'self.source_parent_item_id' },
    { join_type => 'LEFT', on_delete => 'SET NULL' }
);

__PACKAGE__->has_many(
    'lines',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryPurchaseOrderLine',
    { 'foreign.po_id' => 'self.id' },
    { cascade_delete => 1 }
);

1;
