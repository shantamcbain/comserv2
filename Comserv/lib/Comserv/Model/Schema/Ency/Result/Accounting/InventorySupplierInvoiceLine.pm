package Comserv::Model::Schema::Ency::Result::Accounting::InventorySupplierInvoiceLine;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('inventory_supplier_invoice_lines');

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
        size        => 255,
        is_nullable => 1,
    },
    quantity => {
        data_type     => 'decimal',
        size          => [12, 4],
        is_nullable   => 0,
        default_value => '1.0000',
    },
    unit_cost => {
        data_type     => 'decimal',
        size          => [12, 4],
        is_nullable   => 0,
        default_value => '0.0000',
    },
    line_total => {
        data_type     => 'decimal',
        size          => [12, 2],
        is_nullable   => 0,
        default_value => '0.00',
    },
    account_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    location_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'invoice',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventorySupplierInvoice',
    { 'foreign.id' => 'self.invoice_id' },
    { join_type => 'LEFT' }
);

__PACKAGE__->belongs_to(
    'item',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    { 'foreign.id' => 'self.item_id' },
    { join_type => 'LEFT', on_delete => 'SET NULL' }
);

__PACKAGE__->belongs_to(
    'account',
    'Comserv::Model::Schema::Ency::Result::Accounting::CoaAccount',
    { 'foreign.id' => 'self.account_id' },
    { join_type => 'LEFT', on_delete => 'SET NULL' }
);

__PACKAGE__->belongs_to(
    'location',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryLocation',
    { 'foreign.id' => 'self.location_id' },
    { join_type => 'LEFT', on_delete => 'SET NULL' }
);

1;
