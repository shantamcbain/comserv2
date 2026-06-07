package Comserv::Model::Schema::Forager::Result::Brew::Bbs;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('brew_bbs_tb');

# Legacy brewhouse forum posts (read-only).

__PACKAGE__->add_columns(
    record_id          => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    forum              => { data_type => 'varchar', size => 40, is_nullable => 0, default_value => '' },
    parent_id          => { data_type => 'varchar', size => 30, is_nullable => 0, default_value => '' },
    thread_id          => { data_type => 'varchar', size => 40, is_nullable => 0, default_value => '0' },
    magic              => { data_type => 'varchar', size => 200, is_nullable => 0, default_value => '' },
    email              => { data_type => 'varchar', size => 80, is_nullable => 0, default_value => '' },
    name               => { data_type => 'varchar', size => 80, is_nullable => 0, default_value => '' },
    subject            => { data_type => 'varchar', size => 200, is_nullable => 0, default_value => '' },
    body               => { data_type => 'text',    is_nullable => 0 },
    comments           => { data_type => 'text',    is_nullable => 1 },
    username_of_poster => { data_type => 'varchar', size => 30, is_nullable => 0, default_value => '' },
    group_of_poster    => { data_type => 'varchar', size => 30, is_nullable => 0, default_value => '' },
    date_time_posted   => { data_type => 'varchar', size => 50, is_nullable => 0, default_value => '' },
);

__PACKAGE__->set_primary_key('record_id');

1;