package Comserv::Model::Schema::Ency::Result::InventoryCustomerInvoiceLine;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('inventory_customer_invoice_lines');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    invoice_id => {
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
        data_type     => 'decimal',
        size          => [10, 3],
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
    unit_cost => {
        data_type   => 'decimal',
        size        => [10, 2],
        is_nullable => 1,
    },
    income_account_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    cogs_account_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    inventory_account_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'invoice',
    'Comserv::Model::Schema::Ency::Result::InventoryCustomerInvoice',
    { 'foreign.id' => 'self.invoice_id' },
    { on_delete => 'CASCADE' }
);

__PACKAGE__->belongs_to(
    'item',
    'Comserv::Model::Schema::Ency::Result::InventoryItem',
    { 'foreign.id' => 'self.item_id' },
    { join_type => 'LEFT', on_delete => 'SET NULL' }
);

__PACKAGE__->belongs_to(
    'income_account',
    'Comserv::Model::Schema::Ency::Result::CoaAccount',
    { 'foreign.id' => 'self.income_account_id' },
    { join_type => 'LEFT', on_delete => 'SET NULL' }
);

__PACKAGE__->belongs_to(
    'cogs_account',
    'Comserv::Model::Schema::Ency::Result::CoaAccount',
    { 'foreign.id' => 'self.cogs_account_id' },
    { join_type => 'LEFT', on_delete => 'SET NULL' }
);

1;
