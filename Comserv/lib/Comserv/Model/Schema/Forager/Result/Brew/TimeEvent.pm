package Comserv::Model::Schema::Forager::Result::Brew::TimeEvent;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('brew_time_tb');

# Legacy fermentation / brew-day milestone times (read-only).

__PACKAGE__->add_columns(
    record_id          => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    sitename           => { data_type => 'varchar', size => 20, is_nullable => 0, default_value => '' },
    time_code          => { data_type => 'varchar', size => 10, is_nullable => 0 },
    start_mon          => { data_type => 'integer', is_nullable => 0 },
    batchnumber        => { data_type => 'varchar', size => 50, is_nullable => 0, default_value => '' },
    start_day          => { data_type => 'integer', is_nullable => 0 },
    last_mod_by        => { data_type => 'varchar', size => 50, is_nullable => 0, default_value => '' },
    time               => { data_type => 'varchar', size => 20, is_nullable => 0, default_value => '' },
    date               => { data_type => 'date',    is_nullable => 0 },
    start_date         => { data_type => 'float',   is_nullable => 0, default_value => 0 },
    comments           => { data_type => 'text',    is_nullable => 0 },
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