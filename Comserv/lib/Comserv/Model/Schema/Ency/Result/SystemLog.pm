package Comserv::Model::Schema::Ency::Result::SystemLog;
use base 'DBIx::Class::Core';
use strict;
use warnings;

__PACKAGE__->table('system_log');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    timestamp => {
        data_type => 'datetime',
    },
    level => {
        data_type => 'varchar',
        size => 20,
    },
    file => {
        data_type => 'varchar',
        size => 255,
    },
    line => {
        data_type => 'integer',
    },
    subroutine => {
        data_type => 'varchar',
        size => 255,
    },
    message => {
        data_type => 'text',
    },
    sitename => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    username => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('id');

1;
