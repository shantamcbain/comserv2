package Comserv::Model::Schema::Ency::Result::HealthKitchen::UserPantryQty;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('hk_user_pantry_qty');

# Personal pantry overlay. Works with or without the site inventory/accounting package.
# When inventory_item_id is set, qty is a personal overlay on that SKU.
# When null, name+qty is the whole pantry row (member-only sites).

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    user_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    inventory_item_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    qty => {
        data_type     => 'decimal',
        size          => [12, 3],
        is_nullable   => 0,
        default_value => '0.000',
    },
    unit => {
        data_type     => 'varchar',
        size          => 30,
        is_nullable   => 0,
        default_value => 'each',
    },
    reorder_point => {
        data_type     => 'decimal',
        size          => [12, 3],
        is_nullable   => 1,
        default_value => '0.000',
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
__PACKAGE__->add_unique_constraint(hk_pantry_user_name => [qw/user_id sitename name/]);

__PACKAGE__->belongs_to(
    inventory_item => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    'inventory_item_id',
    { is_foreign_key_constraint => 0, join_type => 'LEFT' },
);

1;
