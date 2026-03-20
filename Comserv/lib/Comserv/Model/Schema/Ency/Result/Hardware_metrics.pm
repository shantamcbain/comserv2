package Comserv::Model::Schema::Ency::Result::Hardware_metrics;
use base 'DBIx::Class::Core';

__PACKAGE__->table('hardware_metrics');
__PACKAGE__->add_columns(
    hostname => {
        data_type => 'varchar',
        size => 255,
    },
    id => {
        data_type => 'bigint',
        size => 20,
        is_auto_increment => 1,
    },
    level => {
        data_type => 'varchar',
        size => 20,
        default_value => 'info',
    },
    message => {
        data_type => 'text',
        is_nullable => 1,
    },
    metric_name => {
        data_type => 'varchar',
        size => 100,
    },
    metric_text => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    metric_value => {
        data_type => 'decimal',
        size => 12,3,
        is_nullable => 1,
    },
    system_identifier => {
        data_type => 'varchar',
        size => 255,
    },
    timestamp => {
        data_type => 'datetime',
        default_value => 'current_timestamp()',
    },
    unit => {
        data_type => 'varchar',
        size => 20,
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('id');

1;
