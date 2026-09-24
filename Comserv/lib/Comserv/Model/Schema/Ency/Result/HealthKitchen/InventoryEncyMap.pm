package Comserv::Model::Schema::Ency::Result::HealthKitchen::InventoryEncyMap;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('hk_inventory_ency_map');

# Links a sitename inventory SKU to ENCY knowledge (herb / organism / animal / insect / formula).
# Create via Admin schema-compare. Do not query until the table exists.

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
    inventory_item_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    herb_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    organism_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    animal_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    insect_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    formula_id => {
        data_type   => 'integer',
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
__PACKAGE__->add_unique_constraint(hk_map_item_site => [qw/inventory_item_id sitename/]);

__PACKAGE__->belongs_to(
    inventory_item => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    'inventory_item_id',
    { is_foreign_key_constraint => 0, join_type => 'LEFT' },
);

__PACKAGE__->belongs_to(
    herb => 'Comserv::Model::Schema::Ency::Result::Ency::Herb',
    'herb_id',
    { is_foreign_key_constraint => 0, join_type => 'LEFT' },
);

1;
