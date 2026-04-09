package Comserv::Model::Schema::Ency::Result::InventoryLocation;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('inventory_locations');

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
    description => {
        data_type   => 'text',
        is_nullable => 1,
    },
    location_type => {
        data_type     => 'varchar',
        size          => 100,
        is_nullable   => 1,
        default_value => 'warehouse',
    },
    address => {
        data_type   => 'text',
        is_nullable => 1,
    },
    status => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 0,
        default_value => 'active',
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
    'stock_levels' => 'Comserv::Model::Schema::Ency::Result::InventoryStockLevel',
    { 'foreign.location_id' => 'self.id' },
    { cascade_delete => 0 }
);

__PACKAGE__->has_many(
    'assignments' => 'Comserv::Model::Schema::Ency::Result::InventoryAssignment',
    { 'foreign.location_id' => 'self.id' },
    { cascade_delete => 0 }
);

1;
