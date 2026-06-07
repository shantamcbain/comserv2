package Comserv::Model::Schema::Ency::Result::Brew::Batch;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('brew_batch');

# Actual brew run (instance), not the recipe definition.

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    recipe_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK ency_recipe.id; null for one-off batches',
    },
    batch_code => {
        data_type   => 'varchar',
        size        => 32,
        is_nullable => 1,
    },
    name => {
        data_type   => 'varchar',
        size        => 255,
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
        default_value => 'planned',
        comment       => 'planned | brewing | fermenting | conditioning | packaged | archived',
    },
    brew_date => {
        data_type => 'date',
        is_nullable => 1,
    },
    package_date => {
        data_type => 'date',
        is_nullable => 1,
    },
    volume_l => {
        data_type   => 'decimal',
        size        => [10, 2],
        is_nullable => 1,
    },
    actual_og => {
        data_type   => 'decimal',
        size        => [6, 3],
        is_nullable => 1,
    },
    actual_fg => {
        data_type   => 'decimal',
        size        => [6, 3],
        is_nullable => 1,
    },
    actual_abv => {
        data_type   => 'decimal',
        size        => [5, 2],
        is_nullable => 1,
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    created_by => {
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
__PACKAGE__->add_unique_constraint(brew_batch_code_site => [qw/batch_code sitename/]);

__PACKAGE__->belongs_to(
    recipe => 'Comserv::Model::Schema::Ency::Result::Ency::Recipe',
    'recipe_id',
    { is_foreign_key_constraint => 0, join_type => 'LEFT' },
);

1;