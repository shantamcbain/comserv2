package Comserv::Model::Schema::Ency::Result::InventoryCustomerInvoice;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('inventory_customer_invoices');

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
    customer_order_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    customer_name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
        default_value => '',
    },
    customer_email => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    invoice_number => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    invoice_date => {
        data_type   => 'date',
        is_nullable => 0,
    },
    due_date => {
        data_type   => 'date',
        is_nullable => 1,
    },
    total_amount => {
        data_type     => 'decimal',
        size          => [12, 2],
        is_nullable   => 0,
        default_value => '0.00',
    },
    tax_amount => {
        data_type     => 'decimal',
        size          => [12, 2],
        is_nullable   => 1,
        default_value => '0.00',
    },
    status => {
        data_type     => 'varchar',
        size          => 20,
        is_nullable   => 0,
        default_value => 'draft',
    },
    ar_account_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    income_account_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    tax_account_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    gl_entry_id => {
        data_type   => 'integer',
        is_nullable => 1,
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
    amount_paid => {
        data_type     => 'decimal',
        size          => [10, 0],
        is_nullable   => 1,
        default_value => '0',
    },
    payment_status => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 0,
        default_value => 'pending',
    },
    points_redeemed => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    session_id => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    currency => {
        data_type     => 'char',
        size          => 3,
        is_nullable   => 0,
        default_value => 'CAD',
    },
    exchange_rate => {
        data_type     => 'decimal',
        size          => [12, 6],
        is_nullable   => 1,
        default_value => '1.000000',
    },
    functional_amount => {
        data_type     => 'decimal',
        size          => [12, 2],
        is_nullable   => 1,
        default_value => '0.00',
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->has_many(
    'lines' => 'Comserv::Model::Schema::Ency::Result::InventoryCustomerInvoiceLine',
    { 'foreign.invoice_id' => 'self.id' },
    { cascade_delete => 1 }
);

__PACKAGE__->belongs_to(
    'gl_entry' => 'Comserv::Model::Schema::Ency::Result::GlEntry',
    { 'foreign.id' => 'self.gl_entry_id' },
    { join_type => 'LEFT', on_delete => 'SET NULL' }
);

__PACKAGE__->belongs_to(
    'customer_order' => 'Comserv::Model::Schema::Ency::Result::InventoryCustomerOrder',
    { 'foreign.id' => 'self.customer_order_id' },
    { join_type => 'LEFT', on_delete => 'SET NULL' }
);

1;
