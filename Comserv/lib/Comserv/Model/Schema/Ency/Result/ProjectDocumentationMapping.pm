package Comserv::Model::Schema::Ency::Result::ProjectDocumentationMapping;
use base 'DBIx::Class::Core';

__PACKAGE__->table('project_documentation_mapping');
__PACKAGE__->add_columns(
    id => {
        data_type => 'int',
        is_auto_increment => 1,
    },
    project_id => {
        data_type => 'int',
        is_nullable => 0,
    },
    documentation_path => {
        data_type => 'varchar',
        size => 500,
        is_nullable => 0,
    },
    is_primary => {
        data_type => 'tinyint',
        default_value => 0,
    },
    display_order => {
        data_type => 'int',
        is_nullable => 1,
    },
    created_at => {
        data_type => 'datetime',
        is_nullable => 0,
        set_on_create => 1,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->belongs_to(project => 'Comserv::Model::Schema::Ency::Result::Project', 'project_id');

1;
