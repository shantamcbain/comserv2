package Comserv::Model::Schema::Ency::Result::RolePermission;
use base 'DBIx::Class::Core';
__PACKAGE__->load_components("InflateColumn::DateTime");
use warnings FATAL => 'all';

# Role definitions as DATA (fine-grained access, Oct 2026). One row = "role R may
# do ACTION on MODULE (on SITENAME, or any site when NULL), optionally only on
# records the user owns". Read by Comserv::Util::AccessCheck; edited by admins at
# /admin/role_permissions. user_site_roles still assigns a role to a user per site
# and user_module_access is still the per-user module on/off switch.
#
# While this table is missing or EMPTY, AccessCheck runs in legacy mode (the old
# hard-coded legacy role lists), so creating it changes nothing until
# the first rows are entered.
#
# NOTE ON CREATION: this file is the source of truth; the TABLE is created by an
# admin via /admin/schema_compare -> "Result files without tables" -> Create Table.
# No hand-written DDL, per project policy.

__PACKAGE__->table('role_permissions');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    role => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 0,
        documentation => 'Matches user_site_roles.role, e.g. secretary',
    },
    module => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 0,
        documentation => 'Module name, e.g. todo, calendar, project',
    },
    action => {
        data_type => 'varchar',
        size => 20,
        is_nullable => 0,
        documentation => 'read, create, update or delete',
    },
    own_only => {
        data_type => 'tinyint',
        is_nullable => 0,
        default_value => 0,
        documentation => '1 = only records the user owns',
    },
    sitename => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
        documentation => 'NULL = any site',
    },
    requires_grant => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
        documentation => 'NULL = always applies; else a module the user must be granted/subscribed to on the site (user_module_access granted=1 or membership_service_access), e.g. planning',
    },
    created_by => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    created_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable => 0,
    },
    updated_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

# This DBIx::Class build has NO add_index, so uniqueness is a unique constraint.
# MySQL treats NULL sitename values as distinct, so the admin page also refuses
# duplicates in code.
__PACKAGE__->add_unique_constraint('role_permissions_unique' => [qw(role module action sitename)]);

1;
