package Comserv::Model::Schema::Ency::Result::UserScheduleSettings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('user_schedule_settings');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        size              => 11,
        is_auto_increment => 1,
    },
    username => {
        data_type => 'varchar',
        size      => 255,
    },
    timezone => {
        data_type     => 'varchar',
        size          => 100,
        default_value => 'UTC',
    },
    work_segments => {
        data_type     => 'longtext',
        default_value => '[{"start":"08:00","end":"17:00"}]',
    },
    work_days => {
        data_type     => 'tinyint',
        default_value => 62,
    },
    default_duration_min => {
        data_type     => 'int',
        size          => 11,
        default_value => 15,
    },
    updated_at => {
        data_type     => 'timestamp',
        default_value => 'current_timestamp()',
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('uq_username' => ['username']);

1;
