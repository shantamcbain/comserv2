package Comserv::Model::Schema::Forager::Result::Brew::Faq;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('brew_faq_tb');

# Legacy brewhouse FAQ (read-only).

__PACKAGE__->add_columns(
    record_id          => { data_type => 'tinyint', is_auto_increment => 1, is_nullable => 0 },
    category           => { data_type => 'varchar', size => 150, is_nullable => 0, default_value => '' },
    question           => { data_type => 'text',    is_nullable => 0 },
    answer             => { data_type => 'text',    is_nullable => 0 },
    username_of_poster => { data_type => 'varchar', size => 30, is_nullable => 0, default_value => '' },
    date_time_posted   => { data_type => 'varchar', size => 50, is_nullable => 0, default_value => '' },
);

__PACKAGE__->set_primary_key('record_id');

1;