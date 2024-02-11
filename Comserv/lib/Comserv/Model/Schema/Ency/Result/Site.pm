package Comserv::Model::Schema::Ency::Result::Site;
use base 'DBIx::Class::Core';

__PACKAGE__->table('sites');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    name => {
        data_type => 'varchar',
        size => 255,
    },
    description => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->has_many(user_sites => 'Comserv::Model::Schema::Ency::Result::UserSite', 'site_id');
__PACKAGE__->many_to_many(users => 'user_sites', 'user');
__PACKAGE__->has_many(project_sites => 'Comserv::Model::Schema::Result::ProjectSite', 'site_id');
__PACKAGE__->many_to_many(projects => 'project_sites', 'project');
1;