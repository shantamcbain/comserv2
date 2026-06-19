package Comserv::Model::Schema::Ency::Result::MenuStock;
use base 'DBIx::Class::Core';

=head1 NAME

Comserv::Model::Schema::Ency::Result::MenuStock

=head1 DESCRIPTION

CSC / central canonical stock menu items. These form the "base and mandatory list"
(Main, Login/HelpDesk, Admin, etc.) provided to all sites.

SiteName admins are presented with the full list when editing menus. CSC admins
control the definitions, default placement, icons, and mandatory/always-visible/
reorderable/gating flags.

Styles for items come exclusively from the active site theme (CSS vars).

Part of the major DB-dominated menu system migration (2026).

=cut

__PACKAGE__->table('menu_stock');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
        is_nullable => 0,
    },
    stock_key => {
        data_type => 'varchar',
        size => 64,
        is_nullable => 0,
        comment => 'Stable unique identifier e.g. main_home, helpdesk_submit_ticket',
    },
    default_label => {
        data_type => 'varchar',
        size => 120,
        is_nullable => 0,
    },
    default_url => {
        data_type => 'varchar',
        size => 500,
        is_nullable => 0,
    },
    default_icon => {
        data_type => 'varchar',
        size => 64,
        is_nullable => 1,
        default_value => '',
    },
    default_category => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 0,
        comment => 'Main_links, HelpDesk_links, Admin_links, Member_links, etc.',
    },
    default_submenu => {
        data_type => 'varchar',
        size => 64,
        is_nullable => 1,
        default_value => '',
    },
    always_include => {
        data_type => 'tinyint',
        size => 1,
        is_nullable => 0,
        default_value => 0,
        comment => '1 = CSC forces this item into every site effective menu',
    },
    always_visible => {
        data_type => 'tinyint',
        size => 1,
        is_nullable => 0,
        default_value => 0,
        comment => '1 = always shown regardless of some role/page filters',
    },
    reorderable => {
        data_type => 'tinyint',
        size => 1,
        is_nullable => 0,
        default_value => 1,
        comment => '1 = site admins allowed to change position of this stock item',
    },
    gating => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
        default_value => '',
        comment => 'Gating expression e.g. "module:beekeeping" or "csc_only" or "subscription". Interpreted by builder.',
    },
    sort_hint => {
        data_type => 'integer',
        is_nullable => 0,
        default_value => 100,
    },
    description => {
        data_type => 'text',
        is_nullable => 1,
    },
    is_active => {
        data_type => 'tinyint',
        size => 1,
        is_nullable => 0,
        default_value => 1,
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
__PACKAGE__->add_unique_constraint('uq_stock_key' => ['stock_key']);

__PACKAGE__->has_many(
    'site_overrides' => 'Comserv::Model::Schema::Ency::Result::SiteMenuOverride',
    { 'foreign.stock_id' => 'self.id' },
    { cascade_delete => 0 }
);

# Helper used by builder / editor
sub is_mandatory {
    my $self = shift;
    return $self->always_include || $self->always_visible;
}

sub effective_label_for_site {
    my ($self, $override) = @_;
    return ($override && $override->custom_label) ? $override->custom_label : $self->default_label;
}

1;