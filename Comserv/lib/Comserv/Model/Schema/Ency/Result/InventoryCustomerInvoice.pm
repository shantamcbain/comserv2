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
    invoice_number => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 0,
        comment     => 'Auto-generated: CUST-YYYYMMDD-NNNN',
    },
    customer_name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    customer_email => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    invoice_date => {
        data_type   => 'date',
        is_nullable => 1,
    },
    user_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK to users table if customer was logged in',
    },
    session_id => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
        comment     => 'Catalyst session ID for guest carts',
    },
    payment_method => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 0,
        default_value => 'cash',
        comment       => 'cash | points | ap',
    },
    payment_status => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 0,
        default_value => 'pending',
        comment       => 'pending | paid | partial | refunded | cancelled',
    },
    subtotal => {
        data_type     => 'decimal',
        size          => [12, 2],
        is_nullable   => 0,
        default_value => '0.00',
    },
    tax_rate => {
        data_type     => 'decimal',
        size          => [5, 4],
        is_nullable   => 1,
        default_value => '0.0000',
        comment       => 'Tax rate as decimal e.g. 0.1300 = 13%',
    },
    tax_amount => {
        data_type     => 'decimal',
        size          => [12, 2],
        is_nullable   => 0,
        default_value => '0.00',
    },
    total_amount => {
        data_type     => 'decimal',
        size          => [12, 2],
        is_nullable   => 0,
        default_value => '0.00',
    },
    points_redeemed => {
        data_type     => 'integer',
        is_nullable   => 1,
        default_value => 0,
        comment       => 'Number of points applied to this invoice',
    },
    amount_paid => {
        data_type     => 'decimal',
        size          => [12, 2],
        is_nullable   => 1,
        default_value => '0.00',
    },
    gl_entry_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK to gl_entries — AR/Income double-entry on checkout',
    },
    status => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 0,
        default_value => 'new',
        comment       => 'new | processing | fulfilled | cancelled',
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    ordered_by => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
        comment     => 'Username if logged in, otherwise guest identifier',
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
__PACKAGE__->add_unique_constraint(unique_invoice_number => ['invoice_number']);

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

1;
