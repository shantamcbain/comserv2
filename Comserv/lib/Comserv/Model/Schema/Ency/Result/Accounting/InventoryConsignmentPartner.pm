package Comserv::Model::Schema::Ency::Result::Accounting::InventoryConsignmentPartner;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('inventory_consignment_partners');

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
    name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    contact_name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    phone => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    email => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    address => {
        data_type   => 'text',
        is_nullable => 1,
    },
    commission_percent => {
        data_type     => 'decimal',
        size          => [5, 2],
        is_nullable   => 0,
        default_value => 0,
    },
    payment_terms => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    status => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 0,
        default_value => 'active',
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
    'consignments',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryConsignment',
    { 'foreign.partner_id' => 'self.id' },
    { cascade_delete => 0 }
);

1;
