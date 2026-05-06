package Comserv::Model::Schema::Ency::Result::Accounting::InventoryEquipment;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('inventory_equipment');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    item_id => {
        data_type      => 'integer',
        is_nullable    => 0,
        is_foreign_key => 1,
    },
    wattage => {
        data_type     => 'integer',
        is_nullable   => 1,
        default_value => undef,
        extra         => { unsigned => 1 },
        accessor      => 'wattage',
    },
    depreciation_per_hour => {
        data_type     => 'decimal',
        size          => [10, 6],
        is_nullable   => 1,
        default_value => undef,
    },
    serial_number => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    purchase_price => {
        data_type     => 'decimal',
        size          => [10, 2],
        is_nullable   => 1,
        default_value => undef,
    },
    lease_from_sitename => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    lease_term_months => {
        data_type     => 'integer',
        is_nullable   => 1,
        default_value => undef,
    },
    voltage => {
        data_type   => 'varchar',
        size        => 20,
        is_nullable => 1,
    },
    notes => {
        data_type   => 'text',
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
__PACKAGE__->add_unique_constraint(['item_id']);

__PACKAGE__->belongs_to(
    'item',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    { 'foreign.id' => 'self.item_id' },
    { on_delete => 'CASCADE' }
);

1;
