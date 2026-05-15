package Comserv::Model::Schema::Ency::Result::UserScheduleSettings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('user_schedule_settings');
__PACKAGE__->add_columns(
    default_duration_min => {
        data_type => 'int',
        size => 11,
        default_value => '15',
    },
    id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
    timezone => {
        data_type => 'varchar',
        size => 100,
        default_value => 'UTC',
    },
    updated_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
    },
    username => {
        data_type => 'varchar',
        size => 255,
    },
    work_days => {
        data_type => 'tinyint(3) unsigned',
        default_value => '62',
    },
    work_segments => {
        data_type => 'longtext',
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('uq_username' => ['username']);

1;
