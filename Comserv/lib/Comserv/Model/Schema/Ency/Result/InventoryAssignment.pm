package Comserv::Model::Schema::Ency::Result::InventoryAssignment;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('inventory_assignments');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    item_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    location_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    assigned_to => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    assigned_to_type => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 1,
        default_value => 'user',
    },
    quantity => {
        data_type   => 'decimal',
        size        => [12, 3],
        is_nullable => 0,
        default_value => '1.000',
    },
    todo_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
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
    assigned_by => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    assigned_at => {
        data_type     => 'datetime',
        is_nullable   => 1,
        set_on_create => 1,
    },
    returned_at => {
        data_type   => 'datetime',
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

__PACKAGE__->belongs_to(
    'item' => 'Comserv::Model::Schema::Ency::Result::InventoryItem',
    { 'foreign.id' => 'self.item_id' }
);

__PACKAGE__->belongs_to(
    'location' => 'Comserv::Model::Schema::Ency::Result::InventoryLocation',
    { 'foreign.id' => 'self.location_id' },
    { join_type => 'LEFT' }
);

__PACKAGE__->belongs_to(
    'todo' => 'Comserv::Model::Schema::Ency::Result::Todo',
    { 'foreign.record_id' => 'self.todo_id' },
    { join_type => 'LEFT' }
);

1;
