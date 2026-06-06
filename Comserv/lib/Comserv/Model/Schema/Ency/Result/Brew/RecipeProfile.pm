package Comserv::Model::Schema::Ency::Result::Brew::RecipeProfile;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('brew_recipe_profile');

# Brew-only targets for ency_recipe where recipe_kind = brew_recipe.
# Keeps the shared ency_recipe header narrow; 1:1 with recipe_id.

__PACKAGE__->add_columns(
    recipe_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    style => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
        comment     => 'BJCP or house style name',
    },
    batch_size_l => {
        data_type   => 'decimal',
        size        => [10, 2],
        is_nullable => 1,
    },
    boil_time_min => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    target_og => {
        data_type   => 'decimal',
        size        => [6, 3],
        is_nullable => 1,
    },
    target_fg => {
        data_type   => 'decimal',
        size        => [6, 3],
        is_nullable => 1,
    },
    target_abv => {
        data_type   => 'decimal',
        size        => [5, 2],
        is_nullable => 1,
    },
    target_ibu => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    target_srm => {
        data_type   => 'decimal',
        size        => [6, 2],
        is_nullable => 1,
    },
    efficiency_pct => {
        data_type   => 'decimal',
        size        => [5, 2],
        is_nullable => 1,
    },
    fermentation_days => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    fermentation_temp_c => {
        data_type   => 'decimal',
        size        => [5, 2],
        is_nullable => 1,
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('recipe_id');

__PACKAGE__->belongs_to(
    recipe => 'Comserv::Model::Schema::Ency::Result::Ency::Recipe',
    'recipe_id',
    { is_foreign_key_constraint => 0 },
);

1;