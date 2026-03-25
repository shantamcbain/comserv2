package Comserv::Model::Schema::Ency::Result::Health_alert;
use base 'DBIx::Class::Core';

__PACKAGE__->table('health_alert');
__PACKAGE__->add_columns(
    category => {
        data_type => 'varchar',
        size => 100,
    },
    description => {
        data_type => 'text',
    },
    first_seen => {
        data_type => 'datetime',
    },
    id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
    last_seen => {
        data_type => 'datetime',
    },
    level => {
        data_type => 'varchar',
        size => 20,
    },
    notes => {
        data_type => 'text',
        is_nullable => 1,
    },
    occurrence_count => {
        data_type => 'int',
        size => 11,
        default_value => '1',
    },
    resolved_at => {
        data_type => 'datetime',
        is_nullable => 1,
    },
    sitename => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    status => {
        data_type => 'varchar',
        size => 20,
        default_value => 'OPEN',
    },
    system_identifier => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('id');

1;
