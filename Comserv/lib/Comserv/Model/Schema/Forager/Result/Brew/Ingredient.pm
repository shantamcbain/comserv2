package Comserv::Model::Schema::Forager::Result::Brew::Ingredient;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('brew_ingrediant_tb');

# Legacy recipe lines / stock (read-only; migrate to ency_recipe_line).

__PACKAGE__->add_columns(
    record_id          => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    sitename           => { data_type => 'varchar', size => 20,  is_nullable => 0, default_value => '' },
    item_code          => { data_type => 'varchar', size => 30,  is_nullable => 0, default_value => '' },
    ingrediant_name    => { data_type => 'varchar', size => 50,  is_nullable => 0 },
    recipe_code        => { data_type => 'varchar', size => 30,  is_nullable => 0, default_value => '' },
    description        => { data_type => 'text',    is_nullable => 0 },
    stock              => { data_type => 'varchar', size => 50,  is_nullable => 0, default_value => '' },
    weight             => { data_type => 'decimal', size => [10, 2], is_nullable => 0 },
    bill               => { data_type => 'varchar', size => 10,  is_nullable => 0, default_value => '' },
    comments           => { data_type => 'text',    is_nullable => 0 },
    unit               => { data_type => 'varchar', size => 5,   is_nullable => 0, default_value => '' },
    last_mod_by        => { data_type => 'varchar', size => 20,  is_nullable => 0, default_value => '' },
    end_date           => { data_type => 'varchar', size => 20,  is_nullable => 0, default_value => '' },
    start_day          => { data_type => 'float',   is_nullable => 0, default_value => 0 },
    last_mod_date      => { data_type => 'varchar', size => 20,  is_nullable => 0, default_value => '' },
    start_minute       => { data_type => 'tinyint', is_nullable => 0, default_value => 0 },
    owner              => { data_type => 'varchar', size => 30,  is_nullable => 0, default_value => '' },
    group_of_poster    => { data_type => 'varchar', size => 50,  is_nullable => 0, default_value => '' },
    username_of_poster => { data_type => 'varchar', size => 50,  is_nullable => 0, default_value => '' },
);

__PACKAGE__->set_primary_key('record_id');

__PACKAGE__->belongs_to(
    recipe => 'Comserv::Model::Schema::Forager::Result::Brew::Recipe',
    { recipe_code => 'recipe_code', sitename => 'sitename' },
    { is_foreign_key_constraint => 0, join_type => 'LEFT' },
);

1;