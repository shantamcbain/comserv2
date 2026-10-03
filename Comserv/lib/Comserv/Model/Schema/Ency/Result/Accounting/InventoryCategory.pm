package Comserv::Model::Schema::Ency::Result::Accounting::InventoryCategory;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('inventory_categories');

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
    parent_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    sort_order => {
        data_type     => 'integer',
        is_nullable   => 0,
        default_value => 0,
    },
    is_active => {
        data_type     => 'smallint',
        is_nullable   => 0,
        default_value => 1,
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
__PACKAGE__->add_unique_constraint(unique_category_per_site => ['sitename', 'name', 'parent_id']);

__PACKAGE__->belongs_to(
    'parent',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryCategory',
    { 'foreign.id' => 'self.parent_id' },
    { join_type => 'LEFT', on_delete => 'SET NULL' }
);

__PACKAGE__->has_many(
    'children',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryCategory',
    { 'foreign.parent_id' => 'self.id' },
    { cascade_delete => 0 }
);

__PACKAGE__->has_many(
    'item_links',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItemCategory',
    { 'foreign.category_id' => 'self.id' },
    { cascade_delete => 1 }
);

__PACKAGE__->many_to_many(
    'items' => 'item_links', 'item'
);

1;