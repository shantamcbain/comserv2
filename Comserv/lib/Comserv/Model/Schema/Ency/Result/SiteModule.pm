package Comserv::Model::Schema::Ency::Result::SiteModule;
use base 'DBIx::Class::Core';

__PACKAGE__->table('site_modules');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    sitename => {
        data_type => 'varchar',
        size      => 100,
    },
    module_name => {
        data_type => 'varchar',
        size      => 100,
    },
    enabled => {
        data_type     => 'tinyint',
        default_value => 1,
    },
    min_role => {
        data_type     => 'varchar',
        size          => 50,
        default_value => 'member',
    },
    created_at => {
        data_type     => 'datetime',
        default_value => \'CURRENT_TIMESTAMP',
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->add_unique_constraint(
    'site_module_unique' => ['sitename', 'module_name']
);

__PACKAGE__->belongs_to(
    site => 'Comserv::Model::Schema::Ency::Result::Site',
    { 'foreign.name' => 'self.sitename' },
    { join_type => 'left' }
);

1;
