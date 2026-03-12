package Comserv::Model::Schema::Ency::Result::ApplicationLog;
use base 'DBIx::Class::Core';

__PACKAGE__->table('application_log');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    app_instance => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
        default_value => 'unknown',
    },
    log_level => {
        data_type   => 'varchar',
        size        => 20,
        is_nullable => 0,
        default_value => 'INFO',
    },
    category => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 0,
        default_value => 'GENERAL',
    },
    event_type => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    message => {
        data_type   => 'text',
        is_nullable => 0,
    },
    details => {
        data_type   => 'text',
        is_nullable => 1,
    },
    source_file => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    source_line => {
        data_type   => 'int',
        is_nullable => 1,
    },
    subroutine => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    hostname => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    pid => {
        data_type   => 'int',
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'datetime',
        is_nullable   => 0,
        default_value => \'NOW()',
    },
    evaluated => {
        data_type     => 'tinyint',
        is_nullable   => 0,
        default_value => 0,
    },
    evaluation_score => {
        data_type   => 'int',
        is_nullable => 1,
    },
    pruned => {
        data_type     => 'tinyint',
        is_nullable   => 0,
        default_value => 0,
    },
    occurrence_count => {
        data_type     => 'int',
        is_nullable   => 0,
        default_value => 1,
    },
);

__PACKAGE__->set_primary_key('id');

1;
