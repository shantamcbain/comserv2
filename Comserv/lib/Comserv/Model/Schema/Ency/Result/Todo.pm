package Comserv::Model::Schema::Ency::Result::Todo;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

__PACKAGE__->table('todo');
__PACKAGE__->add_columns(
    record_id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    sitename => {
        data_type => 'varchar',
        size => 255,
    },
    start_date => {
        data_type => 'date',
    },
    parent_todo => {
        data_type => 'varchar',
    },
    due_date => {
        data_type => 'date',
        is_nullable => 0,
    },
    subject => {
        data_type => 'varchar',
        size => 255,
    },
    description => {
        data_type => 'text',
    },
    estimated_man_hours => {
        data_type => 'integer',
    },
    comments => {
        data_type => 'text',
        is_nullable => 1,
    },
    accumulative_time => {
        data_type => 'integer',
    },
    reporter => {
        data_type => 'varchar',
        default_value => "",
        is_nullable => 1,
        size => 50,
    },
    company_code => {
        data_type => 'varchar',
        default_value => "",
        is_nullable => 1,
        size => 30,
    },
    owner => {
        data_type => 'varchar',
        default_value => "",
        is_nullable => 1,
        size => 30,
    },
    project_code => {
        data_type => 'varchar',
        size => 255,
    },
    developer => {
        data_type => 'varchar',
        default_value => "",
        is_nullable => 1,
        size => 50,
    },
    username_of_poster => {
        data_type => 'varchar',
        default_value => "",
        is_nullable => 1,
        size => 30,
    },
    status => {
        data_type => 'varchar',
        size => 255,
    },
    priority => {
        data_type => 'integer',
    },
    share => {
        data_type => 'integer',
    },
    last_mod_by => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
        default_value => 'system',
    },
    last_mod_date => {
        data_type => 'date',
    },
    group_of_poster => {
        data_type => 'varchar',
        size => 255,
    },
    user_id => {
        data_type => 'integer',
    },
    project_id => {
        data_type => 'integer',
    },
    date_time_posted => {
        data_type => 'varchar',
        default_value => "",
        is_nullable => 1,
        size => 30,
    },
);

__PACKAGE__->set_primary_key('record_id');
__PACKAGE__->has_many(
    'logs' => 'Comserv::Model::Schema::Ency::Result::Log',
    { 'foreign.todo_record_id' => 'self.record_id' },
    { cascade_delete => 1 }
);
__PACKAGE__->belongs_to(user => 'Comserv::Model::Schema::Ency::Result::User', 'user_id');
__PACKAGE__->belongs_to(project => 'Comserv::Model::Schema::Ency::Result::Project', 'project_id');

1;
