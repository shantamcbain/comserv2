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
        comment     => 'FK to inventory_items (nullable in case item is later deleted)',
    },
    sku => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
        comment     => 'Snapshot of SKU at time of order',
    },
    item_name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
        comment     => 'Snapshot of item name at time of order',
    },
    quantity => {
        data_type   => 'decimal',
        size        => [12, 3],
        is_nullable => 0,
    },
    unit_price => {
        data_type   => 'decimal',
        size        => [10, 2],
        is_nullable => 0,
        comment     => 'Price per unit at time of order',
    },
    line_total => {
        data_type   => 'decimal',
        size        => [12, 2],
        is_nullable => 0,
        comment     => 'quantity * unit_price',
    },
    options => {
        data_type   => 'text',
        is_nullable => 1,
        comment     => 'JSON: custom options like print settings, colour, material etc.',
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
    'invoice' => 'Comserv::Model::Schema::Ency::Result::InventoryCustomerInvoice',
    { 'foreign.id' => 'self.invoice_id' }
);

__PACKAGE__->belongs_to(
    'item' => 'Comserv::Model::Schema::Ency::Result::InventoryItem',
    { 'foreign.id' => 'self.item_id' },
    { join_type => 'LEFT', on_delete => 'SET NULL' }
);

sub total_value {
    my $self = shift;
    return ($self->quantity || 0) * ($self->unit_price || 0);
}

1;
