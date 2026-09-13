package Comserv::Model::Schema::Ency::Result::Accounting::InventoryPurchaseOrderLine;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('inventory_purchase_order_lines');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    po_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    item_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    quantity_ordered => {
        data_type     => 'decimal',
        size          => [12, 4],
        is_nullable   => 0,
        default_value => '1.0000',
    },
    quantity_received => {
        data_type     => 'decimal',
        size          => [12, 4],
        is_nullable   => 0,
        default_value => '0.0000',
    },
    unit_cost => {
        data_type     => 'decimal',
        size          => [12, 4],
        is_nullable   => 1,
    },
    supplier_sku => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(po_item => [qw/po_id item_id/]);

__PACKAGE__->belongs_to(
    'purchase_order',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryPurchaseOrder',
    { 'foreign.id' => 'self.po_id' },
    { join_type => 'LEFT' }
);

__PACKAGE__->belongs_to(
    'item',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    { 'foreign.id' => 'self.item_id' },
    { join_type => 'LEFT' }
);

1;
