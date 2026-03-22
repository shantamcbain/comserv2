package Comserv::Model::Schema::Ency::Result::MenuVisibility;
use base 'DBIx::Class::Core';

=head1 NAME

Comserv::Model::Schema::Ency::Result::MenuVisibility

=head1 DESCRIPTION

Controls visibility of navigation menus based on site, role, and page context.
Allows site admins to configure which menus are visible for different user roles
and on specific pages.

=cut

__PACKAGE__->table('menu_visibility');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    site_name => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 0,
        comment => 'Site name this visibility rule applies to, or "All" for global',
    },
    menu_name => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 0,
        comment => 'Name of the menu (main, global, hosted, member, admin, etc.)',
    },
    role_name => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
        comment => 'User role this rule applies to, NULL for all roles',
    },
    page_pattern => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
        comment => 'Page URL pattern where this rule applies, NULL for all pages',
    },
    is_visible => {
        data_type => 'boolean',
        default_value => 1,
        is_nullable => 0,
        comment => 'Whether the menu should be visible (1) or hidden (0)',
    },
    priority => {
        data_type => 'integer',
        default_value => 100,
        is_nullable => 0,
        comment => 'Rule priority (lower numbers = higher priority)',
    },
    created_by => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 0,
        comment => 'Username of admin who created this rule',
    },
    created_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable => 0,
    },
    updated_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
        is_nullable => 0,
    },
    notes => {
        data_type => 'text',
        is_nullable => 1,
        comment => 'Admin notes about this visibility rule',
    },
);

__PACKAGE__->set_primary_key('id');

# Add unique constraint to prevent duplicate rules
__PACKAGE__->add_unique_constraint(
    'unique_menu_visibility' => [
        'site_name', 'menu_name', 'role_name', 'page_pattern'
    ]
);

# Indexes for performance
__PACKAGE__->add_unique_constraint(
    'idx_site_menu' => ['site_name', 'menu_name']
);

=head1 RELATIONSHIPS

=cut

# No direct relationships needed for this table

=head1 METHODS

=head2 is_menu_visible_for_context

Check if a menu should be visible for given context (site, role, page)

=cut

sub is_menu_visible_for_context {
    my ($self, $site_name, $menu_name, $role_name, $page_url) = @_;
    
    # This would be implemented as a class method in the actual usage
    # Returns boolean indicating if menu should be visible
}

1;