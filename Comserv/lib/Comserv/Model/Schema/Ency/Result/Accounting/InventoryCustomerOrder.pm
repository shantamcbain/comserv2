package Comserv::Model::Schema::Ency::Result::Accounting::InventoryCustomerOrder;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('inventory_customer_orders');

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
    customer_name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    customer_email => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    customer_phone => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    status => {
        data_type     => 'varchar',
        size          => 30,
        is_nullable   => 0,
        default_value => 'pending',
    },
    total_amount => {
        data_type     => 'decimal',
        size          => [12, 2],
        is_nullable   => 1,
        default_value => '0.00',
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

__PACKAGE__->has_many(
    'lines',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryCustomerOrderLine',
    { 'foreign.order_id' => 'self.id' },
    { cascade_delete => 1 }
);

1;
