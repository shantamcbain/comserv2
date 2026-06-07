package Comserv::Model::Schema::Ency::Result::Accounting::InventoryCustomerOrderLine;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('inventory_customer_order_lines');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    order_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    item_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    description => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    quantity => {
        data_type     => 'integer',
        is_nullable   => 0,
        default_value => 1,
    },
    unit_price => {
        data_type     => 'decimal',
        size          => [10, 2],
        is_nullable   => 1,
        default_value => '0.00',
    },
    line_total => {
        data_type     => 'decimal',
        size          => [10, 2],
        is_nullable   => 1,
        default_value => '0.00',
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'order',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryCustomerOrder',
    { 'foreign.id' => 'self.order_id' },
    { join_type => 'LEFT' }
);

__PACKAGE__->belongs_to(
    'item',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    { 'foreign.id' => 'self.item_id' },
    { join_type => 'LEFT', on_delete => 'SET NULL' }
);

1;
