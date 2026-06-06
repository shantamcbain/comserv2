package Comserv::Model::Schema::Ency::Result::Ency::RecipeLine;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('ency_recipe_line');

# Ingredient lines for any ency_recipe (herbal, food, brew).
# Links to ency_herb_tb (plants/herbs) and/or inventory_items when stocked.

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    recipe_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    sort_order => {
        data_type     => 'integer',
        is_nullable   => 1,
        default_value => 0,
    },
    ingredient_source => {
        data_type     => 'varchar',
        size          => 20,
        is_nullable   => 0,
        default_value => 'herb',
        comment       => 'herb | inventory | ad_hoc',
    },
    herb_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK ency_herb_tb.record_id when ingredient_source=herb',
    },
    inventory_item_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK inventory_items.id (malt, hops, yeast, food stock)',
    },
    name_raw => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
        comment     => 'Display name when not linked or ad_hoc',
    },
    botanical_name_raw => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    quantity => {
        data_type   => 'decimal',
        size        => [12, 4],
        is_nullable => 1,
    },
    quantity_text => {
        data_type   => 'varchar',
        size        => 64,
        is_nullable => 1,
        comment     => 'Legacy/free-text qty (e.g. "2-3 cups")',
    },
    unit => {
        data_type   => 'varchar',
        size        => 30,
        is_nullable => 1,
        comment     => 'g, kg, oz, L, ml, tsp, each, %',
    },
    plant_part => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
        comment     => 'root, leaf, flower, grain, hop, yeast',
    },
    process_step => {
        data_type   => 'varchar',
        size        => 64,
        is_nullable => 1,
        comment     => 'mash, boil, fermentation, dry_hop, prep, cook (kind-specific)',
    },
    time_min => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'Duration at this step if applicable',
    },
    is_optional => {
        data_type     => 'tinyint',
        is_nullable   => 0,
        default_value => 0,
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    recipe => 'Comserv::Model::Schema::Ency::Result::Ency::Recipe',
    'recipe_id',
    { is_foreign_key_constraint => 0 },
);

__PACKAGE__->belongs_to(
    herb => 'Comserv::Model::Schema::Ency::Result::Ency::Herb',
    'herb_id',
    { is_foreign_key_constraint => 0, join_type => 'LEFT' },
);

__PACKAGE__->belongs_to(
    inventory_item => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    'inventory_item_id',
    { is_foreign_key_constraint => 0, join_type => 'LEFT' },
);

1;