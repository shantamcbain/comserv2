package Comserv::Model::Schema::Ency::Result::System_log;
use base 'DBIx::Class::Core';

__PACKAGE__->table('system_log');
__PACKAGE__->add_columns(
    file => {
        data_type => 'varchar',
        size => 255,
    },
    id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
    level => {
        data_type => 'varchar',
        size => 20,
    },
    line => {
        data_type => 'int',
        size => 11,
    },
    message => {
        data_type => 'text',
    },
    sitename => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    subroutine => {
        data_type => 'varchar',
        size => 255,
    },
    system_identifier => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    timestamp => {
        data_type => 'datetime',
    },
    username => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('id');

1;
