package Comserv::Model::Schema::Ency::Result::CustomMenu;
use base 'DBIx::Class::Core';

=head1 NAME

Comserv::Model::Schema::Ency::Result::CustomMenu

=head1 DESCRIPTION

Stores custom menu items that can be added to navigation menus.
Supports role-based access control and page-specific visibility.
Allows site admins to create custom navigation links and organize them
into dropdown menus.

=cut

__PACKAGE__->table('custom_menu');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    site_name => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 0,
        comment => 'Site name this menu item belongs to, or "All" for global',
    },
    parent_menu => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
        comment => 'Parent menu name (main, admin, manager, etc.) or NULL for top-level',
    },
    menu_group => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
        comment => 'Custom menu group name for organizing related items',
    },
    title => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
        comment => 'Display title of the menu item',
    },
    url => {
        data_type => 'varchar',
        size => 500,
        is_nullable => 0,
        comment => 'URL or path for the menu item',
    },
    icon_class => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
        comment => 'CSS class for the menu icon (e.g., icon-link, icon-admin)',
    },
    target => {
        data_type => 'varchar',
        size => 20,
        default_value => '_self',
        is_nullable => 0,
        comment => 'Link target (_self, _blank, _parent, _top)',
    },
    required_role => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
        comment => 'Required user role to see this menu item, NULL for all users',
    },
    page_pattern => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
        comment => 'Page URL pattern where this item should appear, NULL for all pages',
    },
    sort_order => {
        data_type => 'integer',
        default_value => 100,
        is_nullable => 0,
        comment => 'Sort order within the menu (lower numbers appear first)',
    },
    is_active => {
        data_type => 'boolean',
        default_value => 1,
        is_nullable => 0,
        comment => 'Whether this menu item is active (1) or disabled (0)',
    },
    is_dropdown => {
        data_type => 'boolean',
        default_value => 0,
        is_nullable => 0,
        comment => 'Whether this item creates a dropdown menu (1) or is a direct link (0)',
    },
    dropdown_parent_id => {
        data_type => 'integer',
        is_nullable => 1,
        comment => 'ID of parent menu item if this is a dropdown child',
    },
    created_by => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 0,
        comment => 'Username of admin who created this menu item',
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
    description => {
        data_type => 'text',
        is_nullable => 1,
        comment => 'Description or notes about this menu item',
    },
);

__PACKAGE__->set_primary_key('id');

# Indexes for performance
__PACKAGE__->add_unique_constraint(
    'idx_site_parent_order' => ['site_name', 'parent_menu', 'sort_order']
);

__PACKAGE__->add_unique_constraint(
    'idx_active_items' => ['site_name', 'is_active', 'sort_order']
);

=head1 RELATIONSHIPS

=cut

# Self-referential relationship for dropdown hierarchies
__PACKAGE__->belongs_to(
    'dropdown_parent',
    'Comserv::Model::Schema::Ency::Result::CustomMenu',
    { 'foreign.id' => 'self.dropdown_parent_id' },
    { join_type => 'left' }
);

__PACKAGE__->has_many(
    'dropdown_children',
    'Comserv::Model::Schema::Ency::Result::CustomMenu',
    { 'foreign.dropdown_parent_id' => 'self.id' },
    { cascade_delete => 1 }
);

=head1 METHODS

=head2 get_menu_items_for_context

Get menu items for specific context (site, role, page, parent menu)

=cut

sub get_menu_items_for_context {
    my ($self, $site_name, $parent_menu, $role_name, $page_url) = @_;
    
    # This would be implemented as a class method in the actual usage
    # Returns array of menu items matching the context
}

=head2 build_dropdown_structure

Build hierarchical dropdown menu structure

=cut

sub build_dropdown_structure {
    my ($self, $menu_items) = @_;
    
    # This would organize flat menu items into dropdown hierarchy
    # Returns nested structure for template rendering
}

1;