package Comserv::Model::Schema::Forager::Result::Brew::Batch;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('brew_batch_tb');

# Legacy forager brew runs (read-only; migrate to brew_batch on ENCY).

__PACKAGE__->add_columns(
    record_id          => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    sitename           => { data_type => 'varchar', size => 20, is_nullable => 0, default_value => '' },
    batchnumber        => { data_type => 'varchar', size => 30, is_nullable => 0, default_value => '' },
    name               => { data_type => 'varchar', size => 30, is_nullable => 0, default_value => '' },
    description        => { data_type => 'text',    is_nullable => 0 },
    recipecode         => { data_type => 'varchar', size => 20, is_nullable => 0, default_value => '' },
    status             => { data_type => 'integer', is_nullable => 0 },
    comments           => { data_type => 'text',    is_nullable => 0 },
    last_mod_by        => { data_type => 'varchar', size => 20, is_nullable => 0, default_value => '' },
    time               => { data_type => 'varchar', size => 20, is_nullable => 0, default_value => '' },
    start_date         => { data_type => 'date',    is_nullable => 0 },
    last_mod_date      => { data_type => 'varchar', size => 20, is_nullable => 0, default_value => '' },
    start_minute       => { data_type => 'tinyint', is_nullable => 0, default_value => 0 },
    owner              => { data_type => 'varchar', size => 30, is_nullable => 0, default_value => '' },
    group_of_poster    => { data_type => 'varchar', size => 50, is_nullable => 0, default_value => '' },
    username_of_poster => { data_type => 'varchar', size => 50, is_nullable => 0, default_value => '' },
);

__PACKAGE__->set_primary_key('record_id');

__PACKAGE__->belongs_to(
    recipe => 'Comserv::Model::Schema::Forager::Result::Brew::Recipe',
    { recipe_code => 'recipecode', sitename => 'sitename' },
    { is_foreign_key_constraint => 0, join_type => 'LEFT' },
);

__PACKAGE__->has_many(
    temp_readings => 'Comserv::Model::Schema::Forager::Result::Brew::TempLog',
    { 'foreign.batchnumber' => 'self.batchnumber', 'foreign.sitename' => 'self.sitename' },
    { cascade_copy => 0 },
);

__PACKAGE__->has_many(
    time_events => 'Comserv::Model::Schema::Forager::Result::Brew::TimeEvent',
    { 'foreign.batchnumber' => 'self.batchnumber', 'foreign.sitename' => 'self.sitename' },
    { cascade_copy => 0 },
);

1;