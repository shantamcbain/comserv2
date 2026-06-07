package Comserv::Model::Schema::Forager::Result::Brew::CalEvent;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('brew_cal_event');

# Legacy brewhouse calendar events (read-only).
# Migrate into Planning todos / calendar — not a separate Brew calendar app.

__PACKAGE__->add_columns(
    record_id          => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    type               => { data_type => 'varchar', size => 30, is_nullable => 0, default_value => '' },
    priority           => { data_type => 'varchar', size => 30, is_nullable => 0, default_value => '' },
    location           => { data_type => 'varchar', size => 50, is_nullable => 0, default_value => '' },
    last_mod_by        => { data_type => 'varchar', size => 50, is_nullable => 0, default_value => '' },
    start_date         => { data_type => 'varchar', size => 20, is_nullable => 0, default_value => '' },
    end_date           => { data_type => 'varchar', size => 20, is_nullable => 0, default_value => '' },
    start_day          => { data_type => 'float',   is_nullable => 0, default_value => 0 },
    last_mod_date      => { data_type => 'varchar', size => 20, is_nullable => 0, default_value => '' },
    recur_until_date   => { data_type => 'varchar', size => 20, is_nullable => 0, default_value => '' },
    recur_interval     => { data_type => 'varchar', size => 10, is_nullable => 0, default_value => '0' },
    end_minute         => { data_type => 'tinyint', is_nullable => 0, default_value => 0 },
    subject            => { data_type => 'varchar', size => 75, is_nullable => 0, default_value => '' },
    description        => { data_type => 'text',    is_nullable => 0 },
    status             => { data_type => 'varchar', size => 25, is_nullable => 0, default_value => '' },
    owner              => { data_type => 'varchar', size => 30, is_nullable => 0, default_value => '' },
    username_of_poster => { data_type => 'varchar', size => 50, is_nullable => 0, default_value => '' },
    group_of_poster    => { data_type => 'varchar', size => 50, is_nullable => 0, default_value => '' },
);

__PACKAGE__->set_primary_key('record_id');

1;