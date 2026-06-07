package Comserv::Model::Schema::Ency::Result::SystemModule;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

__PACKAGE__->table('system_modules');

__PACKAGE__->add_columns(
    key => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 0,
    },
    name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    owner => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 0,
    },
    description => {
        data_type   => 'text',
        is_nullable => 1,
    },
    route => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    monthly_cost => {
        data_type     => 'decimal',
        size          => [10, 2],
        default_value => '0.00',
        is_nullable   => 0,
    },
    is_active => {
        data_type     => 'tinyint',
        default_value => 1,
        is_nullable   => 0,
    },
    created_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable   => 0,
    },
    updated_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
        is_nullable   => 0,
    },
);

__PACKAGE__->set_primary_key('key');

1;
