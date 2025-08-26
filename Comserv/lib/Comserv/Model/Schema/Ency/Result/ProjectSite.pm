package Comserv::Model::Schema::Ency::Result::ProjectSite;
use base 'DBIx::Class::Core';

__PACKAGE__->table('project_sites');
__PACKAGE__->add_columns(
    project_id => {
        data_type => 'int',
    },
    site_id => {
        data_type => 'int',
    },
);
__PACKAGE__->set_primary_key('project_id', 'site_id');
__PACKAGE__->belongs_to(project => 'Comserv::Model::Schema::Ency::Result::Project', 'project_id');
__PACKAGE__->belongs_to(site => 'Comserv::Model::Schema::Ency::Result::Site', 'site_id');

1;