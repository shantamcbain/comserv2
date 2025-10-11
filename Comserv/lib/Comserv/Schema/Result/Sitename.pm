package Comserv::Schema::Result::Sitename;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('sitename');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
        is_nullable => 0,
    },
    name => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    domain => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    # Add any other columns that exist in the sitename table
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['name']);

1;