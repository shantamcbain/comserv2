package Comserv::Model::Schema::Ency::Result::SystemLog;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('system_log');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    timestamp => {
        data_type   => 'datetime',
        is_nullable => 0,
    },
    level => {
        data_type   => 'varchar',
        size        => 20,
        is_nullable => 0,
    },
    file => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    line => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    subroutine => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    message => {
        data_type   => 'text',
        is_nullable => 0,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    username => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    system_identifier => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

1;
