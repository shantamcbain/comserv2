package Comserv::Model::Schema::Ency::Result::Project;
use base 'DBIx::Class::Core';

__PACKAGE__->table('projects');
__PACKAGE__->add_columns(
    id => {
        data_type => 'int',
        is_auto_increment => 1,
    },
    name => {
        data_type => 'varchar',
        size => 255,
    },
    description => {
        data_type => 'text',
    },
    start_date => {
        data_type => 'date',
    },
    end_date => {
        data_type => 'date',
    },
    status => {
        data_type => 'varchar',
        size => 255,
    },
    record_id => {
        data_type => 'int',
    },
    project_code => {
        data_type => 'varchar',
        size => 255,
    },
    project_size => {
        data_type => 'int',
    },
    estimated_man_hours => {
        data_type => 'int',
    },
    developer_name => {
        data_type => 'varchar',
        size => 255,
    },
    client_name => {
        data_type => 'varchar',
        size => 255,
    },
    sitename => {
        data_type => 'varchar',
        size => 255,
    },
    comments => {
        data_type => 'text',
    },
    username_of_poster => {
        data_type => 'varchar',
        size => 255,
    },
    group_of_poster => {
        data_type => 'varchar',
        size => 255,
    },
    date_time_posted => {
        data_type => 'datetime',
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->has_many(todos => 'Comserv::Model::Schema::Ency::Result::Todo', 'project_id', { cascade_delete => 1 });
__PACKAGE__->has_many(project_sites => 'Comserv::Model::Schema::EncyEncy::Result::ProjectSite', 'project_id');
__PACKAGE__->many_to_many(sites => 'project_sites', 'site');
1;