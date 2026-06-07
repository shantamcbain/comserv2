package Comserv::Model::Schema::Forager::Result::Brew::TempLog;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('brew_temp_tb');

# Legacy mash/sparge temperature readings per batch (read-only).

__PACKAGE__->add_columns(
    record_id          => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    sitename           => { data_type => 'varchar', size => 20, is_nullable => 0, default_value => '' },
    spargtemp          => { data_type => 'decimal', size => [8, 2], is_nullable => 0 },
    mastuntemp         => { data_type => 'decimal', size => [8, 2], is_nullable => 0 },
    batchnumber        => { data_type => 'varchar', size => 50, is_nullable => 0, default_value => '' },
    LineTemp           => { data_type => 'decimal', size => [8, 2], is_nullable => 0 },
    last_mod_by        => { data_type => 'varchar', size => 50, is_nullable => 0, default_value => '' },
    time               => { data_type => 'varchar', size => 20, is_nullable => 0, default_value => '' },
    date               => { data_type => 'date',    is_nullable => 0 },
    start_date         => { data_type => 'float',   is_nullable => 0, default_value => 0 },
    last_mod_date      => { data_type => 'varchar', size => 20, is_nullable => 0, default_value => '' },
    start_minute       => { data_type => 'tinyint', is_nullable => 0, default_value => 0 },
    owner              => { data_type => 'varchar', size => 30, is_nullable => 0, default_value => '' },
    group_of_poster    => { data_type => 'varchar', size => 50, is_nullable => 0, default_value => '' },
    username_of_poster => { data_type => 'varchar', size => 50, is_nullable => 0, default_value => '' },
);

__PACKAGE__->set_primary_key('record_id');

__PACKAGE__->belongs_to(
    batch => 'Comserv::Model::Schema::Forager::Result::Brew::Batch',
    { batchnumber => 'batchnumber', sitename => 'sitename' },
    { is_foreign_key_constraint => 0, join_type => 'LEFT' },
);

1;