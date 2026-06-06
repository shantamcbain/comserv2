package Comserv::Model::Schema::Forager::Result::Brew::Recipe;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('brew_recipe_tb');

# Legacy forager brewhouse recipes (read-only source for migration to ency_recipe).

__PACKAGE__->add_columns(
    record_id           => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    sitename            => { data_type => 'varchar', size => 20,  is_nullable => 0, default_value => '' },
    recipe_code         => { data_type => 'varchar', size => 30,  is_nullable => 0, default_value => '' },
    recipe_name         => { data_type => 'varchar', size => 30,  is_nullable => 0, default_value => '' },
    recipe_size         => { data_type => 'float',   is_nullable => 0 },
    category            => { data_type => 'text',    is_nullable => 0 },
    gravity             => { data_type => 'decimal', size => [4, 0], is_nullable => 0 },
    ingredients         => { data_type => 'text',    is_nullable => 0 },
    instructions        => { data_type => 'text',    is_nullable => 0 },
    alcohol             => { data_type => 'varchar', size => 52,  is_nullable => 0, default_value => '' },
    colour              => { data_type => 'varchar', size => 50,  is_nullable => 0, default_value => '' },
    ph                  => { data_type => 'integer', is_nullable => 0 },
    bitterness          => { data_type => 'varchar', size => 50,  is_nullable => 0, default_value => '' },
    maturation          => { data_type => 'varchar', size => 50,  is_nullable => 0, default_value => '' },
    boiltime            => { data_type => 'time',    is_nullable => 0 },
    description         => { data_type => 'text',    is_nullable => 0 },
    comments            => { data_type => 'text',    is_nullable => 0 },
    last_mod_by         => { data_type => 'varchar', size => 50,  is_nullable => 0, default_value => '' },
    time                => { data_type => 'varchar', size => 20,  is_nullable => 0, default_value => '' },
    end_date            => { data_type => 'varchar', size => 20,  is_nullable => 0, default_value => '' },
    start_day           => { data_type => 'float',   is_nullable => 0, default_value => 0 },
    last_mod_date       => { data_type => 'varchar', size => 20,  is_nullable => 0, default_value => '' },
    start_minute        => { data_type => 'tinyint', is_nullable => 0, default_value => 0 },
    owner               => { data_type => 'varchar', size => 30,  is_nullable => 0, default_value => '' },
    group_of_poster     => { data_type => 'varchar', size => 50,  is_nullable => 0, default_value => '' },
    username_of_poster  => { data_type => 'varchar', size => 50,  is_nullable => 0, default_value => '' },
    mashtontemp         => { data_type => 'float',   is_nullable => 0 },
    spargtemp           => { data_type => 'float',   is_nullable => 0 },
    mashtemp            => { data_type => 'float',   is_nullable => 0 },
    mashduration        => { data_type => 'time',    is_nullable => 0 },
    status              => { data_type => 'varchar', size => 10,  is_nullable => 0, default_value => '' },
);

__PACKAGE__->set_primary_key('record_id');

__PACKAGE__->has_many(
    ingredients => 'Comserv::Model::Schema::Forager::Result::Brew::Ingredient',
    { 'foreign.recipe_code' => 'self.recipe_code', 'foreign.sitename' => 'self.sitename' },
    { cascade_copy => 0 },
);

__PACKAGE__->has_many(
    batches => 'Comserv::Model::Schema::Forager::Result::Brew::Batch',
    { 'foreign.recipecode' => 'self.recipe_code', 'foreign.sitename' => 'self.sitename' },
    { cascade_copy => 0 },
);

1;