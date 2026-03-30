package Comserv::Model::Schema::Ency::Result::AccessLog;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('access_log');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'bigint',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    timestamp => {
        data_type     => 'datetime',
        is_nullable   => 0,
        default_value => \'CURRENT_TIMESTAMP',
    },
    sitename => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    path => {
        data_type   => 'varchar',
        size        => 512,
        is_nullable => 0,
    },
    request_method => {
        data_type   => 'varchar',
        size        => 10,
        is_nullable => 1,
    },
    status_code => {
        data_type   => 'smallint',
        is_nullable => 1,
    },
    ip_address => {
        data_type   => 'varchar',
        size        => 45,
        is_nullable => 1,
    },
    user_agent => {
        data_type   => 'varchar',
        size        => 512,
        is_nullable => 1,
    },
    referer => {
        data_type   => 'varchar',
        size        => 512,
        is_nullable => 1,
    },
    request_type => {
        data_type   => 'varchar',
        size        => 20,
        is_nullable => 1,
    },
    username => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    session_id => {
        data_type   => 'varchar',
        size        => 128,
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
