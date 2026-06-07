package Comserv::Model::Schema::Forager::Result::Brew::BrewLog;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('brewlog_tb');

# Older brew log table (superseded by brew_temp_tb for most data; read-only).

__PACKAGE__->add_columns(
    record_id          => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    sitename           => { data_type => 'varchar', size => 20, is_nullable => 0, default_value => '' },
    spargtemp          => { data_type => 'varchar', size => 30, is_nullable => 0, default_value => '' },
    mastuntemp         => { data_type => 'varchar', size => 30, is_nullable => 0, default_value => '' },
    batchnumber        => { data_type => 'varchar', size => 50, is_nullable => 0, default_value => '' },
    last_mod_by        => { data_type => 'varchar', size => 50, is_nullable => 0, default_value => '' },
    time               => { data_type => 'varchar', size => 20, is_nullable => 0, default_value => '' },
    end_date           => { data_type => 'varchar', size => 20, is_nullable => 0, default_value => '' },
    start_day          => { data_type => 'float',   is_nullable => 0, default_value => 0 },
    last_mod_date      => { data_type => 'varchar', size => 20, is_nullable => 0, default_value => '' },
    start_minute       => { data_type => 'tinyint', is_nullable => 0, default_value => 0 },
    owner              => { data_type => 'varchar', size => 30, is_nullable => 0, default_value => '' },
    group_of_poster    => { data_type => 'varchar', size => 50, is_nullable => 0, default_value => '' },
    username_of_poster => { data_type => 'varchar', size => 50, is_nullable => 0, default_value => '' },
);

__PACKAGE__->set_primary_key('record_id');

1;