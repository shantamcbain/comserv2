package Comserv::Model::Schema::Ency::Result::UserSiteRole;
use base 'DBIx::Class::Core';

=head1 NAME

Comserv::Model::Schema::Ency::Result::UserSiteRole - Site-specific user roles

=head1 DESCRIPTION

This table manages site-specific user roles, allowing fine-grained access control
where users can have different roles on different sites while maintaining
CSC-level administrative access.

=cut

__PACKAGE__->table('user_site_roles');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    user_id => {
        data_type => 'integer',
        is_foreign_key => 1,
    },
    site_id => {
        data_type => 'integer',
        is_foreign_key => 1,
        is_nullable => 1,  # NULL means global/CSC role
    },
    role => {
        data_type => 'varchar',
        size => 50,
        # Possible values: 'super_admin', 'site_admin', 'site_user', 'site_viewer'
    },
    granted_by => {
        data_type => 'integer',
        is_foreign_key => 1,
        is_nullable => 1,
    },
    granted_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
    },
    expires_at => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
    is_active => {
        data_type => 'boolean',
        default_value => 1,
    },
);

__PACKAGE__->set_primary_key('id');

# Unique constraint: one role per user per site
__PACKAGE__->add_unique_constraint(
    'user_site_role_unique' => ['user_id', 'site_id', 'role']
);

# Relationships
__PACKAGE__->belongs_to(
    user => 'Comserv::Model::Schema::Ency::Result::User',
    'user_id'
);

__PACKAGE__->belongs_to(
    site => 'Comserv::Model::Schema::Ency::Result::Project',
    'site_id',
    { join_type => 'left' }  # Left join since site_id can be NULL for global roles
);

__PACKAGE__->belongs_to(
    granted_by_user => 'Comserv::Model::Schema::Ency::Result::User',
    'granted_by',
    { join_type => 'left' }
);

1;