package Comserv::Model::Schema::Ency::Result::HardwareMetrics;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('hardware_metrics');
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
    system_identifier => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    hostname => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    metric_name => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 0,
    },
    metric_value => {
        data_type     => 'decimal',
        size          => [12, 3],
        is_nullable   => 1,
    },
    metric_text => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    unit => {
        data_type   => 'varchar',
        size        => 20,
        is_nullable => 1,
    },
    level => {
        data_type     => 'varchar',
        size          => 20,
        is_nullable   => 0,
        default_value => 'info',
    },
    message => {
        data_type   => 'text',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

1;
