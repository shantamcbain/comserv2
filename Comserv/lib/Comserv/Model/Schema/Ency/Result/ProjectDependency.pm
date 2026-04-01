package Comserv::Model::Schema::Ency::Result::ProjectDependency;
use base 'DBIx::Class::Core';

__PACKAGE__->table('project_dependencies');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    project_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    depends_on_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    dependency_type => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 0,
        default_value => 'blocks',
    },
    description => {
        data_type     => 'text',
        is_nullable   => 0,
        default_value => '',
    },
    status => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 0,
        default_value => 'active',
    },
    sitename => {
        data_type     => 'varchar',
        size          => 100,
        is_nullable   => 0,
        default_value => 'CSC',
    },
    created_by => {
        data_type     => 'varchar',
        size          => 100,
        is_nullable   => 0,
        default_value => 'system',
    },
    created_at => {
        data_type     => 'datetime',
        is_nullable   => 0,
        default_value => \'CURRENT_TIMESTAMP',
    },
    resolved_at => {
        data_type   => 'datetime',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('proj_dep_unique', ['project_id', 'depends_on_id']);

__PACKAGE__->belongs_to(
    project => 'Comserv::Model::Schema::Ency::Result::Project',
    'project_id',
);

__PACKAGE__->belongs_to(
    depends_on => 'Comserv::Model::Schema::Ency::Result::Project',
    'depends_on_id',
);

1;
