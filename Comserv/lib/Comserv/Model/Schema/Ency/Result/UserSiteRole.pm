package Comserv::Model::Schema::Ency::Result::UserSiteRole;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

__PACKAGE__->table('user_site_roles');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    user_id => {
        data_type => 'integer',
        is_nullable => 0,
    },
    role_id => {
        data_type => 'integer',
        is_nullable => 0,
    },
    sitename => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    assigned_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable => 0,
    },
    assigned_by => {
        data_type => 'integer',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['user_id', 'role_id', 'sitename']);

__PACKAGE__->belongs_to(
    'user' => 'Comserv::Model::Schema::Ency::Result::User',
    'user_id',
    { on_delete => 'cascade' }
);

__PACKAGE__->belongs_to(
    'role' => 'Comserv::Model::Schema::Ency::Result::SiteRole',
    'role_id',
    { on_delete => 'cascade' }
);

__PACKAGE__->belongs_to(
    'assigner' => 'Comserv::Model::Schema::Ency::Result::User',
    'assigned_by',
    { join_type => 'left', on_delete => 'set null' }
);

1;
