package Comserv::Model::Schema::Ency::Result::UserModuleAccess;
use base 'DBIx::Class::Core';

__PACKAGE__->table('user_module_access');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    username => {
        data_type => 'varchar',
        size      => 255,
    },
    sitename => {
        data_type => 'varchar',
        size      => 100,
    },
    module_name => {
        data_type => 'varchar',
        size      => 100,
    },
    granted => {
        data_type     => 'tinyint',
        default_value => 1,
    },
    granted_by => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'datetime',
        default_value => \'CURRENT_TIMESTAMP',
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->add_unique_constraint(
    'user_module_unique' => ['username', 'sitename', 'module_name']
);

1;
