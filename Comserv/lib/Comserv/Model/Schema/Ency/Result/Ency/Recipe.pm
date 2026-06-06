package Comserv::Model::Schema::Ency::Result::Ency::Recipe;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('ency_recipe');

# Unified recipe / formula header (herbal, food, brew, and future kinds).
# Line items: ency_recipe_line. Brew targets: brew_recipe_profile (1:1).
# Legacy herbal data remains in usbm_formula_tb until migrated.

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    recipe_code => {
        data_type   => 'varchar',
        size        => 32,
        is_nullable => 1,
        comment     => 'Human or site-specific code (e.g. BRW-001, F-42)',
    },
    name => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 0,
    },
    recipe_kind => {
        data_type     => 'varchar',
        size          => 32,
        is_nullable   => 0,
        default_value => 'herbal_formula',
        comment       => 'herbal_formula | food_recipe | brew_recipe | other',
    },
    description => {
        data_type   => 'text',
        is_nullable => 1,
    },
    preparation => {
        data_type   => 'text',
        is_nullable => 1,
        comment     => 'Prep / mash / decoction instructions',
    },
    instructions => {
        data_type   => 'text',
        is_nullable => 1,
        comment     => 'Step-by-step method (food/brew process)',
    },
    yield_amount => {
        data_type   => 'decimal',
        size        => [12, 4],
        is_nullable => 1,
    },
    yield_unit => {
        data_type   => 'varchar',
        size        => 30,
        is_nullable => 1,
        comment     => 'L, gal, servings, g, batch',
    },
    indications => {
        data_type   => 'text',
        is_nullable => 1,
        comment     => 'Herbal: conditions / TCM pattern',
    },
    dosage => {
        data_type   => 'text',
        is_nullable => 1,
    },
    administration => {
        data_type   => 'text',
        is_nullable => 1,
    },
    servings => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'Food: portion count',
    },
    cook_time_min => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    cuisine => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    reference => {
        data_type   => 'text',
        is_nullable => 1,
    },
    source => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    image => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    url => {
        data_type   => 'text',
        is_nullable => 1,
    },
    sitename => {
        data_type     => 'varchar',
        size          => 100,
        is_nullable   => 1,
        default_value => 'Brew',
    },
    status => {
        data_type     => 'varchar',
        size          => 20,
        is_nullable   => 0,
        default_value => 'active',
        comment       => 'draft | active | archived',
    },
    legacy_formula_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK usbm_formula_tb.record_id when migrated from Formula',
    },
    username_of_poster => {
        data_type   => 'varchar',
        size        => 50,
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
__PACKAGE__->add_unique_constraint(ency_recipe_code_site => [qw/recipe_code sitename/]);

__PACKAGE__->has_many(
    lines => 'Comserv::Model::Schema::Ency::Result::Ency::RecipeLine',
    'recipe_id',
    { cascade_delete => 1 },
);

__PACKAGE__->might_have(
    brew_profile => 'Comserv::Model::Schema::Ency::Result::Brew::RecipeProfile',
    'recipe_id',
    { cascade_delete => 1 },
);

__PACKAGE__->has_many(
    brew_batches => 'Comserv::Model::Schema::Ency::Result::Brew::Batch',
    'recipe_id',
);

1;