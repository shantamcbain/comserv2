package Comserv::Model::Schema::Ency::Result::Accounting::InventoryItemCategory;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('inventory_item_categories');

__PACKAGE__->add_columns(
    item_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    category_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    created_at => {
        data_type     => 'datetime',
        is_nullable   => 1,
        set_on_create => 1,
    },
);

__PACKAGE__->set_primary_key('item_id', 'category_id');

__PACKAGE__->belongs_to(
    'item',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    { 'foreign.id' => 'self.item_id' },
    { on_delete => 'CASCADE' }
);

__PACKAGE__->belongs_to(
    'category',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryCategory',
    { 'foreign.id' => 'self.category_id' },
    { on_delete => 'CASCADE' }
);

1;