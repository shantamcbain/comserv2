package Comserv::Model::Schema::Ency::Result::SiteMenuOverride;
use base 'DBIx::Class::Core';

=head1 NAME

Comserv::Model::Schema::Ency::Result::SiteMenuOverride

=head1 DESCRIPTION

SiteName (or 'All') customizations, adoptions, renames, reorders, and context-specific
variations of CSC menu_stock items.

When editing a menu, the SiteName admin is shown the complete CSC stock catalog.
Choosing to include/rename/reposition a stock item creates or updates a row here.

page_pattern supports the "change appearance of list according to the page" requirement:
- NULL or empty = applies globally for the site.
- Otherwise a simple pattern (prefix/glob) matched against current request path by the
  effective menu builder. Editor is page-aware and asks "global or for this page?".

Mandatory items (per CSC flags on stock) are presented with locks/badges; deletion of
the override is prevented or re-created as "included".

Pure custom (no stock_id) rows supported for future custom top-level menus.

Complements (does not replace) internal_links_tb for user private links and legacy customs.

Part of the 2026 DB-dominated menu system update.

=cut

__PACKAGE__->table('site_menu_overrides');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    site_name => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 0,
        default_value => 'All',
    },
    stock_id => {
        data_type => 'integer',
        is_nullable => 1,
    },
    stock_key => {
        data_type => 'varchar',
        size => 64,
        is_nullable => 1,
    },
    custom_label => {
        data_type => 'varchar',
        size => 120,
        is_nullable => 1,
    },
    custom_url => {
        data_type => 'varchar',
        size => 500,
        is_nullable => 1,
    },
    custom_icon => {
        data_type => 'varchar',
        size => 64,
        is_nullable => 1,
        default_value => '',
    },
    custom_category => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 1,
    },
    custom_submenu => {
        data_type => 'varchar',
        size => 64,
        is_nullable => 1,
        default_value => '',
    },
    sort_order => {
        data_type => 'integer',
        is_nullable => 0,
        default_value => 100,
    },
    is_included => {
        data_type => 'tinyint',
        size => 1,
        is_nullable => 0,
        default_value => 1,
    },
    page_pattern => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    is_page_specific => {
        data_type => 'tinyint',
        size => 1,
        is_nullable => 0,
        default_value => 0,
    },
    notes => {
        data_type => 'text',
        is_nullable => 1,
    },
    created_by => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    created_at => {
        data_type => 'datetime',
        set_on_create => 1,
    },
    updated_at => {
        data_type => 'datetime',
        set_on_create => 1,
        set_on_update => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->add_unique_constraint(
    'uq_site_stock' => [ 'site_name', 'stock_id' ]
);

__PACKAGE__->belongs_to(
    'stock' => 'Comserv::Model::Schema::Ency::Result::MenuStock',
    { 'foreign.id' => 'self.stock_id' },
    { join_type => 'LEFT' }
);

# Convenience: effective values (fall back to stock defaults)
sub effective_label {
    my $self = shift;
    return $self->custom_label || ( $self->stock ? $self->stock->default_label : '' );
}

sub effective_url {
    my $self = shift;
    return $self->custom_url || ( $self->stock ? $self->stock->default_url : '' );
}

sub effective_icon {
    my $self = shift;
    return $self->custom_icon || ( $self->stock ? $self->stock->default_icon : '' );
}

sub effective_category {
    my $self = shift;
    return $self->custom_category || ( $self->stock ? $self->stock->default_category : '' );
}

sub effective_submenu {
    my $self = shift;
    return $self->custom_submenu || ( $self->stock ? $self->stock->default_submenu : '' );
}

1;