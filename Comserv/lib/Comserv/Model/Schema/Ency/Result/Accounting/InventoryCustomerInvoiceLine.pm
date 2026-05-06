package Comserv::Model::Schema::Ency::Result::Accounting::InventoryCustomerInvoiceLine;
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
    sku => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    item_name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    description => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    quantity => {
        data_type     => 'decimal',
        size          => [12, 3],
        is_nullable   => 0,
        default_value => '1.000',
    },
    unit_price => {
        data_type     => 'decimal',
        size          => [10, 2],
        is_nullable   => 0,
        default_value => '0.00',
    },
    unit_cost => {
        data_type     => 'decimal',
        size          => [10, 2],
        is_nullable   => 1,
        default_value => '0.00',
    },
    line_total => {
        data_type     => 'decimal',
        size          => [12, 2],
        is_nullable   => 0,
        default_value => '0.00',
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
    options => {
        data_type   => 'text',
        is_nullable => 1,
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    sort_order => {
        data_type     => 'integer',
        is_nullable   => 1,
        default_value => 0,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'invoice' => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryCustomerInvoice',
    { 'foreign.id' => 'self.invoice_id' }
);

__PACKAGE__->belongs_to(
    'item' => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    { 'foreign.id' => 'self.item_id' },
    { join_type => 'LEFT', on_delete => 'SET NULL' }
);

sub total_value {
    my $self = shift;
    return ($self->quantity || 0) * ($self->unit_price || 0);
}

1;
