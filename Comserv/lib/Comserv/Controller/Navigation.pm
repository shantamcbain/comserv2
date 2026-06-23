package Comserv::Controller::Navigation;
use Moose;
use namespace::autoclean;
use Data::Dumper;

BEGIN { extends 'Catalyst::Controller'; }

use URI::Escape qw(uri_escape);
use JSON::MaybeXS qw(decode_json encode_json);
use List::Util qw(min);

# Class-level cache for navigation data
has '_navigation_cache' => (
    is => 'rw',
    isa => 'HashRef',
    default => sub { {} }
);

has '_tables_checked' => (
    is => 'rw',
    isa => 'Bool',
    default => 0
);

has '_cache_timestamp' => (
    is => 'rw',
    isa => 'Int',
    default => 0
);

=head1 NAME

Comserv::Controller::Navigation - Catalyst Controller for navigation components

=head1 DESCRIPTION

This controller handles database queries for navigation components,
replacing the direct DBI usage in templates with proper model usage.

=cut

# Helper: current sitename convenience
sub _current_site {
    my ($self, $c) = @_;
    return $c->stash->{SiteName} || $c->session->{SiteName} || 'All';
}

# Canonical nav menus — aligned with pagetop.tt / TopDropList*.tt (active menus only)
our @NAV_MENU_CATALOG = (
    { menu => 'Main',       category => 'Main_links',       label => 'Main' },
    { menu => 'Shop',       category => 'Shop_links',       label => 'Shop', requires_shop => 1 },
    { menu => 'Member',     category => 'Member_links',     label => 'Member' },
    { menu => 'HelpDesk',   category => 'HelpDesk_links',   label => 'HelpDesk' },
    { menu => 'Hosted',     category => 'Hosted_links',     label => 'Hosted', csc_only => 1 },
    { menu => 'Planning',   category => 'Planning_links',   label => 'Planning' },
    { menu => 'Workshop',   category => 'Workshop_links',   label => 'Workshops' },
    { menu => 'Weather',    category => 'Weather_links',    label => 'Weather' },
    { menu => 'ENCY',       category => 'ENCY_links',       label => 'Encyclopedia' },
    { menu => 'Beekeeping', category => 'Beekeeping_links', label => 'Beekeeping', requires_module => 'beekeeping' },
    { menu => 'Brew',       category => 'Brew_links',       label => 'Brew', requires_module => 'brew' },
    { menu => '3d',         category => '3d_links',         label => '3D Printing', requires_module => 'printing_3d' },
    { menu => 'Admin',      category => 'Admin_links',      label => 'Admin', admin_only => 1 },
    # Legacy categories (discontinued top-level menus; kept for existing DB rows)
    { menu => 'IT',         category => 'IT_links',         label => 'HelpDesk IT (legacy)', legacy => 1 },
    { menu => 'Global',     category => 'Global_links',     label => 'Global (legacy)', legacy => 1 },
    { menu => 'COOP',       category => 'COOP_links',       label => 'COOP (legacy)', legacy => 1 },
);

our @MENU_LINK_CATEGORIES = map { $_->{category} } @NAV_MENU_CATALOG;

our %MENU_TO_CATEGORY = map { $_->{menu} => $_->{category} } @NAV_MENU_CATALOG;
$MENU_TO_CATEGORY{Beekeeping} = 'Beekeeping_links';
$MENU_TO_CATEGORY{weather}    = 'Weather_links';

our %CATEGORY_LABELS = map { $_->{category} => $_->{label} . ' Menu' } @NAV_MENU_CATALOG;
$CATEGORY_LABELS{Private_links} = 'Login menu (My Links)';
$CATEGORY_LABELS{Hosted_link}   = 'Hosted Menu';    # legacy rows

# Submenu sections within each top-level menu (matches TopDropList*.tt structure)
our %NAV_SUBMENU_CATALOG = (
    Hosted_links => [
        { id => 'hosted_links', label => 'Guides & bookmarks' },
        { id => 'hosted_pages', label => 'Guides & bookmarks (legacy tag — same list)' },
        { id => 'top',          label => 'Top of Hosted dropdown' },
    ],
    HelpDesk_links => [
        { id => 'resources',        label => 'Additional Resources' },
        { id => 'it_services',      label => 'IT Services' },
        { id => 'member_resources', label => 'Member Resources' },
        { id => 'top',              label => 'Top of menu (main list)' },
    ],
    Main_links => [
        { id => 'join_services', label => 'Join & Services' },
        { id => 'public_links',  label => 'Public Links' },
        { id => 'top',           label => 'Top of menu (main list)' },
    ],
    Member_links => [
        { id => 'member_services', label => 'Member Services' },
        { id => 'member_pages',   label => 'Member Pages' },
        { id => 'top',             label => 'Top of menu (main list)' },
    ],
    Admin_links => [
        { id => 'admin_links',      label => 'Admin → Admin (Site Modules, Git Pull, Preview, …)' },
        { id => 'cms_pages',        label => 'Top of Admin dropdown (with CMS site pages)' },
        { id => 'top',              label => 'Top of Admin dropdown (direct links only)' },
        { id => 'ai_assistant',     label => 'AI Assistant' },
        { id => 'documentation',    label => 'Documentation' },
        { id => 'file_management',  label => 'File Management' },
        { id => 'marketplace',      label => 'Marketplace' },
        { id => 'inventory',        label => 'Inventory & Accounting' },
        { id => 'logging',          label => 'Logging' },
        { id => 'projects',         label => 'Projects' },
        { id => 'system_links',     label => 'System Links' },
        { id => 'system_setup',     label => 'System Setup' },
        { id => 'todo',             label => 'ToDo' },
        { id => 'user_management',  label => 'User Management' },
        { id => 'theme_css',        label => 'Theme & CSS' },
        { id => 'debug_options',    label => 'Debug Options' },
        { id => 'mcoop_admin',      label => 'MCOOP Admin' },
    ],
    Private_links => [
        { id => 'login_dropdown', label => 'My Links (login dropdown)' },
    ],
);

our %NAV_SUBMENU_DEFAULTS = (
    Hosted_links   => 'hosted_links',
    HelpDesk_links => 'resources',
    Main_links     => 'join_services',
    Member_links   => 'member_services',
    Admin_links    => 'admin_links',
    Private_links  => 'login_dropdown',
);

our %NAV_SUBMENU_LABELS = (
    hosted_links     => 'Guides & bookmarks',
    hosted_pages     => 'Guides & bookmarks (legacy)',
    resources        => 'Additional Resources',
    it_services      => 'IT Services',
    member_resources => 'Member Resources',
    join_services    => 'Join & Services',
    public_links     => 'Public Links',
    member_services  => 'Member Services',
    login_dropdown   => 'My Links (login dropdown)',
    member_pages     => 'Member Pages',
    cms_pages        => 'CMS Site Pages (top of Admin menu)',
    admin_links      => 'Admin Links submenu',
    top              => 'Top of menu',
    main             => 'Default section',
);

sub nav_menu_catalog        { \@NAV_MENU_CATALOG }
sub nav_submenu_catalog     { \%NAV_SUBMENU_CATALOG }
sub nav_submenu_defaults    { \%NAV_SUBMENU_DEFAULTS }
sub nav_menu_to_category    { \%MENU_TO_CATEGORY }

sub _menu_param_to_category {
    my ($self, $menu) = @_;
    return '' unless defined $menu && $menu ne '';
    return $MENU_TO_CATEGORY{$menu} // '';
}

sub _nav_menu_visible {
    my ($self, $c, $entry) = @_;
    return 1 if $entry->{legacy};

    my $sitename = $c->session->{SiteName} || '';
    if ($entry->{csc_only} && lc($sitename) ne 'csc') {
        return 0;
    }
    if ($entry->{requires_module}) {
        my $mods = $c->stash->{enabled_modules} || {};
        my $mod  = $entry->{requires_module};
        if ($mod eq 'beekeeping') {
            return 0 unless ( $mods->{beekeeping} || $mods->{apiary} || $mods->{bmaster} );
        }
        else {
            return 0 unless $mods->{$mod};
        }
    }
    if ($entry->{requires_shop}) {
        my $mods = $c->stash->{enabled_modules} || {};
        return 0 unless ($c->stash->{site_has_shop} || $mods->{ecommerce});
    }
    return 1;
}

sub _nav_categories_for_user {
    my ($self, $c, $is_admin, $extra_category) = @_;
    my @cats;
    for my $entry (@NAV_MENU_CATALOG) {
        next if $entry->{admin_only} && !$is_admin;
        next if $entry->{legacy};
        next unless $self->_nav_menu_visible($c, $entry);
        push @cats, $entry->{category};
    }
    if ($extra_category) {
        unless (grep { $_ eq $extra_category } @cats) {
            push @cats, $extra_category;
        }
    }
    unless (grep { $_ eq 'Private_links' } @cats) {
        push @cats, 'Private_links';
    }
    return \@cats;
}

sub _default_external_target {
    my ($self, $url, $target) = @_;
    return $target if defined $target && $target ne '';
    return ($url && $url =~ m{^https?://}i) ? '_blank' : '_self';
}

my $_internal_links_submenu_col;
my $_internal_links_public_visible_col;
my $_hosting_list_publicly_col;
my $_hosting_list_publicly_cache = {};

sub _internal_links_has_submenu_column {
    my ($self, $c) = @_;
    return $_internal_links_submenu_col if defined $_internal_links_submenu_col;
    $_internal_links_submenu_col = $self->column_exists( $c, 'internal_links_tb', 'submenu' ) ? 1 : 0;
    return $_internal_links_submenu_col;
}

sub _ensure_internal_links_submenu_column {
    my ($self, $c) = @_;
    return if $self->_internal_links_has_submenu_column($c);
    eval {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        $dbh->do(
            "ALTER TABLE internal_links_tb ADD COLUMN submenu varchar(50) DEFAULT '' AFTER description"
        );
        $_internal_links_submenu_col = 1;
        $c->log->info('Added submenu column to internal_links_tb');
    };
    if ($@) {
        $c->log->error("Could not add submenu column to internal_links_tb: $@");
        $_internal_links_submenu_col = 0;
    }
}

sub _internal_links_has_public_visible_column {
    my ( $self, $c ) = @_;
    return $_internal_links_public_visible_col if defined $_internal_links_public_visible_col;
    $_internal_links_public_visible_col
        = $self->column_exists( $c, 'internal_links_tb', 'public_visible' ) ? 1 : 0;
    return $_internal_links_public_visible_col;
}

sub _ensure_internal_links_public_visible_column {
    my ( $self, $c ) = @_;
    return if $self->_internal_links_has_public_visible_column($c);
    eval {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        $dbh->do(
            "ALTER TABLE internal_links_tb ADD COLUMN public_visible tinyint(1) NOT NULL DEFAULT 1 AFTER status"
        );
        $_internal_links_public_visible_col = 1;
        $c->log->info('Added public_visible column to internal_links_tb');
    };
    if ($@) {
        $c->log->error("Could not add public_visible column to internal_links_tb: $@");
        $_internal_links_public_visible_col = 0;
    }
}

sub _hosting_has_list_publicly_column {
    my ( $self, $c ) = @_;
    return $_hosting_list_publicly_col if defined $_hosting_list_publicly_col;
    $_hosting_list_publicly_col
        = $self->column_exists( $c, 'hosting_accounts', 'list_publicly' ) ? 1 : 0;
    return $_hosting_list_publicly_col;
}

sub _ensure_hosting_list_publicly_column {
    my ( $self, $c ) = @_;
    return if $self->_hosting_has_list_publicly_column($c);
    eval {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        $dbh->do(
            "ALTER TABLE hosting_accounts ADD COLUMN list_publicly tinyint(1) NOT NULL DEFAULT 1 AFTER status"
        );
        $_hosting_list_publicly_col = 1;
        $_hosting_list_publicly_cache = {};
        $c->log->info('Added list_publicly column to hosting_accounts');
    };
    if ($@) {
        $c->log->error("Could not add list_publicly column to hosting_accounts: $@");
        $_hosting_list_publicly_col = 0;
    }
}

# Logged-in users and admins see links/sites hidden from anonymous guests.
sub _viewer_sees_member_content {
    my ( $self, $c ) = @_;
    return 1 if $c->stash->{is_admin};
    my $root = $c->controller('Root');
    return ( $root && $root->user_exists($c) && ( $c->session->{username} // '' ) ne '' ) ? 1 : 0;
}

sub _hosting_list_publicly_for_sitename {
    my ( $self, $c, $sitename ) = @_;
    return 1 unless defined $sitename && $sitename ne '';
    $self->_ensure_hosting_list_publicly_column($c);
    return 1 unless $self->_hosting_has_list_publicly_column($c);

    my $key = lc $sitename;
    return $_hosting_list_publicly_cache->{$key} if exists $_hosting_list_publicly_cache->{$key};

    my $visible = 1;
    eval {
        my $acct = $c->model('DBEncy')->resultset('Accounting::HostingAccount')->search(
            { sitename => $sitename },
            { rows => 1 },
        )->single;
        if ($acct) {
            $visible = $acct->list_publicly ? 1 : 0;
        }
    };
    $_hosting_list_publicly_cache->{$key} = $visible;
    return $visible;
}

sub _hosted_catalog_visible_to_viewer {
    my ( $self, $c, $sitename ) = @_;
    return 1 if $self->_viewer_sees_member_content($c);
    return $self->_hosting_list_publicly_for_sitename( $c, $sitename );
}

sub _link_visible_to_viewer {
    my ( $self, $c, $link ) = @_;
    return 1 if $self->_viewer_sees_member_content($c);
    $self->_ensure_internal_links_public_visible_column($c);
    return 1 unless $self->_internal_links_has_public_visible_column($c);
    my $pv = ref($link) eq 'HASH' ? ( $link->{public_visible} // 1 ) : ( $link->public_visible // 1 );
    return $pv ? 1 : 0;
}

# Public menu rows: blank description, or admin_only when viewer is an administrator.
sub _public_link_description_or {
    my ( $self, $c ) = @_;
    my @or = (
        { description => undef },
        { description => '' },
    );
    if ( $c->stash->{is_admin} ) {
        push @or, { description => 'admin_only' };
    }
    return \@or;
}

# Fetch private links with raw SQL when DBIC/schema drift would otherwise fail.
sub _fetch_private_links_sql {
    my ( $self, $c, $username, $site_name ) = @_;
    return [] unless $username;

    my @results;
    eval {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        my ( $sql, @bind );
        if ( defined $site_name && $site_name ne '' ) {
            $sql = q{
                SELECT id, category, sitename, name, url, target, description, link_order, status
                FROM internal_links_tb
                WHERE description = ? AND status = 1
                  AND (sitename = ? OR sitename = 'All')
                ORDER BY category ASC, sitename ASC, link_order ASC, name ASC
            };
            @bind = ( $username, $site_name );
        }
        else {
            $sql = q{
                SELECT id, category, sitename, name, url, target, description, link_order, status
                FROM internal_links_tb
                WHERE description = ? AND status = 1
                ORDER BY category ASC, sitename ASC, link_order ASC, name ASC
            };
            @bind = ($username);
        }
        my $sth = $dbh->prepare($sql);
        $sth->execute(@bind);
        while ( my $row = $sth->fetchrow_hashref ) {
            push @results, $row;
        }
    };
    if ($@) {
        $c->log->error("SQL fallback for private links failed: $@");
    }
    return \@results;
}

my $_nav_submenu_table_ok;

sub _ensure_nav_submenu_table {
    my ( $self, $c ) = @_;
    return 0 unless $c;
    return 1 if $_nav_submenu_table_ok;

    eval {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        my $sth = $dbh->prepare("SHOW TABLES LIKE 'nav_submenu_tb'");
        $sth->execute();
        unless ( $sth->fetchrow_arrayref ) {
            $dbh->do(q{
                CREATE TABLE nav_submenu_tb (
                    id INT NOT NULL AUTO_INCREMENT,
                    category VARCHAR(50) NOT NULL,
                    sitename VARCHAR(50) NOT NULL DEFAULT 'All',
                    submenu_id VARCHAR(64) NOT NULL,
                    label VARCHAR(120) NOT NULL,
                    icon VARCHAR(64) DEFAULT '',
                    header_url VARCHAR(255) DEFAULT '',
                    section_order INT NOT NULL DEFAULT 0,
                    is_system TINYINT(1) NOT NULL DEFAULT 0,
                    template_slot VARCHAR(64) DEFAULT '',
                    status TINYINT(1) NOT NULL DEFAULT 1,
                    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                    PRIMARY KEY (id),
                    UNIQUE KEY uq_nav_submenu_scope (category, sitename, submenu_id),
                    KEY idx_nav_submenu_category (category),
                    KEY idx_nav_submenu_sitename (sitename),
                    KEY idx_nav_submenu_status (status)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
            });
            $c->log->info('Created nav_submenu_tb');
        }
        $_nav_submenu_table_ok = 1;
        $self->_seed_nav_submenu_catalog( $c, $dbh );
    };
    if ($@) {
        $c->log->error("nav_submenu_tb ensure failed: $@");
        $_nav_submenu_table_ok = 0;
    }
    return $_nav_submenu_table_ok ? 1 : 0;
}

sub seed_nav_submenu_catalog_dbh {
    my ( $self, $dbh ) = @_;
    return unless $dbh;

    my $order = 0;
    for my $category ( sort keys %NAV_SUBMENU_CATALOG ) {
        for my $item ( @{ $NAV_SUBMENU_CATALOG{$category} } ) {
            my $id = $item->{id} // next;
            my $label = $item->{label} // $id;
            eval {
                my $check = $dbh->prepare(
                    'SELECT id FROM nav_submenu_tb '
                    . 'WHERE category = ? AND sitename = ? AND submenu_id = ? LIMIT 1'
                );
                $check->execute( $category, 'All', $id );
                next if $check->fetchrow_arrayref;

                $dbh->do(
                    'INSERT INTO nav_submenu_tb '
                    . '(category, sitename, submenu_id, label, section_order, is_system, template_slot, status) '
                    . 'VALUES (?, ?, ?, ?, ?, 1, ?, 1)',
                    undef,
                    $category, 'All', $id, $label, $order, $id,
                );
            };
            $order += 10;
        }
        $order = 0;
    }
}

sub _seed_nav_submenu_catalog {
    my ( $self, $c, $dbh ) = @_;
    $dbh //= eval { $c->model('DBEncy')->schema->storage->dbh };
    $self->seed_nav_submenu_catalog_dbh($dbh);
}

# ============================================================
# NEW: menu_stock (CSC stock catalog) + site_menu_overrides
# For the DB-dominated menu system with CSC base + SiteName overrides.
# Hybrid: critical fallbacks remain in .tt; stock powers editor + customizable lists.
# ============================================================

my $_menu_stock_table_ok;
my $_site_menu_overrides_table_ok;

sub _ensure_menu_stock_tables {
    my ( $self, $c ) = @_;
    return 0 unless $c;
    return 1 if $_menu_stock_table_ok && $_site_menu_overrides_table_ok;

    eval {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;

        # menu_stock
        my $sth = $dbh->prepare("SHOW TABLES LIKE 'menu_stock'");
        $sth->execute();
        unless ( $sth->fetchrow_arrayref ) {
            my $sql_file = $c->path_to('sql', '20260617_create_menu_stock.sql')->stringify;
            if (-e $sql_file) {
                my $sql = do { local (@ARGV, $/) = $sql_file; <> };
                foreach my $statement (split /;/, $sql) {
                    $statement =~ s/^\s+|\s+$//g;
                    next unless $statement && $statement !~ /^--/;
                    eval { $dbh->do($statement); };
                    $c->log->error("menu_stock migration stmt error: $@") if $@;
                }
            } else {
                # Fallback inline CREATE (matches the .sql)
                $dbh->do(q{
                    CREATE TABLE IF NOT EXISTS menu_stock (
                        id INT NOT NULL AUTO_INCREMENT,
                        stock_key VARCHAR(64) NOT NULL,
                        default_label VARCHAR(120) NOT NULL,
                        default_url VARCHAR(500) NOT NULL,
                        default_icon VARCHAR(64) DEFAULT '',
                        default_category VARCHAR(50) NOT NULL,
                        default_submenu VARCHAR(64) DEFAULT '',
                        always_include TINYINT(1) NOT NULL DEFAULT 0,
                        always_visible TINYINT(1) NOT NULL DEFAULT 0,
                        reorderable TINYINT(1) NOT NULL DEFAULT 1,
                        gating VARCHAR(255) DEFAULT '',
                        sort_hint INT NOT NULL DEFAULT 100,
                        description TEXT,
                        is_active TINYINT(1) NOT NULL DEFAULT 1,
                        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                        updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                        PRIMARY KEY (id),
                        UNIQUE KEY uq_menu_stock_key (stock_key),
                        KEY idx_menu_stock_category (default_category)
                    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
                });
            }
            $c->log->info('Created menu_stock table');
        }
        $_menu_stock_table_ok = 1;

        # site_menu_overrides
        $sth = $dbh->prepare("SHOW TABLES LIKE 'site_menu_overrides'");
        $sth->execute();
        unless ( $sth->fetchrow_arrayref ) {
            my $sql_file2 = $c->path_to('sql', '20260617_create_site_menu_overrides.sql')->stringify;
            if (-e $sql_file2) {
                my $sql2 = do { local (@ARGV, $/) = $sql_file2; <> };
                foreach my $statement (split /;/, $sql2) {
                    $statement =~ s/^\s+|\s+$//g;
                    next unless $statement && $statement !~ /^--/;
                    eval { $dbh->do($statement); };
                    $c->log->error("site_menu_overrides migration stmt error: $@") if $@;
                }
            } else {
                $dbh->do(q{
                    CREATE TABLE IF NOT EXISTS site_menu_overrides (
                        id INT NOT NULL AUTO_INCREMENT,
                        site_name VARCHAR(50) NOT NULL DEFAULT 'All',
                        stock_id INT NULL,
                        stock_key VARCHAR(64) NULL,
                        custom_label VARCHAR(120) NULL,
                        custom_url VARCHAR(500) NULL,
                        custom_icon VARCHAR(64) DEFAULT '',
                        custom_category VARCHAR(50) NULL,
                        custom_submenu VARCHAR(64) DEFAULT '',
                        sort_order INT NOT NULL DEFAULT 100,
                        is_included TINYINT(1) NOT NULL DEFAULT 1,
                        page_pattern VARCHAR(255) DEFAULT NULL,
                        is_page_specific TINYINT(1) NOT NULL DEFAULT 0,
                        notes TEXT,
                        created_by VARCHAR(100),
                        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                        updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                        PRIMARY KEY (id),
                        UNIQUE KEY uq_site_stock (site_name, stock_id),
                        KEY idx_site_menu_overrides_site (site_name)
                    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
                });
            }
            $c->log->info('Created site_menu_overrides table');
        }
        $_site_menu_overrides_table_ok = 1;

        # Seed stock (idempotent)
        $self->_seed_csc_menu_stock( $c, $dbh );
    };
    if ($@) {
        $c->log->error("menu_stock / site_menu_overrides ensure failed: $@");
        $_menu_stock_table_ok = 0;
        $_site_menu_overrides_table_ok = 0;
    }
    return ($_menu_stock_table_ok && $_site_menu_overrides_table_ok) ? 1 : 0;
}

sub seed_csc_menu_stock_dbh {
    my ( $self, $dbh ) = @_;
    return unless $dbh;

    # Core CSC stock items. These are presented to *every* SiteName admin when editing menus.
    # Key mandatories (per user spec): Main always, Admin (for admins) always visible/included,
    # login/user basics protected but many renamable. Gating re-uses/extends existing patterns.
    # Hard-coded fallbacks in .tt for resilience on a few (login, HelpDesk entry, main home).
    # New and most others are fully DB editable after "convert" or direct use.

    my @stock = (
        # === Main (core, mostly DB now; home has .tt fallback) ===
        { stock_key => 'main_home', default_label => 'Home', default_url => '/', default_icon => 'icon-home', default_category => 'Main_links', default_submenu => 'top', always_include => 1, always_visible => 1, reorderable => 1, gating => '', sort_hint => 10, description => 'Core site home (DB by default; .tt fallback available)' },
        { stock_key => 'main_marketplace', default_label => 'Marketplace', default_url => '/marketplace', default_icon => 'icon-marketplace', default_category => 'Main_links', default_submenu => 'join_services', always_include => 0, always_visible => 0, reorderable => 1, gating => '', sort_hint => 30, description => '' },
        { stock_key => 'main_mail', default_label => 'Mail', default_url => '/mail', default_icon => 'icon-mail', default_category => 'Main_links', default_submenu => 'join_services', always_include => 0, always_visible => 0, reorderable => 1, gating => '', sort_hint => 40, description => '' },
        { stock_key => 'main_jobs', default_label => 'Jobs', default_url => '/jobs', default_icon => 'icon-briefcase', default_category => 'Main_links', default_submenu => 'join_services', always_include => 0, always_visible => 0, reorderable => 1, gating => '', sort_hint => 50, description => '' },
        { stock_key => 'main_join', default_label => 'Join', default_url => '/join', default_icon => 'icon-user-plus', default_category => 'Main_links', default_submenu => 'join_services', always_include => 0, always_visible => 0, reorderable => 1, gating => '', sort_hint => 60, description => '' },

        # === HelpDesk / Login support (some core hard-coded in TopDropListHelpDesk.tt and Login for resilience) ===
        { stock_key => 'helpdesk_home', default_label => 'HelpDesk Home', default_url => '/HelpDesk', default_icon => 'icon-helpdesk', default_category => 'HelpDesk_links', default_submenu => 'top', always_include => 1, always_visible => 1, reorderable => 1, gating => '', sort_hint => 10, description => 'Primary support entry (hard fallback in .tt)' },
        { stock_key => 'helpdesk_submit', default_label => 'Submit a Ticket', default_url => '/HelpDesk/ticket/new', default_icon => 'icon-ticket', default_category => 'HelpDesk_links', default_submenu => 'top', always_include => 1, always_visible => 1, reorderable => 1, gating => '', sort_hint => 20, description => 'Key support action (hard fallback)' },
        { stock_key => 'helpdesk_status', default_label => 'Check Ticket Status', default_url => '/HelpDesk/ticket/status', default_icon => 'icon-status', default_category => 'HelpDesk_links', default_submenu => 'top', always_include => 0, always_visible => 0, reorderable => 1, gating => '', sort_hint => 30, description => '' },
        { stock_key => 'helpdesk_kb', default_label => 'Knowledge Base', default_url => '/HelpDesk/kb', default_icon => 'icon-kb', default_category => 'HelpDesk_links', default_submenu => 'resources', always_include => 0, always_visible => 0, reorderable => 1, gating => '', sort_hint => 50, description => '' },
        { stock_key => 'helpdesk_faq', default_label => 'FAQ', default_url => '/faq', default_icon => 'icon-faq', default_category => 'HelpDesk_links', default_submenu => 'resources', always_include => 0, always_visible => 0, reorderable => 1, gating => '', sort_hint => 60, description => '' },
        { stock_key => 'helpdesk_docs', default_label => 'Documentation', default_url => '/Documentation', default_icon => 'icon-docs', default_category => 'HelpDesk_links', default_submenu => 'resources', always_include => 0, always_visible => 0, reorderable => 1, gating => '', sort_hint => 70, description => '' },

        # === Admin (always visible to admins on all pages per spec; admin dropdown protected) ===
        { stock_key => 'admin_home', default_label => 'Admin Home', default_url => '/admin', default_icon => 'icon-admin', default_category => 'Admin_links', default_submenu => 'top', always_include => 1, always_visible => 1, reorderable => 1, gating => 'admin_only', sort_hint => 5, description => 'Admin entry; always visible to admins' },
        { stock_key => 'admin_site_modules', default_label => 'Site Modules', default_url => '/admin/site_modules', default_icon => 'icon-settings', default_category => 'Admin_links', default_submenu => 'admin_links', always_include => 0, always_visible => 0, reorderable => 1, gating => 'admin_only', sort_hint => 20, description => '' },
        { stock_key => 'admin_git_pull', default_label => 'Git Pull', default_url => '/admin/git_pull', default_icon => 'icon-git', default_category => 'Admin_links', default_submenu => 'admin_links', always_include => 0, always_visible => 0, reorderable => 1, gating => 'admin_only', sort_hint => 30, description => '' },
        { stock_key => 'admin_preview', default_label => 'Preview Upcoming Changes', default_url => '/admin/dev-preview', default_icon => 'icon-flask', default_category => 'Admin_links', default_submenu => 'admin_links', always_include => 0, always_visible => 0, reorderable => 1, gating => 'admin_only', sort_hint => 40, description => '' },
        { stock_key => 'admin_theme', default_label => 'Theme & CSS', default_url => '/admin/theme', default_icon => 'icon-paint', default_category => 'Admin_links', default_submenu => 'theme_css', always_include => 0, always_visible => 0, reorderable => 1, gating => 'admin_only', sort_hint => 120, description => '' },

        # === Member / other common (DB dominated; renamable) ===
        { stock_key => 'member_home', default_label => 'Member Home', default_url => '/membership', default_icon => 'icon-accounts', default_category => 'Member_links', default_submenu => 'member_services', always_include => 0, always_visible => 0, reorderable => 1, gating => '', sort_hint => 10, description => '' },

        # === Examples of gated (per user spec: subscription / module) ===
        { stock_key => 'weather', default_label => 'Weather', default_url => '/Weather', default_icon => 'icon-weather', default_category => 'Weather_links', default_submenu => 'top', always_include => 0, always_visible => 0, reorderable => 1, gating => 'subscription', sort_hint => 10, description => 'Visible/movable if subscribed' },
        { stock_key => 'beekeeping', default_label => 'Beekeeping', default_url => '/Beekeeping', default_icon => 'icon-beekeeping', default_category => 'Beekeeping_links', default_submenu => 'top', always_include => 0, always_visible => 0, reorderable => 1, gating => 'module:beekeeping', sort_hint => 10, description => 'Only if beekeeping module enabled' },

        # === Hosted / CSC specific examples ===
        { stock_key => 'hosted_catalog', default_label => 'Hosted Sites', default_url => '/hosted', default_icon => 'icon-server', default_category => 'Hosted_links', default_submenu => 'top', always_include => 0, always_visible => 0, reorderable => 1, gating => 'csc_only_or_hosted', sort_hint => 10, description => 'CSC or active hosted account' },

        # Placeholder for future custom top-levels (sites may create additional)
        { stock_key => 'custom_placeholder', default_label => 'Custom Menu (example)', default_url => '#', default_icon => 'icon-folder', default_category => 'Custom_top', default_submenu => 'top', always_include => 0, always_visible => 0, reorderable => 1, gating => '', sort_hint => 999, description => 'Example; sites can create real custom tops' },
    );

    for my $item (@stock) {
        eval {
            my $check = $dbh->prepare('SELECT id FROM menu_stock WHERE stock_key = ? LIMIT 1');
            $check->execute( $item->{stock_key} );
            if ( $check->fetchrow_arrayref ) {
                # Update defaults if changed (label/url/icon mainly; keep admin flags from CSC)
                $dbh->do(
                    'UPDATE menu_stock SET default_label=?, default_url=?, default_icon=?, default_category=?, default_submenu=?, gating=?, sort_hint=?, description=?, updated_at=NOW() WHERE stock_key=?',
                    undef,
                    $item->{default_label}, $item->{default_url}, $item->{default_icon},
                    $item->{default_category}, $item->{default_submenu},
                    $item->{gating}, $item->{sort_hint}, $item->{description},
                    $item->{stock_key}
                );
                return;
            }
            $dbh->do(
                q{INSERT INTO menu_stock
                    (stock_key, default_label, default_url, default_icon, default_category, default_submenu,
                     always_include, always_visible, reorderable, gating, sort_hint, description, is_active)
                  VALUES (?,?,?,?,?,?,?,?,?,?,?,?,1)},
                undef,
                $item->{stock_key}, $item->{default_label}, $item->{default_url}, $item->{default_icon},
                $item->{default_category}, $item->{default_submenu},
                $item->{always_include}, $item->{always_visible}, $item->{reorderable},
                $item->{gating}, $item->{sort_hint}, $item->{description}
            );
        };
        if ($@) {
            # non-fatal during seed
        }
    }
}

sub _seed_csc_menu_stock {
    my ( $self, $c, $dbh ) = @_;
    $dbh //= eval { $c->model('DBEncy')->schema->storage->dbh };
    $self->seed_csc_menu_stock_dbh($dbh);
}

sub get_csc_stock_catalog {
    my ( $self, $c, $category ) = @_;
    $self->_ensure_menu_stock_tables($c);
    my @rows;
    eval {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        my $sql = 'SELECT * FROM menu_stock WHERE is_active = 1';
        my @bind;
        if ($category) {
            $sql .= ' AND default_category = ?';
            push @bind, $category;
        }
        $sql .= ' ORDER BY sort_hint ASC, default_label ASC';
        my $sth = $dbh->prepare($sql);
        $sth->execute(@bind);
        while (my $r = $sth->fetchrow_hashref) { push @rows, $r; }
    };
    if ($@) { $c->log->error("get_csc_stock_catalog: $@"); }
    return \@rows;
}

sub get_site_menu_overrides {
    my ( $self, $c, $site_name ) = @_;
    $site_name //= $self->_current_site($c);
    $self->_ensure_menu_stock_tables($c);
    my @rows;
    eval {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        my $sth = $dbh->prepare(q{
            SELECT * FROM site_menu_overrides
            WHERE site_name = ? OR site_name = 'All'
            ORDER BY sort_order ASC, custom_label ASC
        });
        $sth->execute($site_name);
        while (my $r = $sth->fetchrow_hashref) { push @rows, $r; }
    };
    if ($@) { $c->log->error("get_site_menu_overrides: $@"); }
    return \@rows;
}

# Very basic effective list for Phase 1 verification (stock + site overrides).
# Full context (page, drag order, mandatory force, gating) expanded in later phases.
sub get_effective_stock_items_for_category {
    my ( $self, $c, $category, $site_name ) = @_;
    $site_name //= $self->_current_site($c);
    my $stock = $self->get_csc_stock_catalog($c, $category);
    my $overrides = $self->get_site_menu_overrides($c, $site_name);

    my %ov_by_stock;
    for my $o (@$overrides) {
        my $key = $o->{stock_key} || ($o->{stock_id} ? 'id:'.$o->{stock_id} : '');
        $ov_by_stock{$key} = $o if $key;
    }

    my @eff;
    for my $s (@$stock) {
        my $ov = $ov_by_stock{ $s->{stock_key} } || $ov_by_stock{ 'id:'.($s->{id}//0) };
        next if $ov && !$ov->{is_included} && !$s->{always_include};

        push @eff, {
            %$s,
            _override_id => $ov ? $ov->{id} : undef,
            name  => ( $ov && $ov->{custom_label} ) ? $ov->{custom_label} : $s->{default_label},
            url   => ( $ov && $ov->{custom_url} )   ? $ov->{custom_url}   : $s->{default_url},
            icon  => ( $ov && $ov->{custom_icon} )  ? $ov->{custom_icon}  : $s->{default_icon},
            category => ( $ov && $ov->{custom_category} ) ? $ov->{custom_category} : $s->{default_category},
            submenu  => ( $ov && $ov->{custom_submenu} )  ? $ov->{custom_submenu}  : $s->{default_submenu},
            sort_order => ( $ov && defined $ov->{sort_order} ) ? $ov->{sort_order} : $s->{sort_hint},
            is_from_stock => 1,
            is_mandatory  => $s->{always_include} || $s->{always_visible},
            reorderable   => $s->{reorderable},
        };
    }
    @eff = sort { ($a->{sort_order}||0) <=> ($b->{sort_order}||0) || lc($a->{name}||'') cmp lc($b->{name}||'') } @eff;
    return \@eff;
}

sub _slugify_submenu_id {
    my ( $self, $label ) = @_;
    return '' unless defined $label && $label ne '';
    my $slug = lc $label;
    $slug =~ s/[^a-z0-9]+/_/g;
    $slug =~ s/^_+|_+$//g;
    $slug =~ s/_+/_/g;
    $slug = substr( $slug, 0, 64 );
    return $slug if $slug ne '';
    return 'submenu';
}

sub _fetch_nav_submenu_rows {
    my ( $self, $c, $category, $site_name ) = @_;
    return [] unless $self->_ensure_nav_submenu_table($c);

    $site_name //= $self->_current_site($c);
    my @rows;
    eval {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        my $sth = $dbh->prepare(q{
            SELECT *
            FROM nav_submenu_tb
            WHERE category = ?
              AND status = 1
              AND (sitename = ? OR sitename = 'All')
            ORDER BY section_order ASC, label ASC
        });
        $sth->execute( $category, $site_name );
        while ( my $row = $sth->fetchrow_hashref ) {
            push @rows, $row;
        }
    };
    if ($@) {
        $c->log->error("Error loading nav submenus for $category: $@");
        return [];
    }

    my %by_id;
    for my $row (@rows) {
        my $sid = $row->{submenu_id} // next;
        my $existing = $by_id{$sid};
        if ( !$existing ) {
            $by_id{$sid} = $row;
            next;
        }
        if ( ( $row->{sitename} // '' ) ne 'All' ) {
            $by_id{$sid} = $row;
        }
    }

    return [ sort { ( $a->{section_order} || 0 ) <=> ( $b->{section_order} || 0 )
                    || lc( $a->{label} // '' ) cmp lc( $b->{label} // '' ) } values %by_id ];
}

sub get_submenus_for_category {
    my ( $self, $category, $c, $site_name ) = @_;
    if ($c) {
        my $rows = $self->_fetch_nav_submenu_rows( $c, $category, $site_name );
        if (@$rows) {
            return [
                map { +{ id => $_->{submenu_id}, label => $_->{label} } } @$rows
            ];
        }
    }
    return $NAV_SUBMENU_CATALOG{$category} // [];
}

sub build_submenu_catalog_for_site {
    my ( $self, $c, $site_name ) = @_;
    $site_name //= $self->_current_site($c);
    my %catalog;
    for my $cat ( @{ $self->_nav_categories_for_user( $c, $c->stash->{is_admin} ? 1 : 0 ) } ) {
        $catalog{$cat} = $self->get_submenus_for_category( $cat, $c, $site_name );
    }
    return \%catalog;
}

sub build_submenu_labels_for_site {
    my ( $self, $c, $site_name ) = @_;
    $site_name //= $self->_current_site($c);
    my %labels = %NAV_SUBMENU_LABELS;
    if ( $self->_ensure_nav_submenu_table($c) ) {
        eval {
            my $dbh = $c->model('DBEncy')->schema->storage->dbh;
            my $sth = $dbh->prepare(q{
                SELECT submenu_id, label
                FROM nav_submenu_tb
                WHERE status = 1 AND (sitename = ? OR sitename = 'All')
            });
            $sth->execute($site_name);
            while ( my ( $id, $label ) = $sth->fetchrow_array ) {
                $labels{$id} = $label if defined $id && $id ne '';
            }
        };
    }
    return \%labels;
}

sub get_custom_submenu_sections {
    my ( $self, $c, $category, $site_name ) = @_;
    my $rows = $self->_fetch_nav_submenu_rows( $c, $category, $site_name );
    return [ grep { !$_->{is_system} } @$rows ];
}

sub group_menu_links_by_submenu {
    my ( $self, $links, $category, $c, $site_name ) = @_;
    my @out_links = @{ $links || [] };
    my %by;
    for my $l (@out_links) {
        next unless ref($l) eq 'HASH';
        my $cat = $self->_normalize_link_category( $l->{category} // $category );
        my $sub = $self->normalize_link_submenu( $cat, $l->{submenu}, $c, $site_name );
        push @{ $by{$sub} }, $l;
    }
    return \%by;
}

sub default_submenu_for_category {
    my ($self, $category) = @_;
    return $NAV_SUBMENU_DEFAULTS{$category} // 'main';
}

sub normalize_link_submenu {
    my ( $self, $category, $submenu, $c, $site_name ) = @_;
    $category = $self->_normalize_link_category($category);
    my $default = $self->default_submenu_for_category($category);
    $submenu = $default if !defined $submenu || $submenu eq '';
    my @allowed = map { $_->{id} }
        @{ $self->get_submenus_for_category( $category, $c, $site_name ) };
    return $submenu if @allowed && grep { $_ eq $submenu } @allowed;
    return $submenu
        if defined $submenu
        && $submenu ne ''
        && $submenu =~ /^[a-z][a-z0-9_]{0,62}$/;
    return $default;
}

sub submenu_display_label {
    my ( $self, $submenu, $c, $site_name ) = @_;
    return '' unless defined $submenu && $submenu ne '';
    if ($c) {
        my $labels = $self->build_submenu_labels_for_site( $c, $site_name );
        return $labels->{$submenu} if $labels->{$submenu};
    }
    return $NAV_SUBMENU_LABELS{$submenu} // $submenu;
}

sub _normalize_link_category {
    my ($self, $category) = @_;
    return 'Hosted_links' if defined $category && $category eq 'Hosted_link';
    return $category // '';
}

sub filter_menu_links_by_submenu {
    my ( $self, $links, $want_submenu, $default_submenu, $c, $site_name ) = @_;
    $default_submenu //= 'main';
    my @out;
    for my $l ( @{ $links || [] } ) {
        next unless ref($l) eq 'HASH';
        my $cat = $self->_normalize_link_category( $l->{category} );
        my $sub = $self->normalize_link_submenu( $cat, $l->{submenu}, $c, $site_name );
        push @out, $l if $sub eq $want_submenu;
    }
    return \@out;
}

sub filter_menu_links_by_submenus {
    my ( $self, $links, $want_submenus, $c, $site_name ) = @_;
    $want_submenus = [$want_submenus] unless ref($want_submenus) eq 'ARRAY';
    my %want = map { $_ => 1 } grep { defined $_ && $_ ne '' } @$want_submenus;
    return [] unless %want;
    my @out;
    for my $l ( @{ $links || [] } ) {
        next unless ref($l) eq 'HASH';
        my $cat = $self->_normalize_link_category( $l->{category} );
        my $sub = $self->normalize_link_submenu( $cat, $l->{submenu}, $c, $site_name );
        push @out, $l if $want{$sub};
    }
    return \@out;
}

# Public + user's private hosted menu rows (Hosted_links and legacy Hosted_link category)
sub get_merged_hosted_menu_links {
    my ($self, $c, $site_name) = @_;
    $site_name //= $self->_current_site($c);
    my %seen_id;
    my @merged;
    for my $cat (qw(Hosted_links Hosted_link)) {
        for my $l (@{ $self->get_merged_menu_links( $c, $cat, $site_name ) }) {
            next unless ref($l) eq 'HASH';
            my $id = $l->{id};
            next if defined $id && $seen_id{$id}++;
            push @merged, $l;
        }
    }
    @merged = sort { ( $a->{link_order} || 0 ) <=> ( $b->{link_order} || 0 ) } @merged;
    return \@merged;
}

# True when domain is a public DNS name (not .local, dev TLD, localhost, or IP).
sub is_public_dns_domain {
    my ( $self, $domain ) = @_;
    require Comserv::Util::HostingAccount;
    return Comserv::Util::HostingAccount::is_public_dns_domain($domain);
}

# Features dropdown: CSC public product overview (no subscription required).
sub features_nav_visible {
    my ( $self, $c ) = @_;
    my $sn = $c->session->{SiteName} || $c->stash->{SiteName} || '';
    return 0 unless $sn ne '';
    return lc($sn) eq 'csc' ? 1 : 0;
}

# Hosted dropdown: CSC hub, active hosted customer sites, or referring sites with clients.
sub hosted_nav_visible {
    my ( $self, $c ) = @_;
    my $sn = $c->session->{SiteName} || $c->stash->{SiteName} || '';
    return 0 unless $sn ne '';
    return 1 if lc($sn) eq 'csc';

    my $visible = 0;
    eval {
        my $schema = $c->model('DBEncy');
        my $acct   = $schema->resultset('Accounting::HostingAccount')->search(
            { sitename => $sn, status => { -in => [qw(active pending)] } },
            { rows => 1 },
        )->single;
        $visible = 1 if $acct;

        unless ($visible) {
            my $ref = $schema->resultset('Accounting::HostingAccount')->search(
                { referring_sitename => $sn, status => 'active' },
                { rows => 1 },
            )->single;
            $visible = 1 if $ref;
        }
    };
    return $visible;
}

sub _is_csc_hosting_admin {
    my ( $self, $c ) = @_;
    my $sn = lc( $c->session->{SiteName} || $c->stash->{SiteName} || '' );
    return ( $c->stash->{is_admin} || 0 ) && $sn eq 'csc';
}

sub _user_admin_sitenames {
    my ( $self, $c ) = @_;
    my $user_id = $c->session->{user_id} or return [];
    my %seen;
    my @names;
    eval {
        my @roles = $c->model('DBEncy')->resultset('UserSiteRole')->search(
            {
                user_id   => $user_id,
                is_active => 1,
                role      => { -like => 'admin' },
            },
            { prefetch => 'site' },
        )->all;
        for my $role (@roles) {
            my $site = eval { $role->site };
            my $name = $site && $site->can('name') ? ( $site->name // '' ) : '';
            next unless $name ne '';
            next if $seen{ lc($name) }++;
            $seen{ lc($name) } = 1;
            push @names, $name;
        }
    };
    return \@names;
}

sub _sitename_in_list {
    my ( $self, $name, $list ) = @_;
    return 0 unless defined $name && $name ne '';
    my $want = lc $name;
    return 1 if grep { lc($_) eq $want } @{ $list || [] };
    return 0;
}

sub _user_contact_email {
    my ( $self, $c ) = @_;
    my $user_id = $c->session->{user_id} or return '';
    my $user = eval { $c->model('DBEncy')->resultset('User')->find($user_id) };
    return lc( $user->email // '' ) if $user;
    return '';
}

# Active hosting accounts visible to the current user (before public-domain filter).
sub _hosted_accounts_for_viewer {
    my ( $self, $c ) = @_;
    my $current_site = $c->session->{SiteName} || $c->stash->{SiteName} || '';
    my @accounts;

    eval {
        my $schema = $c->model('DBEncy');
        my $rs     = $schema->resultset('Accounting::HostingAccount');

        if ( $self->_is_csc_hosting_admin($c) ) {
            @accounts = $rs->search( { status => 'active' }, { order_by => 'sitename' } )->all;
        }
        elsif ( $c->stash->{is_admin} ) {
            my $admin_sites = $self->_user_admin_sitenames($c);
            if (@$admin_sites) {
                my @ors;
                for my $sn (@$admin_sites) {
                    push @ors, { sitename           => $sn };
                    push @ors, { referring_sitename => $sn };
                }
                @accounts = $rs->search(
                    { -and => [ { status => 'active' }, { -or => \@ors } ] },
                    { order_by => 'sitename' },
                )->all if @ors;
            }
        }
        elsif ( lc($current_site) eq 'csc' ) {
            # Public CSC catalogue: guests and members see all active hosted sites (public DNS filtered later).
            @accounts = $rs->search( { status => 'active' }, { order_by => 'sitename' } )->all;
        }
        elsif ( $c->session->{user_id} ) {
            my $email = $self->_user_contact_email($c);
            my @ors;
            push @ors, { contact_email => $email } if $email ne '';
            push @ors, { sitename => $current_site } if $current_site ne '';
            @accounts = $rs->search(
                { -and => [ { status => 'active' }, { -or => \@ors } ] },
                { order_by => 'sitename' },
            )->all if @ors;
        }
        elsif ( $current_site ne '' ) {
            my $acct = $rs->search(
                { sitename => $current_site, status => 'active' },
                { rows => 1 },
            )->single;
            push @accounts, $acct if $acct;
        }
    };

    return \@accounts;
}

sub _catalog_push_host {
    my ( $self, $c, $seen, $out, $args ) = @_;
    require Comserv::Util::HostingAccount;

    my $sitename = $args->{sitename} // '';
    return 0 unless $self->_hosted_catalog_visible_to_viewer( $c, $sitename );

    my $hostname = Comserv::Util::HostingAccount::normalize_hostname( $args->{hostname} // '' );
    return 0 unless $hostname;
    return 0 unless $self->is_public_dns_domain($hostname);
    return 0 if $seen->{$hostname}++;
    my $label    = $sitename ne '' ? "$sitename — $hostname" : $hostname;
    push @$out,
        {
        sitename    => $sitename,
        hostname    => $hostname,
        label       => $label,
        url         => "https://$hostname",
        plan_slug   => $args->{plan_slug},
        status      => $args->{status} // 'active',
        domain_type => $args->{domain_type},
        source      => $args->{source} // 'account',
        };
    $seen->{$hostname} = 1;
    return 1;
}

sub _append_sitedomain_public_hosts_for_sitename {
    my ( $self, $c, $seen, $out, $sitename, $meta ) = @_;
    return unless defined $sitename && $sitename ne '';

    eval {
        my $site = $c->model('DBEncy')->resultset('Site')->search(
            { name => $sitename },
            { rows => 1 },
        )->single or return;

        my @sds = $c->model('DBEncy')->resultset('SiteDomain')->search(
            { site_id => $site->id },
            { order_by => 'domain' },
        )->all;

        for my $sd (@sds) {
            $self->_catalog_push_host(
                $c, $seen, $out,
                {
                    %{ $meta || {} },
                    sitename => $sitename,
                    hostname => $sd->domain,
                    source   => 'sitedomain',
                }
            );
        }
    };
}

sub _append_csc_partner_subdomains {
    my ( $self, $c, $seen, $out ) = @_;
    require Comserv::Util::HostingAccount;

    eval {
        my @sds = $c->model('DBEncy')->resultset('SiteDomain')->search(
            {},
            { order_by => 'domain', prefetch => 'site' },
        )->all;

        for my $sd (@sds) {
            my $hostname = Comserv::Util::HostingAccount::normalize_hostname( $sd->domain // '' );
            next unless Comserv::Util::HostingAccount::is_csc_partner_public_host($hostname);

            my $site_name = eval { $sd->site->name } // '';
            next if lc($site_name) eq 'csc';

            $self->_catalog_push_host(
                $c, $seen, $out,
                {
                    sitename => $site_name,
                    hostname => $hostname,
                    status   => 'active',
                    source   => 'partner_domain',
                }
            );
        }
    };
}

# Active hosted sites with resolved public hostnames (nav + /hosted catalogue).
sub get_hosted_sites_catalog {
    my ( $self, $c ) = @_;
    require Comserv::Util::HostingAccount;

    my %seen_domain;
    my @out;
    my %account_sitenames;

    for my $ha ( @{ $self->_hosted_accounts_for_viewer($c) } ) {
        my $sitename = $ha->sitename // '';
        $account_sitenames{ lc($sitename) } = 1 if $sitename ne '';

        my $hostname = Comserv::Util::HostingAccount::resolve_hostname($ha);
        if ( $hostname && $self->is_public_dns_domain($hostname) ) {
            $self->_catalog_push_host(
                $c, \%seen_domain, \@out,
                {
                    sitename    => $sitename,
                    hostname    => $hostname,
                    plan_slug   => $ha->plan_slug,
                    status      => $ha->status,
                    domain_type => $ha->domain_type,
                    source      => 'account',
                }
            );
        }

        $self->_append_sitedomain_public_hosts_for_sitename(
            $c, \%seen_domain, \@out, $sitename,
            {
                plan_slug   => $ha->plan_slug,
                status      => $ha->status,
                domain_type => $ha->domain_type,
            }
        );
    }

    my $current_site = lc( $c->session->{SiteName} || $c->stash->{SiteName} || '' );
    if ( $current_site eq 'csc' ) {
        $self->_append_csc_partner_subdomains( $c, \%seen_domain, \@out );
    }

    return \@out;
}

# Public hosted sites for nav + internal dev domains for site admins only.
sub get_merged_hosted_sites_for_nav {
    my ( $self, $c ) = @_;
    my %seen_domain;
    my @out;
    my $is_admin      = $c->stash->{is_admin} || 0;
    my $admin_sites   = $is_admin ? $self->_user_admin_sitenames($c) : [];

    for my $entry ( @{ $self->get_hosted_sites_catalog($c) } ) {
        my $hostname = $entry->{hostname};
        next if $seen_domain{$hostname}++;
        push @out,
            {
            label  => $entry->{label},
            url    => $entry->{url},
            source => 'account',
            };
        $seen_domain{$hostname} = 1;
    }

    # Internal/dev domains (workshop.local, etc.): admins only, scoped to sites they admin.
    if ($is_admin && @$admin_sites) {
        eval {
            my @sds = $c->model('DBEncy')->resultset('SiteDomain')->search(
                {},
                { order_by => 'domain', prefetch => 'site' },
            )->all;
            for my $sd (@sds) {
                my $d = lc( $sd->domain || '' );
                $d =~ s/:\d+$//;
                next unless $d;
                next if $seen_domain{$d}++;
                next if $self->is_public_dns_domain($d);

                my $site_name = eval { $sd->site->name } // '';
                next unless $self->_sitename_in_list( $site_name, $admin_sites );

                my $label = $site_name ? "$site_name — $d" : $d;
                push @out,
                    {
                    label    => $label,
                    url      => "http://$d",
                    source   => 'domain',
                    internal => 1,
                    };
                $seen_domain{$d} = 1;
            }
        };
    }

    return \@out;
}

# User/admin bookmarks for Hosted menu (hosted_links + hosted_pages submenus, not top-level shortcuts).
sub merge_hosted_resource_links {
    my ( $self, $hosted_merged ) = @_;
    my %seen_id;
    my @out;
    for my $l ( @{ $hosted_merged || [] } ) {
        next unless ref($l) eq 'HASH';
        my $sub = $self->normalize_link_submenu( 'Hosted_links', $l->{submenu} );
        next if $sub eq 'top';
        next if defined $l->{id} && $seen_id{ $l->{id} }++;
        $seen_id{ $l->{id} }++ if defined $l->{id};
        push @out, $l;
    }
    @out = sort { ( $a->{link_order} || 0 ) <=> ( $b->{link_order} || 0 ) } @out;
    return \@out;
}

sub _attach_submenu_to_link_data {
    my ($self, $c, $link_data, $category, $submenu) = @_;
    return unless $self->_internal_links_has_submenu_column($c);
    if ( ( !defined $submenu || $submenu eq '' )
        && $category eq 'Admin_links'
        && !$link_data->{description} )
    {
        $submenu = 'admin_links';
    }
    $link_data->{submenu} = $self->normalize_link_submenu( $category, $submenu, $c );
}

sub get_available_link_sites {
    my ($self, $c) = @_;
    my $sitename = $c->session->{SiteName} || $self->_current_site($c) || '';
    my @sites;

    if (lc($sitename) eq 'csc') {
        eval {
            my $list = $c->model('Site')->get_all_sites($c);
            if ($list && ref($list) eq 'ARRAY') {
                for my $s (@$list) {
                    my $name = ref($s) && $s->can('name') ? $s->name
                        : (ref($s) eq 'HASH' ? ($s->{name} // '') : "$s");
                    push @sites, $name if $name;
                }
            }
        };
        if ($@) {
            $c->log->error("get_available_link_sites: $@");
        }
    }

    push @sites, $sitename if $sitename && $sitename ne 'All';
    my %seen;
    @sites = sort grep { $_ && !$seen{lc($_)}++ } @sites;
    return \@sites;
}

sub _link_row_type {
    my ($self, $link) = @_;
    my $desc = ref($link) eq 'HASH' ? ($link->{description} // '') : ($link->description // '');
    return ($desc && $desc ne '') ? 'private' : 'public';
}

sub _effective_link_sitename {
    my ($self, $c, $cross_site, $sitename) = @_;
    return 'All' if $cross_site;
    return $sitename || $self->_current_site($c);
}

sub user_can_edit_link {
    my ($self, $c, $link) = @_;
    return 0 unless $link && $c->session->{username};

    return 1 if $c->stash->{is_admin};

    my $username = $c->session->{username};
    my $desc = ref($link) eq 'HASH' ? ($link->{description} // '') : ($link->description // '');
    return ($desc && $desc eq $username) ? 1 : 0;
}

# Merged public + current user's private links for a menu category
sub get_merged_menu_links {
    my ($self, $c, $category, $site_name) = @_;
    $site_name //= $self->_current_site($c);

    my @merged;
    my $username = $c->session->{username} || '';
    $self->_ensure_internal_links_public_visible_column($c);

    eval {
        my %public_where = (
            category => $category,
            sitename => [ $site_name, 'All' ],
            status   => 1,
            -or      => $self->_public_link_description_or($c),
        );
        if (  $self->_internal_links_has_public_visible_column($c)
            && !$self->_viewer_sees_member_content($c) )
        {
            $public_where{public_visible} = 1;
        }

        my $rs = $c->model('DBEncy')->resultset('InternalLinksTb')->search(
            \%public_where,
            { order_by => { -asc => 'link_order' } }
        );

        while (my $row = $rs->next) {
            my %link = $row->get_columns;
            next unless $self->_link_visible_to_viewer( $c, \%link );
            $link{link_type} = 'public';
            $link{can_edit}  = $self->user_can_edit_link($c, \%link) ? 1 : 0;
            push @merged, \%link;
        }

        if ($username) {
            my $prs = $c->model('DBEncy')->resultset('InternalLinksTb')->search(
                {
                    category    => $category,
                    sitename    => [ $site_name, 'All' ],
                    description => $username,
                    status      => 1,
                },
                { order_by => { -asc => 'link_order' } }
            );

            while (my $row = $prs->next) {
                my %link = $row->get_columns;
                $link{link_type} = 'private';
                $link{owner}     = $username;
                $link{can_edit}  = 1;
                push @merged, \%link;
            }
        }
    };
    if ($@) {
        $c->log->error("Error getting merged menu links for $category: $@");
    }

    @merged = sort { ($a->{link_order} || 0) <=> ($b->{link_order} || 0) } @merged;
    return \@merged;
}

# Method to get internal links for a specific category and site
sub get_internal_links {
    my ( $self, $c, $category, $site_name, $opts ) = @_;
    $opts ||= {};
    my $include_hidden = $opts->{include_hidden} ? 1 : 0;

    $c->log->debug("Getting internal links for category: $category, site: $site_name");
    
    # Initialize results array
    my @results;
    $self->_ensure_internal_links_public_visible_column($c);
    
    # Use eval to catch any database errors
    eval {
        my %where = (
            category => $category,
            sitename => [ $site_name, 'All' ],
            -or      => $self->_public_link_description_or($c),
        );
        if (  !$include_hidden
            && $self->_internal_links_has_public_visible_column($c)
            && !$self->_viewer_sees_member_content($c) )
        {
            $where{public_visible} = 1;
        }

        my $rs = $c->model('DBEncy')->resultset('InternalLinksTb')->search(
            \%where,
            { order_by => { -asc => 'link_order' } }
        );
        
        while (my $row = $rs->next) {
            my %link = $row->get_columns;
            next if !$include_hidden && !$self->_link_visible_to_viewer( $c, \%link );
            push @results, \%link;
        }
        
        if (!@results) {
            my $dbh = $c->model('DBEncy')->schema->storage->dbh;
            my $desc_sql = $c->stash->{is_admin}
                ? q{(description IS NULL OR description = '' OR description = 'admin_only')}
                : q{(description IS NULL OR description = '')};
            my $query = qq{
                SELECT *
                FROM internal_links_tb
                WHERE category = ?
                  AND (sitename = ? OR sitename = 'All')
                  AND $desc_sql
            };
            if (  !$include_hidden
                && $self->_internal_links_has_public_visible_column($c)
                && !$self->_viewer_sees_member_content($c) )
            {
                $query .= ' AND public_visible = 1';
            }
            $query .= ' ORDER BY link_order';
            my $sth = $dbh->prepare($query);
            $sth->execute($category, $site_name);
            
            while (my $row = $sth->fetchrow_hashref) {
                next if !$include_hidden && !$self->_link_visible_to_viewer( $c, $row );
                push @results, $row;
            }
        }
        
        $c->log->debug("Found " . scalar(@results) . " internal links");
    };
    if ($@) {
        $c->log->error("Error getting internal links: $@");
    }
    
    return \@results;
}

# Method to get pages for a specific menu and site
sub get_pages {
    my ($self, $c, $menu, $site_name, $status) = @_;
    
    $status //= 2; # Default status is 2 (active)
    
    $c->log->debug("Getting pages for menu: $menu, site: $site_name, status: $status");
    
    # Initialize results array
    my @results;
    
    # Use eval to catch any database errors
    eval {
        # Fetch active and inactive to let local overrides fully eclipse shared pages
        my $rs = $c->model('DBEncy')->resultset('Page')->search({
            '-or' => [
                { sitename => [ $site_name, 'CSC', 'All' ] },
                { share_with => 'all' },
                { share_with => { 'like' => "%$site_name%" } }
            ]
        });

        my %pages_by_code;
        while (my $row = $rs->next) {
            my $code = $row->page_code;
            my $site = $row->sitename;
            
            # Priority: 3 = Local Site override, 2 = CSC/All fallback, 1 = Shared
            my $priority = 1;
            if ($site eq $site_name) {
                $priority = 3;
            } elsif ($site eq 'CSC' || $site eq 'All') {
                $priority = 2;
            }
            
            if (!exists $pages_by_code{$code} || $pages_by_code{$code}->{_priority} < $priority) {
                my $page_data = { $row->get_columns };
                $page_data->{_priority} = $priority;
                $pages_by_code{$code} = $page_data;
            }
        }

        # Filter by active status and requested menu
        my @filtered;
        for my $code (keys %pages_by_code) {
            my $p = $pages_by_code{$code};
            if ($p->{status} eq 'active' && lc($p->{menu}) eq lc($menu)) {
                push @filtered, $p;
            }
        }

        @results = sort { ($a->{link_order} || 0) <=> ($b->{link_order} || 0) } @filtered;
        $c->log->debug("Found " . scalar(@results) . " pages");
    };
    if ($@) {
        $c->log->error("Error getting pages: $@");
    }

    return \@results;
}

# Method to get admin pages
sub get_admin_pages {
    my ($self, $c, $site_name) = @_;
    
    $c->log->debug("Getting admin pages for site: $site_name");
    
    # Initialize results array
    my @results;
    
    # Use eval to catch any database errors
    eval {
        my $rs = $c->model('DBEncy')->resultset('Page')->search({
            '-or' => [
                { sitename => [ $site_name, 'CSC', 'All' ] },
                { share_with => 'all' },
                { share_with => { 'like' => "%$site_name%" } }
            ]
        });

        my %pages_by_code;
        while (my $row = $rs->next) {
            my $code = $row->page_code;
            my $site = $row->sitename;
            
            # Priority: 3 = Local Site override, 2 = CSC/All fallback, 1 = Shared
            my $priority = 1;
            if ($site eq $site_name) {
                $priority = 3;
            } elsif ($site eq 'CSC' || $site eq 'All') {
                $priority = 2;
            }
            
            if (!exists $pages_by_code{$code} || $pages_by_code{$code}->{_priority} < $priority) {
                my $page_data = { $row->get_columns };
                $page_data->{_priority} = $priority;
                $pages_by_code{$code} = $page_data;
            }
        }

        # Filter by active status and requested menu
        my @filtered;
        for my $code (keys %pages_by_code) {
            my $p = $pages_by_code{$code};
            if ($p->{status} eq 'active' && lc($p->{menu}) eq 'admin') {
                push @filtered, $p;
            }
        }

        @results = sort { ($a->{link_order} || 0) <=> ($b->{link_order} || 0) } @filtered;

        if (!@results) {
            # Get the database handle from the DBEncy model
            my $dbh = $c->model('DBEncy')->schema->storage->dbh;

            my $query = "SELECT * FROM page WHERE menu = 'Admin' AND status = 'active' AND (sitename = ? OR sitename = 'CSC' OR share_with = 'all' OR share_with LIKE ?) ORDER BY link_order";
            my $sth = $dbh->prepare($query);
            $sth->execute($site_name, "%$site_name%");
            
            # Fetch all results
            while (my $row = $sth->fetchrow_hashref) {
                push @results, $row;
            }
        }
        
        $c->log->debug("Found " . scalar(@results) . " admin pages");
    };
    if ($@) {
        $c->log->error("Error getting admin pages: $@");
    }
    
    return \@results;
}

# Method to get admin links
sub get_admin_links {
    my ($self, $c, $site_name) = @_;
    
    $c->log->debug("Getting admin links for site: $site_name");
    
    # Initialize results array
    my @results;
    
    # Use eval to catch any database errors
    eval {
        # Try to use the DBIx::Class API first
        my $rs = $c->model('DBEncy')->resultset('InternalLinksTb')->search({
            category => 'Admin_links',
            sitename => [ $site_name, 'All' ],
            -or => [
                { description => undef },
                { description => '' },
            ],
        }, {
            order_by => { -asc => 'link_order' }
        });
        
        while (my $row = $rs->next) {
            push @results, { $row->get_columns };
        }
        
        # If no results and we might need to fall back to direct SQL
        if (!@results) {
            # Get the database handle from the DBEncy model
            my $dbh = $c->model('DBEncy')->schema->storage->dbh;
            
            # Prepare and execute the query
            my $query = "SELECT * FROM internal_links_tb WHERE category = 'Admin_links' AND (sitename = ? OR sitename = 'All') ORDER BY link_order";
            my $sth = $dbh->prepare($query);
            $sth->execute($site_name);
            
            # Fetch all results
            while (my $row = $sth->fetchrow_hashref) {
                push @results, $row;
            }
        }
        
        $c->log->debug("Found " . scalar(@results) . " admin links");
    };
    if ($@) {
        $c->log->error("Error getting admin links: $@");
    }
    
    return \@results;
}

# Method to get private links for a specific user
sub get_private_links {
    my ($self, $c, $username, $site_name) = @_;
    
    $c->log->debug("Getting private links for user: $username, site: $site_name");
    return [] unless $username;

    $self->_ensure_internal_links_submenu_column($c);

    my @results;
    eval {
        my $rs = $c->model('DBEncy')->resultset('InternalLinksTb')->search(
            {
                description => $username,
                status      => 1,
                sitename    => [ $site_name, 'All' ],
            },
            {
                order_by => [
                    { -asc => 'category' },
                    { -asc => 'link_order' },
                    { -asc => 'name' },
                ],
            }
        );
        
        while (my $row = $rs->next) {
            push @results, { $row->get_columns };
        }
        
        $c->log->debug("Found " . scalar(@results) . " private links for user: $username");
    };
    if ($@) {
        $c->log->error("Error getting private links: $@");
    }

    if (!@results) {
        my $fallback = $self->_fetch_private_links_sql( $c, $username, $site_name );
        @results = @$fallback if $fallback && @$fallback;
    }
    
    return \@results;
}

# All private links for manage page and user dropdown (any site scope).
sub get_all_private_links_for_user {
    my ($self, $c, $username) = @_;
    return [] unless $username;

    $self->_ensure_internal_links_submenu_column($c);

    my @results;
    eval {
        my $rs = $c->model('DBEncy')->resultset('InternalLinksTb')->search(
            { description => $username, status => 1 },
            {
                order_by => [
                    { -asc => 'category' },
                    { -asc => 'sitename' },
                    { -asc => 'link_order' },
                    { -asc => 'name' },
                ],
            }
        );
        while (my $row = $rs->next) {
            my %link = $row->get_columns;
            $link{link_type} = 'private';
            $link{can_edit}  = 1;
            push @results, \%link;
        }
    };
    if ($@) {
        $c->log->error("Error getting all private links for $username: $@");
    }

    if (!@results) {
        my $fallback = $self->_fetch_private_links_sql( $c, $username );
        if ($fallback && @$fallback) {
            for my $l (@$fallback) {
                $l->{link_type} = 'private';
                $l->{can_edit}  = 1;
            }
            @results = @$fallback;
        }
    }

    return \@results;
}

# Unified method to add links (public or private based on permissions)
sub add_link :Path('/navigation/add_link') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is logged in
    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $c->session->{username}) {
        $c->flash->{error_msg} = "You must be logged in to add links.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    my $username = $c->session->{username};
    my $user_roles = $c->session->{roles} || [];
    my $user_sitename = $c->session->{SiteName} || '';
    
    # Determine user permissions
    my $permissions = $self->get_user_link_permissions($c);
    my $return_url  = $c->req->param('return_url') || $c->req->referer || $c->uri_for('/')->as_string;
    # ensure we always have a safe relative fallback
    $return_url = $c->uri_for('/')->as_string unless $return_url;
    # Provide the complete list of all menus (from nav_submenu_tb) so the form can show every seeded menu
    eval {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        my $sth = $dbh->prepare("SELECT DISTINCT category FROM nav_submenu_tb WHERE status=1 ORDER BY category");
        $sth->execute();
        my @all_menus;
        while (my ($cat) = $sth->fetchrow_array) { push @all_menus, $cat; }
        $c->stash->{all_menus} = \@all_menus if @all_menus;
    };
    if ($@) {
        $c->log->warn("Could not load complete menu list for add_link form: $@");
    }

    
    if ($c->req->method eq 'POST') {
        my $name = $c->req->param('name');
        my $url = $c->req->param('url');
        my $target = $self->_default_external_target($c->req->param('url'), $c->req->param('target') || '_self');
        my $category = $c->req->param('category');
        my $sitename = $c->req->param('sitename');
        my $link_type = $c->req->param('link_type') || 'private'; # private, public
        my $cross_site = $c->req->param('cross_site') ? 1 : 0;    # show on all sites
        my $effective_site = $cross_site ? 'All' : ($sitename || $user_sitename || $self->_current_site($c));
        my $submenu = $c->req->param('submenu');
        
        # Validate required fields
        unless ($name && $url && $category) {
            $c->flash->{error_msg} = "Name, URL, and category are required fields.";
            $c->stash->{permissions} = $permissions;
            $c->stash->{form_data} = $c->req->params;
            $c->stash->{template} = 'Navigation/add_link.tt';
            return;
        }
        
        # Validate permissions
        unless ($self->validate_link_permissions($c, $link_type, $category, $effective_site)) {
            $c->flash->{error_msg} = "You don't have permission to create this type of link.";
            $c->stash->{permissions} = $permissions;
            $c->stash->{form_data} = $c->req->params;
            $c->stash->{template} = 'Navigation/add_link.tt';
            return;
        }
        
        # Get the next link order for this category/site
        my $max_order = $self->get_max_link_order($c, $category, $effective_site, $username, $link_type);
        
        # Prepare link data
        my $link_data = {
            category => $category,
            sitename => $effective_site,
            name => $name,
            url => $url,
            target => $target,
            link_order => $max_order + 1,
            status => 1
        };
        
        # For private links, store username in description
        if ($link_type eq 'private') {
            $link_data->{description} = $username;
        }

        $self->_attach_submenu_to_link_data($c, $link_data, $category, $submenu);

        $self->_ensure_internal_links_public_visible_column($c);
        if ( $self->_internal_links_has_public_visible_column($c) ) {
            if ( $link_type eq 'public' && $permissions->{can_create_public} ) {
                $link_data->{public_visible}
                    = $c->req->param('public_visible') ? 1 : 0;
            }
            else {
                $link_data->{public_visible} = 1;
            }
        }
        
        # Add the link
        eval {
            $c->model('DBEncy')->resultset('InternalLinksTb')->create($link_data);
            $c->flash->{success_msg} = "Link '$name' added successfully.";
            # Clear cached nav so the new link appears immediately
            $self->clear_navigation_cache($c);
        };
        if ($@) {
            $c->log->error("Error adding link: $@");
            $c->flash->{error_msg} = "Error adding link. Please try again.";
        }
        
        # Redirect to where user clicked "+ Add Link"
        $c->response->redirect($return_url);
        return;
    }
    
    # Pre-populate form based on URL parameters
    my $preset_menu     = $c->req->param('menu') || '';
    my $preset_category = $c->req->param('category')
        || $self->_menu_param_to_category($preset_menu)
        || 'Member_links';
    my $preset_sitename = $c->req->param('sitename') || $user_sitename;
    my $preset_submenu  = $c->req->param('submenu') || '';
    if ( !$preset_submenu && $preset_menu eq 'Admin' && $preset_category eq 'Admin_links' ) {
        $preset_submenu = 'admin_links';
    }
    $preset_submenu ||= $self->default_submenu_for_category($preset_category);
    my $preset_return   = $return_url;
    my $preset_linktype = 'private';
    
    $c->stash->{permissions} = $permissions;
    $c->stash->{preset_submenu} = $preset_submenu;
    $c->stash->{preset_category} = $preset_category;
    $c->stash->{preset_sitename} = $preset_sitename;
    $c->stash->{preset_return_url} = $preset_return;
    $c->stash->{preset_link_type} = $preset_linktype;
    $c->stash->{template} = 'Navigation/add_link.tt';
}

# User's personal private links only (all site scopes).
sub manage_private_links :Path('/navigation/manage_private_links') :Args(0) {
    my ($self, $c) = @_;

    my $root_controller = $c->controller('Root');
    unless ( $root_controller->user_exists($c) && $c->session->{username} ) {
        $c->flash->{error_msg} = 'You must be logged in to manage your private links.';
        $c->response->redirect( $c->uri_for('/user/login') );
        return;
    }

    my $username = $c->session->{username};
    my $private_links = $self->get_all_private_links_for_user( $c, $username );
    for my $link (@$private_links) {
        $link->{link_type} = 'private';
        $link->{can_edit}   = 1;
    }

    $c->stash->{private_links}   = $private_links;
    $c->stash->{template_title}  = 'Manage My Private Links';
    $c->stash->{template}        = 'Navigation/manage_private_links.tt';
}

# Admin/public link management; normal users are sent to manage_private_links.
sub manage_links :Path('/navigation/manage_links') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is logged in
    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $c->session->{username}) {
        $c->flash->{error_msg} = "You must be logged in to manage links.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    my $username = $c->session->{username};
    my $permissions = $self->get_user_link_permissions($c);

    unless ( $permissions->{can_create_public} ) {
        $c->response->redirect( $c->uri_for('/navigation/manage_private_links') );
        return;
    }
    
    # Get user's links based on permissions
    my $user_links = $self->get_user_manageable_links($c, $username, $permissions);
    
    $c->stash->{user_links} = $user_links;
    $c->stash->{permissions} = $permissions;
    $c->stash->{template_title} = 'Manage Links';

    # Make sure navigation data (merged links, submenus, pages) is available for the real preview
    $self->populate_navigation_data($c);

    my $sitename = $c->session->{SiteName} || $self->_current_site($c);

    # Prepare editor data: current real menu structure (existing links + pages) so user sees "how the menu will look or act"
    # Plus full CSC stock palette for adding.
    my %editor_menus;
    for my $cat (qw(Main_links HelpDesk_links Admin_links)) {
        my $links = $self->get_merged_menu_links($c, $cat, $sitename) || [];
        my $grouped = $self->group_menu_links_by_submenu($links, $cat, $c, $sitename) || {};

        my %secs;
        for my $sub (keys %$grouped) {
            $secs{$sub} = [ map { +{ type => 'link', data => $_ } } @{ $grouped->{$sub} } ];
        }

        # Add pages that belong to this menu (they appear in the real menu)
        my $menu_short = $cat;
        $menu_short =~ s/_links//i;
        my $pages = $self->get_pages($c, $menu_short, $sitename) || [];
        for my $p (@$pages) {
            my $sub = 'cms_pages'; # or top / public_links depending on the menu
            push @{ $secs{$sub} ||= [] }, { type => 'page', data => $p };
        }

        $editor_menus{$cat} = {
            label => ($cat =~ s/_links//r),
            sections => \%secs,
        };
    }
    $c->stash->{editor_menus} = \%editor_menus;

    # Full CSC stock for the palette (all items the user can drag in)
    $c->stash->{csc_stock_palette} = $self->get_csc_stock_catalog($c);

    # Also the submenus for "containers" management (like cards in page editor)
    my $submenus = {};
    for my $cat (keys %editor_menus) {
        $submenus->{$cat} = $self->get_submenus_for_category($cat, $c, $sitename) || [];
    }
    $c->stash->{editor_submenus} = $submenus;

    $c->stash->{template} = 'Navigation/manage_links.tt';
}

# Button on manage links page runs this to ensure the living plan page exists in the live DB.
sub seed_plan_page :Path('/navigation/seed_plan_page') :Args(0) {
    my ($self, $c) = @_;

    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $c->session->{username}) {
        $c->flash->{error_msg} = "You must be logged in.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    my $permissions = $self->get_user_link_permissions($c);
    unless ( $permissions->{can_create_public} ) {
        $c->flash->{error_msg} = "Admin access required to seed plan page.";
        $c->response->redirect( $c->uri_for('/navigation/manage_links') );
        return;
    }

    my $plan_body = q{<h1>Menu System DB Migration &amp; Upgrade Plan (2026)</h1>
<p><strong>LIVING DOCUMENT</strong> — Edit this page in the normal CMS editor (/pages/edit/menu-system-upgrade-plan) to track progress, add notes, and update the checklist as we implement the changes. This page was created/updated by the "Run Seed" button on the Manage Links screen.</p>

<p><a href="/navigation/manage_links">← Back to Manage Links (menu editor)</a></p>

<h2>Goal</h2>
<p>DB-dominated menu system. CSC provides the base/mandatory stock items and lists (Main, HelpDesk, Admin, etc.). SiteName admins rename, reorder, and change list appearance according to the page/context. When editing a menu the admin sees <strong>all CSC stock items</strong>. Styles come only from the chosen SiteName theme. Critical items keep hard-coded .tt fallbacks for resilience.</p>

<h2>Progress (update this section by editing the page)</h2>
<h3>✅ Phase 1: Foundations — COMPLETE</h3>
<ul>
<li>menu_stock + site_menu_overrides tables + DBIC models</li>
<li>Seeder with CSC stock (mandatory flags, gating)</li>
<li>Controller population of stock catalog into stash</li>
<li>Link + "Run Seed" button added to manage_links</li>
</ul>

<h3>🔄 Phase 2: Drag &amp; Drop + Stock Browser Editor</h3>
<p>Basic drag &amp; drop ordering has been added to this manage links table. Full "Browse all CSC Stock" palette and per-item override form coming next.</p>

<h2>Notes Log</h2>
<p><strong>2026-06-16:</strong> Plan page now lives in the DB and is linked from the menu edit UI. Click the seed button anytime to refresh it. Drag &amp; drop reordering for links is active on this page.</p>};

    eval {
        my $page_rs = $c->model('DBEncy')->resultset('Page');
        $page_rs->update_or_create({
            sitename   => 'CSC',
            menu       => 'Admin',
            page_code  => 'menu-system-upgrade-plan',
            title      => 'Menu System Upgrade Plan - Living Document',
            body       => $plan_body,
            status     => 'active',
            roles      => 'admin',
            link_order => 500,
            created_by => $c->session->{username} || 'admin-seed',
        });

        # Also try pages_content for broader compatibility
        eval {
            my $content_rs = $c->model('DBEncy')->resultset('PagesContent');
            $content_rs->update_or_create({
                sitename  => 'CSC',
                page_code => 'menu-system-upgrade-plan',
                title     => 'Menu System Upgrade Plan - Living Document',
                body      => $plan_body,
                menu      => 'Admin',
                status    => 'active',
                roles     => 'admin',
                link_order => 500,
            });
        };

        $c->flash->{success_msg} = "Plan page seeded/updated in the live database. You can now visit /page/menu-system-upgrade-plan and edit it like any CMS page.";
    };
    if ($@) {
        $c->log->error("seed_plan_page failed: $@");
        $c->flash->{error_msg} = "Could not seed plan page: $@";
    }

    $c->response->redirect( $c->uri_for('/navigation/manage_links') );
}

# Support for drag & drop reordering on the manage links table.
# Expects POST with ordered list of link ids.
sub update_link_orders :Path('/navigation/update_link_orders') :Args(0) {
    my ($self, $c) = @_;

    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $c->session->{username}) {
        $c->response->body('{"error":"login required"}');
        $c->response->status(403);
        return;
    }

    my @ordered_ids = $c->req->param('link_ids');

    my $updated = 0;
    eval {
        my $rs = $c->model('DBEncy')->resultset('InternalLinksTb');
        my $pos = 10;
        for my $id (@ordered_ids) {
            next unless $id =~ /^\d+$/;
            my $link = $rs->find($id);
            next unless $link && $self->user_can_edit_link($c, $link);
            $link->update({ link_order => $pos });
            $pos += 10;
            $updated++;
        }
        $self->clear_navigation_cache($c);
    };
    if ($@) {
        $c->log->error("update_link_orders: $@");
        $c->response->body('{"error":"update failed"}');
        $c->response->status(500);
        return;
    }

    $c->response->body( encode_json({ success => 1, updated => $updated }) );
    $c->response->content_type('application/json');
}

# Save changes from the interactive visual menu editor (drag items between places/sections).
# Expects JSON or form with structure like:
# sections[Main_links][top][] = stock_key_or_id   (repeated for order)
sub save_visual_menu :Path('/navigation/save_visual_menu') :Args(0) {
    my ($self, $c) = @_;

    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $c->session->{username}) {
        $c->flash->{error_msg} = "Login required";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    my $sitename = $c->session->{SiteName} || $self->_current_site($c);
    my $username = $c->session->{username};

    my $data = $c->req->body_data || {};
    my $updated = 0;

    eval {
        my $override_rs = $c->model('DBEncy')->resultset('SiteMenuOverride');
        my $stock_rs    = $c->model('DBEncy')->resultset('MenuStock');
        my $link_rs     = $c->model('DBEncy')->resultset('InternalLinksTb');

        # Handle top-level menu order (drag headers left/right in the bar)
        if ($data->{top_order} && ref $data->{top_order} eq 'ARRAY') {
            my @top = @{$data->{top_order}};
            my $pos = 10;
            foreach my $menu (@top) {
                $override_rs->update_or_create({
                    site_name => $sitename,
                    stock_key => 'top_level_' . $menu,
                    custom_category => 'top_level',
                    custom_submenu => $menu,
                    sort_order => $pos,
                    is_included => 1,
                    created_by => $username,
                    notes => 'Top level menu order override from editor',
                });
                $pos += 10;
                $updated++;
            }
        }

        # Example: data has 'menu_Main_links_top' => [ 'main_home', 'link-123', ... ]
        # or we can accept nested. For simplicity, look for keys like visual_*
        foreach my $key (keys %$data) {
            next unless $key =~ /^visual_(.+?)_(.+)$/;
            my ($cat, $sub) = ($1, $2);
            my $items = $data->{$key};
            $items = [$items] unless ref $items eq 'ARRAY';

            my $pos = 10;
            foreach my $item_key (@$items) {
                if ($item_key =~ /^stock:(.+)$/) {
                    my $stock_key = $1;
                    my $stock = $stock_rs->search({stock_key => $stock_key})->first;
                    next unless $stock;

                    $override_rs->update_or_create({
                        site_name => $sitename,
                        stock_key => $stock_key,
                        stock_id  => $stock->id,
                        custom_submenu => $sub,
                        sort_order => $pos,
                        is_included => 1,
                        created_by => $username,
                    });
                    $updated++;
                } elsif ($item_key =~ /^link:(\d+)$/) {
                    my $lid = $1;
                    my $link = $link_rs->find($lid);
                    next unless $link && $self->user_can_edit_link($c, $link);
                    $link->update({
                        submenu => $sub,
                        link_order => $pos,
                    });
                    $updated++;
                }
                $pos += 10;
            }
        }
        $self->clear_navigation_cache($c);
    };
    if ($@) {
        $c->log->error("save_visual_menu: $@");
        $c->flash->{error_msg} = "Failed to save menu layout: $@";
    } else {
        $c->flash->{success_msg} = "Menu layout saved ($updated changes). The menus will reflect the new order (including top level header positions from bar drag).";
    }
    $c->response->redirect($c->uri_for('/navigation/manage_links'));
}

sub _require_submenu_admin {
    my ( $self, $c ) = @_;
    my $root_controller = $c->controller('Root');
    unless ( $root_controller->user_exists($c) && $c->session->{username} ) {
        $c->flash->{error_msg} = 'You must be logged in.';
        $c->response->redirect( $c->uri_for('/user/login') );
        return 0;
    }
    my $permissions = $self->get_user_link_permissions($c);
    unless ( $permissions->{can_create_public} ) {
        $c->flash->{error_msg} = 'Only site administrators can manage submenu sections.';
        $c->response->redirect( $c->uri_for('/navigation/manage_private_links') );
        return 0;
    }
    $self->_ensure_nav_submenu_table($c);
    return $permissions;
}

sub _fetch_manageable_submenus {
    my ( $self, $c, $permissions, $filter_site, $filter_category ) = @_;
    my @rows;
    eval {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        my $sql = q{
            SELECT *
            FROM nav_submenu_tb
            WHERE status = 1
        };
        my @bind;
        if ( $filter_category && $filter_category ne '' ) {
            $sql .= ' AND category = ?';
            push @bind, $filter_category;
        }
        if ( $filter_site && $filter_site ne '' ) {
            $sql .= ' AND (sitename = ? OR sitename = ?)';
            push @bind, $filter_site, 'All';
        }
        elsif ( !$permissions->{is_csc} ) {
            my $sn = $c->session->{SiteName} || $self->_current_site($c);
            $sql .= ' AND (sitename = ? OR sitename = ?)';
            push @bind, $sn, 'All';
        }
        $sql .= ' ORDER BY category ASC, sitename ASC, section_order ASC, label ASC';
        my $sth = $dbh->prepare($sql);
        $sth->execute(@bind);
        while ( my $row = $sth->fetchrow_hashref ) {
            push @rows, $row;
        }
    };
    if ($@) {
        $c->log->error("Error listing nav submenus: $@");
    }
    return \@rows;
}

sub manage_submenus :Path('/navigation/manage_submenus') :Args(0) {
    my ( $self, $c ) = @_;
    my $permissions = $self->_require_submenu_admin($c);
    return unless $permissions;

    my $filter_site     = $c->req->param('sitename') || '';
    my $filter_category = $c->req->param('category') || '';

    $c->stash->{submenu_rows}     = $self->_fetch_manageable_submenus(
        $c, $permissions, $filter_site, $filter_category
    );
    $c->stash->{permissions}      = $permissions;
    $c->stash->{filter_site}      = $filter_site;
    $c->stash->{filter_category}  = $filter_category;
    $c->stash->{template_title}   = 'Manage Menu Submenus';
    $c->stash->{template}         = 'Navigation/manage_submenus.tt';
}

sub add_submenu :Path('/navigation/add_submenu') :Args(0) {
    my ( $self, $c ) = @_;
    my $permissions = $self->_require_submenu_admin($c);
    return unless $permissions;

    my $user_sitename = $c->session->{SiteName} || $self->_current_site($c);

    if ( $c->req->method eq 'POST' ) {
        my $category = $c->req->param('category') || 'Admin_links';
        my $cross_site = $c->req->param('cross_site') ? 1 : 0;
        my $sitename   = $cross_site ? 'All' : ( $c->req->param('sitename') || $user_sitename );
        my $label      = $c->req->param('label') || '';
        my $submenu_id = $c->req->param('submenu_id') || $self->_slugify_submenu_id($label);
        my $icon       = $c->req->param('icon') || '';
        my $header_url = $c->req->param('header_url') || '';
        my $section_order = $c->req->param('section_order') || 500;

        unless ( $label && $submenu_id && $category ) {
            $c->flash->{error_msg} = 'Label and menu category are required.';
        }
        elsif ( $submenu_id !~ /^[a-z][a-z0-9_]{0,62}$/ ) {
            $c->flash->{error_msg}
                = 'Submenu ID must be lowercase letters, numbers, and underscores.';
        }
        else {
            eval {
                my $dbh = $c->model('DBEncy')->schema->storage->dbh;
                my $check = $dbh->prepare(
                    'SELECT id FROM nav_submenu_tb '
                    . 'WHERE category = ? AND sitename = ? AND submenu_id = ? LIMIT 1'
                );
                $check->execute( $category, $sitename, $submenu_id );
                if ( $check->fetchrow_arrayref ) {
                    $c->flash->{error_msg}
                        = "Submenu ID '$submenu_id' already exists for this menu and site scope.";
                }
                else {
                    $dbh->do(
                        'INSERT INTO nav_submenu_tb '
                        . '(category, sitename, submenu_id, label, icon, header_url, section_order, is_system, status) '
                        . 'VALUES (?, ?, ?, ?, ?, ?, ?, 0, 1)',
                        undef,
                        $category, $sitename, $submenu_id, $label,
                        $icon, $header_url, $section_order,
                    );
                    $self->clear_navigation_cache($c);
                    $c->flash->{success_msg} = "Submenu '$label' added.";
                    $c->response->redirect( $c->uri_for('/navigation/manage_submenus') );
                    return;
                }
            };
            if ($@) {
                $c->log->error("Error adding submenu: $@");
                $c->flash->{error_msg} = 'Error adding submenu. Please try again.';
            }
        }
    }

    $c->stash->{permissions}    = $permissions;
    $c->stash->{preset_category} = $c->req->param('category') || 'Admin_links';
    $c->stash->{preset_sitename} = $user_sitename;
    $c->stash->{form_data}      = $c->req->params;
    $c->stash->{template_title} = 'Add Menu Submenu';
    $c->stash->{template}       = 'Navigation/add_submenu.tt';
}

sub edit_submenu :Path('/navigation/edit_submenu') :Args(0) {
    my ( $self, $c ) = @_;
    my $permissions = $self->_require_submenu_admin($c);
    return unless $permissions;

    my $id = $c->req->param('id');
    unless ($id) {
        $c->flash->{error_msg} = 'Submenu ID is required.';
        $c->response->redirect( $c->uri_for('/navigation/manage_submenus') );
        return;
    }

    my $row;
    eval {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        my $sth = $dbh->prepare('SELECT * FROM nav_submenu_tb WHERE id = ? LIMIT 1');
        $sth->execute($id);
        $row = $sth->fetchrow_hashref;
    };
    unless ($row) {
        $c->flash->{error_msg} = 'Submenu not found.';
        $c->response->redirect( $c->uri_for('/navigation/manage_submenus') );
        return;
    }

    if ( $c->req->method eq 'POST' ) {
        if ( $c->req->param('delete') && !$row->{is_system} ) {
            eval {
                my $dbh = $c->model('DBEncy')->schema->storage->dbh;
                $dbh->do( 'UPDATE nav_submenu_tb SET status = 0 WHERE id = ?', undef, $id );
                $self->clear_navigation_cache($c);
                $c->flash->{success_msg} = 'Submenu removed.';
            };
            if ($@) {
                $c->log->error("Error deleting submenu: $@");
                $c->flash->{error_msg} = 'Error removing submenu.';
            }
            $c->response->redirect( $c->uri_for('/navigation/manage_submenus') );
            return;
        }

        my $label        = $c->req->param('label') || '';
        my $icon         = $c->req->param('icon') || '';
        my $header_url   = $c->req->param('header_url') || '';
        my $section_order = $c->req->param('section_order') || $row->{section_order} || 0;

        unless ($label) {
            $c->flash->{error_msg} = 'Label is required.';
        }
        else {
            eval {
                my $dbh = $c->model('DBEncy')->schema->storage->dbh;
                $dbh->do(
                    'UPDATE nav_submenu_tb SET label = ?, icon = ?, header_url = ?, section_order = ? WHERE id = ?',
                    undef,
                    $label, $icon, $header_url, $section_order, $id,
                );
                $self->clear_navigation_cache($c);
                $c->flash->{success_msg} = "Submenu '$label' updated.";
                $c->response->redirect( $c->uri_for('/navigation/manage_submenus') );
                return;
            };
            if ($@) {
                $c->log->error("Error updating submenu: $@");
                $c->flash->{error_msg} = 'Error updating submenu.';
            }
        }
    }

    $c->stash->{submenu_row}    = $row;
    $c->stash->{permissions}    = $permissions;
    $c->stash->{form_data}      = $c->req->params;
    $c->stash->{template_title} = 'Edit Menu Submenu';
    $c->stash->{template}       = 'Navigation/edit_submenu.tt';
}

# Method to edit a link
sub edit_link :Path('/navigation/edit_link') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is logged in
    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $c->session->{username}) {
        $c->flash->{error_msg} = "You must be logged in to edit links.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    my $link_id = $c->req->param('id') || $c->req->param('link_id');
    my $username = $c->session->{username};
    
    unless ($link_id) {
        $c->flash->{error_msg} = "Link ID is required.";
        $c->response->redirect($c->uri_for('/navigation/manage_links'));
        return;
    }
    
    # Get the link and verify ownership
    my $link;
    eval {
        $link = $c->model('DBEncy')->resultset('InternalLinksTb')->find($link_id);
    };
    
    unless ($link) {
        $c->flash->{error_msg} = "Link not found.";
        $c->response->redirect($c->uri_for('/navigation/manage_links'));
        return;
    }
    
    unless ($self->user_can_edit_link($c, $link)) {
        $c->flash->{error_msg} = "You can only edit your own links.";
        $c->response->redirect($c->uri_for('/navigation/manage_links'));
        return;
    }
    
    my $permissions = $self->get_user_link_permissions($c);
    $permissions->{available_categories} = $self->_nav_categories_for_user(
        $c,
        ( $c->stash->{is_admin} || 0 ) ? 1 : 0,
        $link->category,
    );
    my $is_private_link = $self->_link_row_type($link) eq 'private';
    $permissions->{editing_private_link} = $is_private_link ? 1 : 0;

    if ($c->req->method eq 'POST') {
        my $name       = $c->req->param('name');
        my $url        = $c->req->param('url');
        my $target     = $self->_default_external_target($url, $c->req->param('target') || '_self');
        my $category   = $c->req->param('category');
        my $link_type  = $c->req->param('link_type') || 'private';
        my $cross_site = $c->req->param('cross_site') ? 1 : 0;
        my $sitename   = $self->_effective_link_sitename($c, $cross_site, $c->req->param('sitename'));
        my $submenu    = $c->req->param('submenu');

        unless ($permissions->{can_create_public}) {
            $link_type = 'private';
        }

        unless ($name && $url && $category) {
            $c->flash->{error_msg} = "Name, URL, and menu are required fields.";
            my %link_data = $link->get_columns;
            $link_data{link_type}  = $link_type;
            $link_data{cross_site} = $cross_site;
            $c->stash->{link} = \%link_data;
            $c->stash->{permissions} = $permissions;
            $c->stash->{template} = 'Navigation/edit_link.tt';
            return;
        }

        unless ($self->validate_link_permissions($c, $link_type, $category, $sitename)) {
            $c->flash->{error_msg} = "You don't have permission to save this link configuration.";
            my %link_data = $link->get_columns;
            $link_data{link_type}  = $link_type;
            $link_data{cross_site} = $cross_site;
            $c->stash->{link} = \%link_data;
            $c->stash->{permissions} = $permissions;
            $c->stash->{template} = 'Navigation/edit_link.tt';
            return;
        }

        my $update = {
            name     => $name,
            url      => $url,
            target   => $target,
            category => $category,
            sitename => $sitename,
        };
        if ($link_type eq 'private') {
            $update->{description} = $username;
        } else {
            $update->{description} = undef;
        }

        $self->_attach_submenu_to_link_data($c, $update, $category, $submenu);

        $self->_ensure_internal_links_public_visible_column($c);
        if ( $self->_internal_links_has_public_visible_column($c) ) {
            if ( $link_type eq 'public' && $permissions->{can_create_public} ) {
                $update->{public_visible} = $c->req->param('public_visible') ? 1 : 0;
            }
            else {
                $update->{public_visible} = 1;
            }
        }

        eval {
            $link->update($update);
            $self->clear_navigation_cache($c);
            $c->flash->{success_msg} = "Link '$name' updated successfully.";
        };
        if ($@) {
            $c->log->error("Error updating link: $@");
            $c->flash->{error_msg} = "Error updating link. Please try again.";
        }

        my $return = $is_private_link
            ? $c->uri_for('/navigation/manage_private_links')
            : $c->uri_for('/navigation/manage_links');
        $c->response->redirect($return);
        return;
    }

    my %link_data = $link->get_columns;
    $link_data{link_type}  = $self->_link_row_type(\%link_data);
    $link_data{cross_site} = ($link_data{sitename} && $link_data{sitename} eq 'All') ? 1 : 0;
    $link_data{public_visible} = defined $link_data{public_visible} ? $link_data{public_visible} : 1;

    $c->stash->{link} = \%link_data;
    $c->stash->{permissions} = $permissions;
    $c->stash->{template} = 'Navigation/edit_link.tt';
}

# Quick admin toggle for public link guest visibility.
sub toggle_link_visibility :Path('/navigation/toggle_link_visibility') :Args(0) {
    my ( $self, $c ) = @_;

    my $root_controller = $c->controller('Root');
    unless ( $root_controller->user_exists($c) && $c->session->{username} ) {
        $c->flash->{error_msg} = 'You must be logged in.';
        $c->response->redirect( $c->uri_for('/user/login') );
        return;
    }

    my $permissions = $self->get_user_link_permissions($c);
    unless ( $permissions->{can_create_public} ) {
        $c->flash->{error_msg} = 'Admin access required.';
        $c->response->redirect( $c->uri_for('/navigation/manage_private_links') );
        return;
    }

    my $link_id = $c->req->param('id');
    unless ($link_id) {
        $c->flash->{error_msg} = 'Link ID is required.';
        $c->response->redirect( $c->uri_for('/navigation/manage_links') );
        return;
    }

    my $link = eval { $c->model('DBEncy')->resultset('InternalLinksTb')->find($link_id) };
    unless ( $link && $self->user_can_edit_link( $c, $link ) ) {
        $c->flash->{error_msg} = 'Link not found or not editable.';
        $c->response->redirect( $c->uri_for('/navigation/manage_links') );
        return;
    }

    unless ( $self->_link_row_type($link) eq 'public' ) {
        $c->flash->{error_msg} = 'Only public links can be toggled for guest visibility.';
        $c->response->redirect( $c->uri_for('/navigation/manage_links') );
        return;
    }

    $self->_ensure_internal_links_public_visible_column($c);
    unless ( $self->_internal_links_has_public_visible_column($c) ) {
        $c->flash->{error_msg} = 'public_visible column is not available.';
        $c->response->redirect( $c->uri_for('/navigation/manage_links') );
        return;
    }

    my $new_val = $link->public_visible ? 0 : 1;
    eval {
        $link->update( { public_visible => $new_val } );
        $self->clear_navigation_cache($c);
        $c->flash->{success_msg}
            = sprintf( "Link '%s' is now %s.", $link->name, $new_val ? 'visible to guests' : 'hidden from guests (members only)' );
    };
    if ($@) {
        $c->flash->{error_msg} = "Toggle failed: $@";
    }

    $c->response->redirect( $c->uri_for('/navigation/manage_links') );
}

# Method to delete a link
sub delete_link :Path('/navigation/delete_link') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is logged in
    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $c->session->{username}) {
        $c->flash->{error_msg} = "You must be logged in to delete links.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    my $link_id = $c->req->param('id') || $c->req->param('link_id');
    my $username = $c->session->{username};
    
    unless ($link_id) {
        $c->flash->{error_msg} = "Link ID is required.";
        $c->response->redirect($c->uri_for('/navigation/manage_links'));
        return;
    }
    
    # Get the link and verify ownership
    my $link;
    eval {
        $link = $c->model('DBEncy')->resultset('InternalLinksTb')->find($link_id);
    };
    
    unless ($link) {
        $c->flash->{error_msg} = "Link not found.";
        $c->response->redirect($c->uri_for('/navigation/manage_links'));
        return;
    }
    
    unless ($self->user_can_edit_link($c, $link)) {
        $c->flash->{error_msg} = "You can only delete your own links.";
        $c->response->redirect($c->uri_for('/navigation/manage_links'));
        return;
    }
    
    # Delete the link
    my $link_name = $link->name;
    eval {
        $link->delete();
        $c->flash->{success_msg} = "Link '$link_name' deleted successfully.";
    };
    if ($@) {
        $c->log->error("Error deleting link: $@");
        $c->flash->{error_msg} = "Error deleting link. Please try again.";
    }
    
    $c->response->redirect($c->uri_for('/navigation/manage_links'));
}

# Method to get user's link permissions based on roles
sub get_user_link_permissions {
    my ($self, $c) = @_;
    
    my $username = $c->session->{username} || '';
    my $roles = $c->session->{roles} || [];
    my $group = $c->session->{group} || '';
    my $sitename = $c->session->{SiteName} || '';
    
    # Convert roles to array if needed
    if (!ref($roles)) {
        $roles = [$roles];
    }
    
    my $is_admin = 0;
    if (ref($roles) eq 'ARRAY') {
        $is_admin = grep { lc($_) eq 'admin' } @$roles;
    }
    
    # Also check legacy group field
    if (!$is_admin && $group && lc($group) eq 'admin') {
        $is_admin = 1;
    }
    
    my $available_sites = $self->get_available_link_sites($c);
    my $permissions = {
        can_create_private   => 1,
        can_create_public    => $is_admin ? 1 : 0,
        can_manage_all_sites => $is_admin ? 1 : 0,
        available_categories => $self->_nav_categories_for_user(
            $c, ( $c->stash->{is_admin} || $is_admin ) ? 1 : 0
        ),
        available_sites      => $available_sites,
        is_csc               => (lc($sitename || '') eq 'csc') ? 1 : 0,
        user_role            => $is_admin ? 'admin' : 'normal',
        category_labels      => { %CATEGORY_LABELS },
        menu_catalog         => \@NAV_MENU_CATALOG,
        submenu_catalog      => $self->build_submenu_catalog_for_site( $c, $sitename ),
        submenu_defaults     => { %NAV_SUBMENU_DEFAULTS },
        submenu_labels       => $self->build_submenu_labels_for_site( $c, $sitename ),
    };
    
    # Developer scaffolding (future role) - keep structure ready
    if (grep { lc($_) eq 'developer' } @$roles) {
        # For now, developer behaves like normal. When enabled later, adjust here.
        $permissions->{user_role} = $is_admin ? 'admin' : 'normal';
    }
    
    # Cross-site handling: normal users can set private links to All; admins can do both types cross-site.
    # available_sites already includes current and 'All'
    
    return $permissions;
}

# Method to validate if user can create a specific type of link
sub validate_link_permissions {
    my ($self, $c, $link_type, $category, $sitename) = @_;
    
    my $permissions = $self->get_user_link_permissions($c);
    
    # Check link type permissions
    if ($link_type eq 'private' && !$permissions->{can_create_private}) {
        return 0;
    }
    
    if ($link_type eq 'public' && !$permissions->{can_create_public}) {
        return 0;
    }
    
    # Check category permissions (private links can be added to any known category in available list)
    unless (grep { $_ eq $category } @{$permissions->{available_categories}}) {
        return 0;
    }
    
    # Check site permissions (any known site, or All for cross-site sharing)
    unless ($sitename eq 'All' || grep { $_ eq $sitename } @{$permissions->{available_sites}}) {
        return 0;
    }
    
    return 1;
}

# Method to get maximum link order for a category
sub get_max_link_order {
    my ($self, $c, $category, $sitename, $username, $link_type) = @_;
    
    my $search_criteria = {
        category => $category,
        sitename => $sitename
    };
    
    # For private links, filter by username
    if ($link_type eq 'private') {
        $search_criteria->{description} = $username;
    }
    
    my $max_order = 0;
    eval {
        my $rs = $c->model('DBEncy')->resultset('InternalLinksTb')->search(
            $search_criteria,
            {
                select => [{ max => 'link_order' }],
                as => ['max_order']
            }
        );
        
        my $row = $rs->first;
        $max_order = $row ? ($row->get_column('max_order') || 0) : 0;
    };
    
    return $max_order;
}

sub _dedupe_manageable_links {
    my ($self, $links) = @_;
    my %seen_id;
    my %seen_key;
    my @out;
    for my $link (@$links) {
        next unless ref($link) eq 'HASH';
        my $id = $link->{id};
        if (defined $id && $id ne '') {
            next if $seen_id{$id}++;
        }
        my $key = join '|',
            map { lc($_ // '') }
            qw(name url category sitename description);
        next if $seen_key{$key}++;
        $seen_key{$key} = 1;
        push @out, $link;
    }
    return \@out;
}

# Method to get all links that user can manage
sub get_user_manageable_links {
    my ($self, $c, $username, $permissions) = @_;
    
    my @all_links = ();
    my $site_name = $c->session->{SiteName} || $self->_current_site($c);
    
    # All private links the user owns (any site scope — manage page must list everything)
    if ($permissions->{can_create_private}) {
        my $private_links = $self->get_all_private_links_for_user($c, $username);
        for my $link (@$private_links) {
            $link->{link_type} = 'private';
            $link->{manageable} = 1;
        }
        push @all_links, @$private_links;
    }
    
    # Public links: one pass per category (not per site — avoids duplicate rows for sitename=All)
    if ($permissions->{can_create_public}) {
        my @public_cats = @{ $permissions->{available_categories} };
        push @public_cats, 'Hosted_link' unless grep { $_ eq 'Hosted_link' } @public_cats;
        for my $category (@public_cats) {
            next if $category eq 'Private_links';
            
            my $public_links = $self->get_internal_links(
                $c, $category, $site_name, { include_hidden => 1 }
            );
            for my $link (@$public_links) {
                $link->{link_type} = 'public';
                $link->{manageable} = 1;
                $link->{category_display} = $category;
                $link->{public_visible} = defined $link->{public_visible} ? $link->{public_visible} : 1;
            }
            push @all_links, @$public_links;
        }
    }
    
    return $self->_dedupe_manageable_links(\@all_links);
}

# Method to populate navigation data in the stash with caching
sub populate_navigation_data {
    my ($self, $c) = @_;
    
    # === NAVIGATION SYSTEM TOGGLE ===
    # Set USE_NEW_NAVIGATION=1 (or true) in environment to use the new hybrid system.
    # Default (unset / 0 / false) → fall back to the old reliable navigation.
    my $use_new_nav = $ENV{USE_NEW_NAVIGATION} || 0;
    return unless $use_new_nav;

    # Use eval to catch any errors
    eval {
        my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || 'default';
        my $username = $c->session->{username} || '';
        $self->_ensure_nav_submenu_table($c);
        
        # Create cache key based on site and user
        my $cache_key = "${site_name}_${username}";
        my $current_time = time();
        my $cache_ttl = 300; # 5 minutes cache
        my $max_cache_age = 3600; # 1 hour max for the whole cache structure
        
        # Periodically clear the entire cache to prevent indefinite growth
        if (($current_time - $self->_cache_timestamp) > $max_cache_age) {
            $c->log->debug("Navigation cache exceeded max age, clearing all entries");
            $self->_navigation_cache({});
        }
        
        # Check if we have valid cached data
        if ($self->_navigation_cache->{$cache_key} && 
            ($current_time - $self->_cache_timestamp) < $cache_ttl) {
            
            # Use cached data (visibility flags always recomputed — cheap and schema-independent)
            my $cached_data = $self->_navigation_cache->{$cache_key};
            $c->stash->{$_} = $cached_data->{$_} for keys %$cached_data;
            $c->stash->{show_hosted_nav} = $self->hosted_nav_visible($c);
            my $sn_lc = lc( $c->stash->{SiteName} || $c->session->{SiteName} || '' );
            $c->stash->{show_features_nav} = ( $sn_lc eq 'csc' ) ? 1 : 0;
            $c->log->debug("Using cached navigation data for site: $site_name");
            return;
        }
        
        $c->log->debug("Populating fresh navigation data for site: $site_name");
        
        # Set is_admin flag based on user roles
        my $is_admin = 0;
        my $root_controller = $c->controller('Root');
        if ($root_controller->user_exists($c) && $c->session->{roles}) {
            if (ref($c->session->{roles}) eq 'ARRAY') {
                $is_admin = grep { lc($_) eq 'admin' } @{$c->session->{roles}};
            } elsif (!ref($c->session->{roles})) {
                $is_admin = ($c->session->{roles} =~ /\badmin\b/i) ? 1 : 0;
            }
        }
        
        # Also check the legacy group field
        if (!$is_admin && $c->session->{group} && lc($c->session->{group}) eq 'admin') {
            $is_admin = 1;
        }
        
        # Set the is_admin flag in stash for use in templates
        $c->stash->{is_admin} = $is_admin;
        
        # Only check tables once per application lifecycle
        if (!$self->_tables_checked) {
            $self->_ensure_navigation_tables_exist($c);
            $self->_ensure_internal_links_public_visible_column($c);
            $self->_ensure_hosting_list_publicly_column($c);
            $self->_tables_checked(1);
        }

        # NEW menu system tables (CSC stock + site overrides) – ensure + seed on first use
        $self->_ensure_menu_stock_tables($c);
        
        # Prepare data structure for caching
        my $nav_data = {
            is_admin => $is_admin
        };
        
        # Merged public + user-private links per menu category (for themed dropdown partials)
        my %nav_merged_links;
        for my $cat (@MENU_LINK_CATEGORIES) {
            next if $cat eq 'Admin_links' && !$is_admin;
            $nav_merged_links{$cat} = $self->get_merged_menu_links($c, $cat, $site_name);
        }
        $nav_data->{nav_merged_links} = \%nav_merged_links;

        # NEW: CSC stock catalog + basic effective site menu items (Phase 1 foundation)
        # Full context/page/gating/merge with customs + drag order in later phases + editor.
        eval {
            $nav_data->{csc_stock_catalog} = $self->get_csc_stock_catalog($c);
            $nav_data->{csc_stock_by_category} = {};
            for my $cat (@MENU_LINK_CATEGORIES, 'Custom_top') {
                $nav_data->{csc_stock_by_category}{$cat} = $self->get_csc_stock_catalog($c, $cat);
            }
            # Effective (stock + site overrides) for key menus – available in stash for debug/editor
            $nav_data->{effective_menu_items} = {
                Main_links   => $self->get_effective_stock_items_for_category($c, 'Main_links', $site_name),
                HelpDesk_links => $self->get_effective_stock_items_for_category($c, 'HelpDesk_links', $site_name),
                Admin_links  => $is_admin ? $self->get_effective_stock_items_for_category($c, 'Admin_links', $site_name) : [],
            };
        };
        if ($@) {
            $c->log->error("Phase1 menu_stock stash failed (non-fatal): $@");
            $nav_data->{csc_stock_catalog} = [];
            $nav_data->{effective_menu_items} = {};
        }

        # Legacy stash keys (public-only internal links)
        $nav_data->{member_links} = $nav_merged_links{Member_links} // $self->get_internal_links($c, 'Member_links', $site_name);
        $nav_data->{member_pages} = $self->get_pages($c, 'member', $site_name);
        $nav_data->{main_links}   = $nav_merged_links{Main_links}   // $self->get_internal_links($c, 'Main_links', $site_name);
        $nav_data->{main_pages}   = $self->get_pages($c, 'Main', $site_name);
        $nav_data->{hosted_links} = $self->get_merged_hosted_menu_links( $c, $site_name );
        my $hosted_merged = $nav_data->{hosted_links} || [];
        $nav_data->{hosted_custom_links} = $self->filter_menu_links_by_submenu(
            $hosted_merged, 'hosted_links', 'hosted_links', $c, $site_name
        );
        $nav_data->{hosted_pages_user_links} = $self->filter_menu_links_by_submenu(
            $hosted_merged, 'hosted_pages', 'hosted_links', $c, $site_name
        );
        $nav_data->{hosted_top_links} = $self->filter_menu_links_by_submenu(
            $hosted_merged, 'top', 'hosted_links', $c, $site_name
        );
        $nav_data->{hosted_sites_merged}   = $self->get_merged_hosted_sites_for_nav($c);
        $nav_data->{hosted_resource_links} = $self->merge_hosted_resource_links($hosted_merged);
        $nav_data->{show_hosted_nav}       = $self->hosted_nav_visible($c);
        my $feat_sn_lc = lc( $c->stash->{SiteName} || $c->session->{SiteName} || '' );
        $nav_data->{show_features_nav}     = ( $feat_sn_lc eq 'csc' ) ? 1 : 0;

        if ($is_admin) {
            my $admin_merged = $nav_merged_links{Admin_links}
                // $self->get_merged_menu_links( $c, 'Admin_links', $site_name );
            $nav_data->{admin_pages} = $self->get_admin_pages($c, $site_name);
            $nav_data->{admin_links} = $admin_merged;
            $nav_data->{admin_submenu_links} = $self->filter_menu_links_by_submenu(
                $admin_merged, 'admin_links', 'admin_links', $c, $site_name
            );
            $nav_data->{admin_top_links} = $self->filter_menu_links_by_submenus(
                $admin_merged, [qw(top cms_pages)], $c, $site_name
            );
            $nav_data->{admin_links_by_submenu} = $self->group_menu_links_by_submenu(
                $admin_merged, 'Admin_links', $c, $site_name
            );
            $nav_data->{admin_custom_submenu_sections}
                = $self->get_custom_submenu_sections( $c, 'Admin_links', $site_name );
        }

        # All private links for user dropdown and per-menu private rows (any site scope)
        if ($root_controller->user_exists($c) && $username) {
            my $private = $self->get_all_private_links_for_user( $c, $username );
            for my $l (@$private) {
                $l->{link_type} = 'private';
                $l->{owner}     = $username;
                $l->{can_edit}  = 1;
            }
            $nav_data->{private_links} = $private;
            if ($is_admin) {
                $nav_data->{admin_private_links} = [
                    grep { ( $_->{category} // '' ) eq 'Admin_links' } @$private
                ];
            }
        }
        
        # Cap cache size to prevent unbounded memory growth (max 50 entries)
        if (scalar(keys %{$self->_navigation_cache}) >= 50) {
            $self->_navigation_cache({});
        }
        # Cache the data
        $self->_navigation_cache->{$cache_key} = $nav_data;
        $self->_cache_timestamp($current_time);
        
        # Set stash data
        $c->stash->{$_} = $nav_data->{$_} for keys %$nav_data;
        
        $c->log->debug("Navigation data populated and cached successfully");
    };
    if ($@) {
        $c->log->error("Error populating navigation data: $@");
    }
}

# Separate method for table existence checking (called only once)
sub _ensure_navigation_tables_exist {
    my ($self, $c) = @_;
    
    eval {
        # Ensure tables exist before querying them
        my $db_model = $c->model('DBEncy');
        my $schema = $db_model->schema;
        
        # Check if tables exist in the database
        my $dbh = $schema->storage->dbh;
        my $tables = $db_model->list_tables();
        my $internal_links_exists = grep { $_ eq 'internal_links_tb' } @$tables;
        my $navigation_exists = grep { $_ eq 'navigation' } @$tables;

        if ($internal_links_exists) {
            $self->_ensure_internal_links_submenu_column($c);
        }

        if (!$internal_links_exists) {
            $c->log->debug("internal_links_tb table doesn't exist. Attempting to create it.");
            $db_model->create_table_from_result('InternalLinksTb', $schema, $c);

            $tables = $db_model->list_tables();
            $internal_links_exists = grep { $_ eq 'internal_links_tb' } @$tables;

            if (!$internal_links_exists) {
                my $sql_file = $c->path_to('sql', 'internal_links_tb.sql')->stringify;
                if (-e $sql_file) {
                    my $sql = do { local (@ARGV, $/) = $sql_file; <> };
                    foreach my $statement (split /;/, $sql) {
                        $statement =~ s/^\s+|\s+$//g;
                        next unless $statement;
                        eval { $dbh->do($statement); };
                        $c->log->error("Error executing SQL: $@") if $@;
                    }
                } else {
                    $c->log->error("SQL file not found: $sql_file");
                }
            }
        }
        
        # Check and run migration for navigation table if it exists but lacks is_private column
        if ($navigation_exists) {
            my $has_is_private = $self->column_exists($c, 'navigation', 'is_private');
            if (!$has_is_private) {
                $c->log->info("Running migration to add is_private column to navigation table");
                $self->run_navigation_migration($c);
            }
        }
    };
    if ($@) {
        $c->log->error("Error ensuring navigation tables exist: $@");
    }
}

# Method to get navigation items filtered by privacy settings
sub get_navigation_items {
    my ($self, $c, $menu_name, $user_logged_in) = @_;
    
    $c->log->debug("Getting navigation items for menu: $menu_name, user_logged_in: " . ($user_logged_in ? 'yes' : 'no'));
    
    my @results;
    
    eval {
        # Get navigation items from the new navigation table
        my $rs = $c->model('DBEncy')->resultset('Navigation')->search(
            { 
                menu => $menu_name,
                -or => [
                    { is_private => 0 },                    # Public items always shown
                    { is_private => 1, -and => $user_logged_in ? () : ('0=1') } # Private items only if logged in
                ]
            },
            { 
                order_by => [
                    { -asc => 'parent_id' },    # Top-level items first (parent_id is null)
                    { -asc => 'order' }         # Then by order within same level
                ],
                prefetch => ['page', 'parent', 'children']
            }
        );
        
        while (my $nav_item = $rs->next) {
            my $item_data = {
                id          => $nav_item->id,
                page_id     => $nav_item->page_id,
                menu        => $nav_item->menu,
                parent_id   => $nav_item->parent_id,
                order       => $nav_item->order,
                is_private  => $nav_item->is_private,
            };
            
            # Include page data if available
            if ($nav_item->page) {
                $item_data->{page} = {
                    id          => $nav_item->page->id,
                    name        => $nav_item->page->name,
                    url         => $nav_item->page->url,
                    target      => $nav_item->page->target,
                    description => $nav_item->page->description,
                    status      => $nav_item->page->status,
                };
            }
            
            push @results, $item_data;
        }
        
        $c->log->debug("Found " . scalar(@results) . " navigation items");
    };
    if ($@) {
        $c->log->error("Error getting navigation items: $@");
    }
    
    return \@results;
}

# Method to get hierarchical navigation structure
sub get_navigation_tree {
    my ($self, $c, $menu_name, $user_logged_in) = @_;
    
    my $items = $self->get_navigation_items($c, $menu_name, $user_logged_in);
    
    # Build hierarchical structure
    my %item_lookup = map { $_->{id} => $_ } @$items;
    my @tree = ();
    
    foreach my $item (@$items) {
        if (defined $item->{parent_id} && exists $item_lookup{$item->{parent_id}}) {
            # Add as child to parent
            $item_lookup{$item->{parent_id}}->{children} ||= [];
            push @{$item_lookup{$item->{parent_id}}->{children}}, $item;
        } else {
            # Top-level item
            push @tree, $item;
        }
    }
    
    return \@tree;
}

# Helper method to check if a column exists in a table
sub column_exists {
    my ($self, $c, $table_name, $column_name) = @_;
    
    my $exists = 0;
    eval {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        my $sth = $dbh->prepare("SHOW COLUMNS FROM `$table_name` LIKE ?");
        $sth->execute($column_name);
        my $result = $sth->fetchrow_arrayref();
        $exists = $result ? 1 : 0;
    };
    if ($@) {
        $c->log->error("Error checking if column exists: $@");
        return 0;
    }
    return $exists;
}

# Method to run the navigation table migration
sub run_navigation_migration {
    my ($self, $c) = @_;
    
    eval {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        
        # Add is_private column
        $dbh->do("ALTER TABLE `navigation` ADD COLUMN `is_private` TINYINT(1) NOT NULL DEFAULT 0 COMMENT 'Flag to mark navigation items as private (1) or public (0)'");
        
        # Create indexes for better performance
        $dbh->do("CREATE INDEX `idx_navigation_privacy` ON `navigation` (`is_private`)");
        $dbh->do("CREATE INDEX `idx_navigation_menu_privacy` ON `navigation` (`menu`, `is_private`)");
        
        # Update table comment
        $dbh->do("ALTER TABLE `navigation` COMMENT = 'Navigation structure with hierarchical support and public/private visibility'");
        
        $c->log->info("Successfully ran navigation migration - added is_private column");
    };
    if ($@) {
        $c->log->error("Error running navigation migration: $@");
    }
}

# Method to add a navigation item (Admin interface)
sub add_navigation_item :Path('/navigation/add') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is admin
    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $c->session->{roles} && 
            (grep { $_ eq 'admin' } @{$c->session->{roles}})) {
        $c->flash->{error_msg} = "Administrative privileges required.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    if ($c->req->method eq 'POST') {
        my $page_id = $c->req->param('page_id');
        my $menu = $c->req->param('menu');
        my $parent_id = $c->req->param('parent_id') || undef;
        my $order = $c->req->param('order') || 0;
        my $is_private = $c->req->param('is_private') ? 1 : 0;
        
        # Validate required fields
        unless ($page_id && $menu) {
            $c->flash->{error_msg} = "Page ID and Menu are required fields.";
            $c->stash->{template} = 'Navigation/add.tt';
            return;
        }
        
        # Add the navigation item
        eval {
            $c->model('DBEncy')->resultset('Navigation')->create({
                page_id => $page_id,
                menu => $menu,
                parent_id => $parent_id,
                order => $order,
                is_private => $is_private,
            });
            $c->flash->{success_msg} = "Navigation item added successfully.";
            $self->clear_navigation_cache($c);
            $c->response->redirect($c->uri_for('/navigation/manage'));
            return;
        };
        if ($@) {
            $c->log->error("Error adding navigation item: $@");
            $c->flash->{error_msg} = "Error adding navigation item: $@";
        }
    }
    
    # Load pages for dropdown
    $c->stash->{pages} = [$c->model('DBEncy')->resultset('Page')->search({
        status => 'active',
    }, { order_by => 'title' })->all];
    $c->stash->{template} = 'Navigation/add.tt';
}

# Method to manage navigation items (Admin interface)
sub manage :Path('/navigation/manage') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is admin
    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $c->session->{roles} && 
            (grep { $_ eq 'admin' } @{$c->session->{roles}})) {
        $c->flash->{error_msg} = "Administrative privileges required.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    # Get all navigation items
    my @navigation_items = $c->model('DBEncy')->resultset('Navigation')->search({}, {
        order_by => ['me.menu', 'me.parent_id', 'me.order'],
        prefetch => 'page'
    })->all;
    
    $c->stash->{navigation_items} = \@navigation_items;
    $c->stash->{template} = 'Navigation/manage.tt';
}

sub _role_rank {
    my ($self, $role) = @_;
    my %r = ( guest => 0, user => 1, admin => 2 );
    return $r{lc($role // 'guest')} // 0;
}

sub _decode_trigger_phrases {
    my ($self, $raw) = @_;
    return [] unless defined $raw && $raw ne '';
    eval {
        my $decoded = decode_json($raw);
        return ref($decoded) eq 'ARRAY' ? $decoded : [$decoded];
    };
    return [ split /\s*,\s*/, $raw ] if $@;
    return [];
}

# AI navigation shortcuts visible to current user/site/role
# Lightweight DB-driven menu builder for use_db_menu=1 path
sub _get_db_menu {
    my ($self, $c) = @_;
    my $site = $self->_current_site($c);
    
    my @items = $c->model('DBEncy')->resultset('NavSubmenuTb')->search({
        sitename => $site,
        status   => 1,
    }, { order_by => ['section_order', 'label'] })->all;
    
    my @menu;
    for my $row (@items) {
        my $item = { label => $row->label, url => $row->header_url || '#', icon => $row->icon };
        my @children = $c->model('DBEncy')->resultset('NavSubmenuTb')->search({
            sitename   => $site,
            status     => 1,
            category   => $row->category,
            submenu_id => { '!=' => '' },
        }, { order_by => ['section_order', 'label'] })->all;
        
        $item->{children} = [ map {{ label => $_->label, url => $_->header_url || '#' }} @children ] if @children;
        push @menu, $item;
    }
    return \@menu;
}

# Runtime toggle for admin users (legacy <-> db)
sub toggle_menu_mode :Path('/navigation/toggle_menu_mode') :Args(0) {
    my ($self, $c) = @_;
    unless ($c->session->{is_admin} || $c->stash->{is_admin}) {
        $c->response->redirect('/');
        return;
    }
    my $mode = $c->req->param('mode') || 'legacy';
    if ($mode eq 'db') {
        $c->session->{use_db_menu} = 1;
    } else {
        $c->session->{use_db_menu} = 0;
    }
    my $ref = $c->req->referer || '/'; $c->response->redirect($ref);
}
sub get_ai_navigation_shortcuts {
    my ($self, $c, $role_tier, $site_name, $max) = @_;
    $max //= 50;
    $role_tier //= 'guest';
    $site_name //= $self->_current_site($c);

    my $username = $c->session->{username} || '';
    my $user_rank = $self->_role_rank($role_tier);
    my @out;

    eval {
        my $rs = $c->model('DBEncy')->resultset('AiNavigationShortcut')->search(
            {
                status   => 1,
                sitename => [ $site_name, 'All' ],
            },
            { order_by => [ { -asc => 'link_order' }, { -asc => 'label' } ], rows => $max * 2 }
        );

        while (my $row = $rs->next) {
            next if $self->_role_rank($row->min_role) > $user_rank;
            if ($row->is_private) {
                next unless $username && $row->owner_username && $row->owner_username eq $username;
            }
            push @out, {
                id              => $row->id,
                label           => $row->label,
                url             => $row->url,
                category        => $row->category,
                sitename        => $row->sitename,
                is_private      => $row->is_private,
                owner_username  => $row->owner_username,
                min_role        => $row->min_role,
                trigger_phrases => $self->_decode_trigger_phrases($row->trigger_phrases),
            };
            last if @out >= $max;
        }
    };
    if ($@) {
        $c->log->error("Error loading AI navigation shortcuts: $@");
    }

    return \@out;
}

# Match a user phrase against shortcuts (for "open my X account")
sub find_ai_shortcut_for_phrase {
    my ($self, $c, $phrase, $role_tier) = @_;
    return unless $phrase && $c;

    my $norm = lc($phrase);
    $norm =~ s/^\s+|\s+$//g;
    $norm =~ s/^(?:open|go to|take me to|navigate to|show)\s+(?:my\s+)?//;
    $norm =~ s/\s+(?:account|page|site|link)$//;
    return unless length($norm) >= 2;

    my $shortcuts = $self->get_ai_navigation_shortcuts($c, $role_tier);
    for my $sc (@$shortcuts) {
        if (lc($sc->{label}) eq $norm) {
            return $sc;
        }
        for my $tr (@{ $sc->{trigger_phrases} || [] }) {
            my $t = lc($tr);
            $t =~ s/^\s+|\s+$//g;
            next unless length($t) >= 2;
            return $sc if $norm eq $t || index($norm, $t) >= 0 || index($t, $norm) >= 0;
        }
    }
    return;
}

# Format shortcuts for AI system prompt
sub build_ai_shortcut_navigation_section {
    my ($self, $c, $role_tier, $base_url) = @_;
    $base_url =~ s/\/$// if $base_url;
    my $shortcuts = $self->get_ai_navigation_shortcuts($c, $role_tier);
    return '' unless $shortcuts && @$shortcuts;

    my $out = "\nSaved navigation shortcuts (DB — prefer for \"open my X\" requests):\n";
    for my $sc (@$shortcuts) {
        my $url = $sc->{url};
        $url = "$base_url$url" if $url =~ m{^/};
        my $scope = $sc->{is_private} ? 'private' : 'public';
        $out .= "  - $sc->{label} ($scope): $url";
        if ($sc->{trigger_phrases} && @{ $sc->{trigger_phrases } }) {
            $out .= ' [triggers: ' . join(', ', @{ $sc->{trigger_phrases } }) . ']';
        }
        $out .= "\n";
    }
    return $out;
}

# User/site links from internal_links_tb for AI nav guide
sub build_internal_links_navigation_section {
    my ($self, $c, $role_tier, $base_url) = @_;
    $base_url =~ s/\/$// if $base_url;
    return '' unless $c->session->{username};

    my $site = $self->_current_site($c);
    my $username = $c->session->{username};
    my @lines;

    for my $cat (@MENU_LINK_CATEGORIES) {
        next if $cat eq 'Admin_links' && $self->_role_rank($role_tier) < 2;
        my $links = $self->get_merged_menu_links($c, $cat, $site);
        for my $lnk (@$links) {
            my $url = $lnk->{url};
            $url = "$base_url$url" if $url =~ m{^/};
            my $type = $lnk->{link_type} eq 'private' ? 'my private' : 'site';
            push @lines, "  - [$cat] $lnk->{name} ($type): $url";
        }
    }

    return '' unless @lines;
    return "\nUser and site menu links (from navigation database):\n" . join("\n", @lines) . "\n";
}

# Save or update an AI navigation shortcut (JSON API)
sub save_ai_shortcut :Path('/navigation/save_ai_shortcut') :Args(0) {
    my ($self, $c) = @_;

    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $c->session->{username}) {
        $c->response->status(401);
        $c->stash->{json} = { success => 0, error => 'Login required' };
        $c->forward('View::JSON');
        return;
    }

    my $username = $c->session->{username};
    my $body     = eval { $c->request->body_data } // {};
    $body = {} unless ref($body) eq 'HASH';

    my $label        = $c->req->param('label')        || $body->{label};
    my $url          = $c->req->param('url')          || $body->{url};
    my $phrases_raw  = $c->req->param('trigger_phrases') || $body->{trigger_phrases};
    my $category     = $c->req->param('category')     || $body->{category};
    my $cross_site   = $c->req->param('cross_site')   || $body->{cross_site};
    my $is_private   = defined $c->req->param('is_private') ? $c->req->param('is_private') : ($body->{is_private} // 1);
    my $sitename     = $cross_site ? 'All' : ($c->req->param('sitename') || $body->{sitename} || $self->_current_site($c));
    my $shortcut_id  = $c->req->param('id') || $body->{id};

    unless ($label && $url) {
        $c->response->status(400);
        $c->stash->{json} = { success => 0, error => 'label and url are required' };
        $c->forward('View::JSON');
        return;
    }

    my @phrases;
    if (defined $phrases_raw) {
        if (ref($phrases_raw) eq 'ARRAY') {
            @phrases = @$phrases_raw;
        } else {
            @phrases = split /\s*,\s*/, $phrases_raw;
        }
    }
    push @phrases, "open my $label" unless grep { lc($_) eq "open my " . lc($label) } @phrases;

    my $is_admin = $c->stash->{is_admin} ? 1 : 0;
    unless ($is_admin) {
        my $roles = $c->session->{roles} || [];
        $roles = [$roles] unless ref($roles) eq 'ARRAY';
        $is_admin = grep { lc($_) eq 'admin' } @$roles ? 1 : 0;
    }
    # Non-admins may only create private shortcuts; admins may create public site shortcuts
    $is_private = $is_admin ? ($is_private ? 1 : 0) : 1;

    my $data = {
        label           => $label,
        url             => $url,
        trigger_phrases => encode_json(\@phrases),
        category        => $category,
        sitename        => $sitename,
        is_private      => $is_private ? 1 : 0,
        owner_username  => $is_private ? $username : undef,
        min_role        => 'user',
        status          => 1,
        source          => 'manual',
    };

    eval {
        if ($shortcut_id) {
            my $row = $c->model('DBEncy')->resultset('AiNavigationShortcut')->find($shortcut_id);
            die 'Shortcut not found' unless $row;
            if ($row->is_private && $row->owner_username ne $username && !$is_admin) {
                die 'Not allowed';
            }
            $row->update($data);
            $c->stash->{json} = { success => 1, id => $row->id, message => 'Shortcut updated' };
        } else {
            my $row = $c->model('DBEncy')->resultset('AiNavigationShortcut')->create($data);
            $c->stash->{json} = { success => 1, id => $row->id, message => 'Shortcut saved' };
        }
    };
    if ($@) {
        $c->response->status(500);
        $c->stash->{json} = { success => 0, error => "$@" };
    }

    $c->forward('View::JSON');
}

sub _nav_source_priority {
    my ( $self, $source ) = @_;
    my %p = (
        private_link    => 100,
        menu_link       => 95,
        shortcut        => 90,
        core_route      => 88,
        site_local      => 75,
        site_production => 70,
        site_module     => 70,
        hosting_account => 60,
        learned_link    => 55,
        site_domain     => 40,
    );
    return $p{ $source // '' } // 0;
}

# Role-gated app routes indexed for chat nav (no manual JS/AI.pm edits per link).
# Each: [ label, path, min_role, optional alias phrases... ]
our @CORE_ROLE_NAV_ROUTES = (
    [ 'opnsense gateway', '/admin/infrastructure/opnsense', 'admin',
      qw(opnsense opn sense opn-sense opnsense gateway opnsense dashboard gateway management opsence opnsence) ],
    [ 'infrastructure', '/admin/infrastructure', 'admin', qw(infrastructure infra) ],
    [ 'application dns', '/admin/dns', 'admin', qw(dns dns zones application dns) ],
    [ 'gateway plan', '/Documentation/system/GatewayPlan', 'admin', qw(gateway plan routing plan) ],
    [ 'admin panel', '/admin', 'admin', qw(admin admin dashboard) ],
    [ 'projects', '/project', 'user', qw(projects project list) ],
    [ 'todo list', '/todo', 'user', qw(todos todo list) ],
    [ 'helpdesk', '/HelpDesk', 'guest', qw(helpdesk help desk support) ],
    [ 'documentation', '/Documentation', 'guest', qw(documentation docs) ],
    [ 'ai chat', '/ai', 'guest', qw(ai ai chat assistant) ],
    [ 'preview upcoming changes', '/admin/dev-preview', 'admin',
      qw(dev preview preview upcoming changes upcoming changes dev preview preview changes preview site) ],
);

sub _nav_path_admin_only {
    my ( $self, $path ) = @_;
    return 0 unless defined $path && length $path;
    return 1 if $path =~ m{^/admin(?:/|$)}i;
    return 1 if $path =~ m{^/file/}i;
    return 1 if $path =~ m{^/site(?:/|$)}i;
    return 1 if $path =~ m{^/themeadmin}i;
    return 1 if $path =~ m{^/log$}i;
    return 1 if $path =~ m{^/chat/admin}i;
    return 1 if $path =~ m{^/ai/models}i;
    return 1 if $path =~ m{^/navigation/manage_links}i;
    return 0;
}

sub _viewer_role_tier {
    my ( $self, $c ) = @_;
    return 'admin' if $c->stash->{is_admin};
    return $c->session->{username} ? 'user' : 'guest';
}

sub _edit_distance {
    my ( $self, $a, $b ) = @_;
    $a //= '';
    $b //= '';
    return length($b) if !length($a);
    return length($a) if !length($b);
    return 0 if $a eq $b;
    my @prev = 0 .. length($b);
    for my $i ( 0 .. length($a) - 1 ) {
        my @curr = ( $i + 1 );
        for my $j ( 0 .. length($b) - 1 ) {
            my $cost = substr( $a, $i, 1 ) eq substr( $b, $j, 1 ) ? 0 : 1;
            push @curr, min( $curr[$j] + 1, $prev[ $j + 1 ] + 1, $prev[$j] + $cost );
        }
        @prev = @curr;
    }
    return $prev[-1];
}

sub _phrase_looks_like_opnsense {
    my ( $self, $phrase ) = @_;
    return 0 unless defined $phrase && $phrase ne '';
    my $compact = lc($phrase);
    $compact =~ s/[^a-z]//g;
    return 0 unless length($compact) >= 4;
    return 1 if $compact =~ /opnsense|opsense|opsence|opnsence|opense|opensense/;
    return 1 if $compact =~ /^opn/ && $compact =~ /(?:sense|sence)$/;
    return 0;
}

sub _register_core_role_nav_routes {
    my ( $self, $c, $add, $role ) = @_;
    my $user_rank = $self->_role_rank($role);
    for my $row (@CORE_ROLE_NAV_ROUTES) {
        my ( $label, $path, $min_role, @aliases ) = @$row;
        next if $self->_role_rank( $min_role // 'guest' ) > $user_rank;
        next if $user_rank < 2 && $self->_nav_path_admin_only($path);
        $self->_register_chat_nav_link(
            $add, $label, $path, '_self', 'core_route', 1, $label
        );
        for my $alias (@aliases) {
            $self->_register_chat_nav_link(
                $add, $alias, $path, '_self', 'core_route', 0, $label
            );
        }
    }
}

sub _register_learned_chat_nav_links {
    my ( $self, $c, $add, $role ) = @_;
    my $user_rank = $self->_role_rank($role);
    eval {
        my $schema = $c->model('DBEncy')->schema;
        return unless $schema;
        my @rows = $schema->resultset('LearnedData')->search(
            { file => 'ai_discovered_link', word => { like => 'ai_link:%' } },
            { order_by => { -desc => 'frequency' }, rows => 50 }
        )->all;
        for my $r (@rows) {
            my $w = $r->word || '';
            $w =~ s/^ai_link://;
            next unless $w =~ m{^/};
            next if $user_rank < 2 && $self->_nav_path_admin_only($w);
            my $label = $w;
            $label =~ s{.*/}{};
            $label =~ s/[_?.-]+/ /g;
            $label =~ s/\s+/ /g;
            $label =~ s/^\s+|\s+$//g;
            next unless length($label) >= 2;
            $self->_register_chat_nav_link(
                $add, $label, $w, '_self', 'learned_link', 1, $label
            );
        }
    };
    if ($@) {
        $c->log->error("Error loading learned chat nav links: $@");
    }
}

sub _nav_link_host_key {
    my ( $self, $url ) = @_;
    return '' unless defined $url && $url ne '';
    if ( $url =~ m{^https?://([^/?#]+)}i ) {
        my $h = lc($1);
        $h =~ s/^www\.//;
        return $h;
    }
    if ( $url =~ m{^/([^/?#]+)} ) {
        return 'path:' . lc($1);
    }
    return lc($url);
}

# Full destination key (host + port) — http/https duplicates collapse; .local:3000 ≠ ve7tit.com
sub _nav_link_destination_key {
    my ( $self, $url ) = @_;
    return '' unless defined $url && $url ne '';
    if ( $url =~ m{^https?://([^/?#]+)}i ) {
        return lc($1);
    }
    return lc($url);
}

sub _default_local_site_port {
    my ( $self, $c, $site_row ) = @_;
    if ( $site_row && $site_row->can('document_root_url') ) {
        my $u = $site_row->document_root_url;
        if ( defined $u && $u =~ m{^https?://[^/]+:(\d+)}i ) {
            return $1;
        }
    }
    return 3001;
}

sub _normalize_hosting_nav_url {
    my ( $self, $c, $domain, $site_row ) = @_;
    return undef unless $domain;
    my $d = $domain;
    $d =~ s{^https?://}{}i;
    $d =~ s{/.*}{};
    return undef unless $d;
    if ( $d =~ /\.local$/i ) {
        return undef unless $c;
        if ( $d =~ /^([^:]+):(\d+)$/ ) {
            return "http://$1:$2";
        }
        my $port = $self->_default_local_site_port( $c, $site_row );
        return "http://$d:$port";
    }
    $d =~ s/^www\.//i;
    return "https://$d";
}

sub _site_domain_rows {
    my ( $self, $c, $site_row ) = @_;
    return [] unless $site_row && $site_row->can('id') && $site_row->id;
    return [
        $c->model('DBEncy')->resultset('SiteDomain')->search(
            { site_id => $site_row->id },
            { order_by => 'domain' }
        )->all
    ];
}

sub _site_local_nav_url {
    my ( $self, $c, $site_row ) = @_;
    for my $sd ( @{ $self->_site_domain_rows( $c, $site_row ) } ) {
        my $d = $sd->domain;
        next unless $d && $d =~ /\.local$/i;
        next if $d =~ /workstation\.local/i;
        return $self->_normalize_hosting_nav_url( $c, $d, $site_row );
    }
    return undef;
}

sub _site_production_nav_url {
    my ( $self, $c, $site_row ) = @_;
    for my $sd ( @{ $self->_site_domain_rows( $c, $site_row ) } ) {
        my $d = $sd->domain;
        next unless $d && $d !~ /\.local$/i;
        next if $d =~ /workstation\.local/i;
        return $self->_normalize_hosting_nav_url( $c, $d, $site_row );
    }
    return undef;
}

sub _find_site_row_by_name {
    my ( $self, $c, $site_name ) = @_;
    return undef unless $site_name;
    return eval {
        $c->model('DBEncy')->resultset('Site')->search(
            \[ 'LOWER(name) = ?', lc($site_name) ]
        )->first;
    };
}

sub _chat_nav_link_score {
    my ( $self, $c, $link, $phrase ) = @_;
    my $url = $link->{url} // '';
    my $score = $self->_nav_source_priority( $link->{source} );
    $score += 40 if $phrase && lc( $link->{name} // '' ) eq lc($phrase);
    $score += 35 if $phrase && ( $link->{label} // '' ) eq lc($phrase);
    $score += 45 if $url =~ /\.local:\d+/i;
    $score -= 40 if $url =~ /\.local$/i && $url !~ /:\d+/;
    $score += 10 if $url =~ m{^https://}i && $url !~ /\.local/i;
    $score -= 80 if $url =~ /workstation\.local/i;
    $score -= 60 if $url !~ m{^https?://}i;
    return $score;
}

# Drop http/https duplicates only — keep ve7tit.local:3000 and ve7tit.com separate
sub _dedupe_chat_nav_destinations {
    my ( $self, $c, $links, $phrase ) = @_;
    my %best;
    for my $l (@$links) {
        my $url = $l->{url} // '';
        next if $url =~ /\.local$/i && $url !~ /:\d+/;
        my $key = $self->_nav_link_destination_key($url);
        next unless $key;
        my $score = $self->_chat_nav_link_score( $c, $l, $phrase );
        if ( !$best{$key} || $score > $best{$key}{score} ) {
            $best{$key} = { link => $l, score => $score };
        }
    }
    return [ map { $_->{link} } values %best ];
}

# Register local + production URLs for a hosted site (e.g. ve7tit.local:3000 and ve7tit.com)
sub _register_hosted_site_nav {
    my ( $self, $c, $add, $site_name, $site_row, $production_domain ) = @_;
    return unless $site_name;

    my $label = lc($site_name);
    $label =~ s/\s+//g;

    my $local_url = $site_row ? $self->_site_local_nav_url( $c, $site_row ) : undef;
    if ($local_url) {
        my ($host) = $local_url =~ m{^https?://([^/]+)}i;
        $self->_register_chat_nav_link(
            $add, $label, $local_url, '_blank', 'site_local',
            0, "$site_name ($host)"
        );
    }

    my $prod_url;
    if ( defined $production_domain && $production_domain ne '' && $production_domain !~ /\.local$/i ) {
        $prod_url = $self->_normalize_hosting_nav_url( $c, $production_domain, $site_row );
    }
    $prod_url //= ( $site_row ? $self->_site_production_nav_url( $c, $site_row ) : undef );

    if ($prod_url) {
        my ($prod_host) = $prod_url =~ m{^https?://([^/]+)}i;
        $prod_host =~ s/^www\.//i if $prod_host;
        $self->_register_chat_nav_link(
            $add, $label, $prod_url, '_blank', 'site_production',
            0, "$site_name ($prod_host)"
        );
        $self->_register_chat_nav_link(
            $add, lc($prod_host), $prod_url, '_blank', 'site_production',
            0, "$site_name ($prod_host)"
        ) if $prod_host && lc($prod_host) ne $label;
    }
}

# Register one chat-nav alias; $alias_hosts=0 for auto-indexed rows (hosting, domains)
sub _register_chat_nav_link {
    my ( $self, $add, $name, $url, $target, $source, $alias_hosts, $display_name ) = @_;
    $alias_hosts = 1 unless defined $alias_hosts;
    return unless $name && $url;
    $target = $self->_default_external_target( $url, $target );
    $display_name //= $name;
    $add->( $name, $display_name, $url, $target, $source );
    return unless $alias_hosts;

    my $norm = lc($name);
    $norm =~ s/[^a-z0-9]+/ /g;
    for my $w (split /\s+/, $norm) {
        $add->( $w, $name, $url, $target, $source ) if length($w) >= 3;
    }
    if ( $url =~ m{^https?://([^/?#]+)}i ) {
        my $host = lc($1);
        $host =~ s/^www\.//;
        $host =~ s/:\d+$//;
        $add->( $host, $name, $url, $target, $source );
        my ($hostbase) = $host =~ /^([a-z0-9][-a-z0-9]*)/;
        $add->( $hostbase, $name, $url, $target, $source )
            if $hostbase && length($hostbase) >= 3 && $hostbase ne lc($name);
    }
}

# User + shortcut links for AI chat fast-path navigation (label, url, target)
sub get_user_chat_nav_links {
    my ($self, $c) = @_;
    my @out;
    my $username = $c->session->{username} || '';
    return \@out unless $username;

    my $site = $self->_current_site($c);
    my $role = $c->stash->{is_admin} ? 'admin' : 'user';
    my %seen;

    my $add = sub {
        my ($label, $name, $url, $target, $source) = @_;
        return unless $label && $url;
        my $key = lc($label) . '|' . $url;
        return if $seen{$key}++;
        push @out, {
            label  => lc($label),
            name   => $name || $label,
            url    => $url,
            target => ($target && $target ne '') ? $target : '_self',
            source => $source,
        };
    };

    # Chat can open any of the user's bookmarks regardless of current site scope
    for my $l (@{ $self->get_all_private_links_for_user($c, $username) }) {
        $self->_register_chat_nav_link(
            $add, $l->{name}, $l->{url}, $l->{target}, 'private_link'
        );
    }

    # Top-nav menu links (public + this user's private) for the current site
    for my $cat (@MENU_LINK_CATEGORIES) {
        next if $cat eq 'Admin_links' && $self->_role_rank($role) < 2;
        for my $l (@{ $self->get_merged_menu_links($c, $cat, $site) }) {
            $self->_register_chat_nav_link(
                $add, $l->{name}, $l->{url}, $l->{target}, 'menu_link'
            );
        }
    }

    # Active hosting accounts and site domains (Hosted menu — not in internal_links_tb)
    eval {
        my @ha = $c->model('DBEncy')->resultset('Accounting::HostingAccount')->search(
            { status => 'active' },
            { order_by => 'sitename' }
        )->all;
        for my $ha (@ha) {
            my $sitename = $ha->sitename;
            my $domain   = $ha->domain;
            next unless $sitename;
            my $site_row = $self->_find_site_row_by_name( $c, $sitename );
            $self->_register_hosted_site_nav(
                $c, $add, $sitename, $site_row, $domain
            );
        }
    };
    if ($@) {
        $c->log->error("Error loading hosting accounts for chat nav: $@");
    }

    eval {
        my $sites = $c->model('Site')->get_all_sites($c);
        $sites = [] unless ref($sites) eq 'ARRAY';
        my %registered_site;
        for my $site_row (@$sites) {
            my $name = ref($site_row) ? $site_row->name : $site_row->{name};
            next unless $name;
            next if $registered_site{ lc($name) }++;
            $self->_register_hosted_site_nav( $c, $add, $name, $site_row, undef );
        }
    };
    if ($@) {
        $c->log->error("Error loading site modules for chat nav: $@");
    }

    for my $sc (@{ $self->get_ai_navigation_shortcuts($c, $role) }) {
        $add->($sc->{label}, $sc->{label}, $sc->{url}, '_blank', 'shortcut');
        for my $tr (@{ $sc->{trigger_phrases} || [] }) {
            my $t = lc($tr);
            $t =~ s/^\s+|\s+$//g;
            $t =~ s/^(?:open|go to|take me to)\s+(?:my\s+)?//;
            $add->($t, $sc->{label}, $sc->{url}, '_blank', 'shortcut') if length($t) >= 2;
        }
    }

    # Role-filtered core routes + links observed during prior AI sessions (LearnedData)
    $self->_register_core_role_nav_routes( $c, $add, $role );
    $self->_register_learned_chat_nav_links( $c, $add, $role );

    return $self->_dedupe_chat_nav_destinations( $c, \@out );
}

sub _normalize_nav_phrase {
    my ($self, $phrase) = @_;
    $phrase = lc( $phrase // '' );
    $phrase =~ s/^\s+|\s+$//g;
    $phrase =~ s/^(?:goto|go to|open|take me to|navigate to|visit|switch to|switch|bring me to|load|browse|display|show me the|show me|take me to the|go to the)\s+//;
    $phrase =~ s/^(?:the|a|an)\s+//;
    $phrase =~ s/[^\w.\-]+/ /g;
    $phrase =~ s/\s+/ /g;
    return $phrase;
}

sub _chat_nav_link_matches_phrase {
    my ( $self, $l, $q ) = @_;
    return 0 unless $l && $q;
    my $label = $l->{label} // '';
    my $name  = lc( $l->{name} // '' );
    return 1 if $label eq $q;
    return 1 if $name eq $q;
    return 1 if $label =~ /^\Q$q\E[.\-]/;
    return 1 if length($q) >= 3 && $name =~ /^\Q$q\E\s*\(/;
    my @words = split /\s+/, $label;
    return 1 if grep { $_ eq $q } @words;
    return 1 if length($q) >= 4 && $label eq $q;
    if ( length($q) >= 4 ) {
        my $max_dist = length($q) >= 7 ? 2 : 1;
        return 1 if $self->_edit_distance( $q, $label ) <= $max_dist;
        return 1 if length($name) >= 4 && $self->_edit_distance( $q, $name ) <= $max_dist;
        for my $w (@words) {
            return 1 if length($w) >= 4 && $self->_edit_distance( $q, $w ) <= $max_dist;
        }
    }
    if ( $self->_phrase_looks_like_opnsense($q) ) {
        my $url = $l->{url} // '';
        return 1 if $url =~ m{/admin/infrastructure/opnsense}i;
        return 1 if ( $label =~ /opn.?sense/i || $name =~ /opn.?sense/i )
            && $url =~ m{/project/details}i;
    }
    return 0;
}

sub find_opnsense_nav_destinations {
    my ( $self, $c ) = @_;
    return [] unless $c->stash->{is_admin};
    my @dest;
    push @dest, {
        label  => 'opnsense gateway',
        name   => 'OPNsense Gateway Dashboard',
        url    => '/admin/infrastructure/opnsense',
        target => '_self',
        source => 'core_route',
    };
    eval {
        my $site = $self->_current_site($c);
        my $projects = $c->model('Project')->get_projects(
            $c->model('DBEncy')->schema, $site
        );
        if ($projects) {
            for my $p (@$projects) {
                my $n = $p->name // '';
                next unless $n =~ /opn\s*sense/i;
                push @dest, {
                    label  => 'opnsense project',
                    name   => $n,
                    url    => '/project/details?project_id=' . ( $p->id // '' ),
                    target => '_blank',
                    source => 'menu_link',
                };
                last;
            }
        }
    };
    return \@dest;
}

sub find_user_nav_link_for_phrase {
    my ( $self, $c, $phrase ) = @_;
    my $q = $self->_normalize_nav_phrase($phrase);
    return undef unless $q && length($q) >= 2;

    if ( $self->_phrase_looks_like_opnsense($q) && $c->stash->{is_admin} ) {
        my $bundle = $self->find_opnsense_nav_destinations($c);
        return $bundle->[0] if $bundle && @$bundle;
    }

    my @raw = @{ $self->get_user_chat_nav_links($c) };
    my @matches = grep { $self->_chat_nav_link_matches_phrase( $_, $q ) } @raw;
    return undef unless @matches;

    my @scored = sort {
        $self->_chat_nav_link_score( $c, $b, $q ) <=> $self->_chat_nav_link_score( $c, $a, $q )
    } @matches;
    my $deduped = $self->_dedupe_chat_nav_destinations( $c, \@scored, $q );
    return $deduped->[0] if $deduped && @$deduped;
    return undef;
}

sub match_user_nav_link :Path('/navigation/match_user_nav_link') :Args(0) {
    my ( $self, $c ) = @_;

    my $root_controller = $c->controller('Root');
    unless ( $root_controller->user_exists($c) && $c->session->{username} ) {
        $c->response->status(401);
        $c->stash->{json} = { success => 0, error => 'Login required' };
        $c->forward('View::JSON');
        return;
    }

    my $phrase = $c->req->param('phrase') || '';
    my $q      = $self->_normalize_nav_phrase($phrase);

    if ( $q && $self->_phrase_looks_like_opnsense($q) && $c->stash->{is_admin} ) {
        my $bundle = $self->find_opnsense_nav_destinations($c);
        if ( $bundle && @$bundle ) {
            $c->stash->{json} = {
                success => 1,
                multi   => 1,
                links   => $bundle,
                link    => $bundle->[0],
            };
            $c->forward('View::JSON');
            return;
        }
    }

    my $match = $self->find_user_nav_link_for_phrase( $c, $phrase );

    if ($match) {
        $c->stash->{json} = { success => 1, link => $match };
    }
    else {
        $c->stash->{json} = { success => 0, error => 'No matching link' };
    }
    $c->forward('View::JSON');
}

sub user_nav_links :Path('/navigation/user_nav_links') :Args(0) {
    my ($self, $c) = @_;
    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $c->session->{username}) {
        $c->response->status(401);
        $c->stash->{json} = { success => 0, error => 'Login required' };
        $c->forward('View::JSON');
        return;
    }
    $c->stash->{json} = {
        success => 1,
        links   => $self->get_user_chat_nav_links($c),
    };
    $c->forward('View::JSON');
}

# JSON: match phrase to AI shortcut (for client nav / chat helpers)
sub match_ai_shortcut :Path('/navigation/match_ai_shortcut') :Args(0) {
    my ($self, $c) = @_;

    my $phrase = $c->req->param('phrase') || '';
    my $role   = $c->stash->{is_admin} ? 'admin' : ($c->session->{username} ? 'user' : 'guest');
    my $match  = $self->find_ai_shortcut_for_phrase($c, $phrase, $role);

    if ($match) {
        $c->stash->{json} = { success => 1, shortcut => $match };
    } else {
        $c->stash->{json} = { success => 0, error => 'No matching shortcut' };
    }
    $c->forward('View::JSON');
}

# Method to clear navigation cache (useful for admin operations)
sub clear_hosting_visibility_cache {
    my ($self) = @_;
    $_hosting_list_publicly_cache = {};
}

sub clear_navigation_cache {
    my ($self, $c) = @_;
    $self->clear_hosting_visibility_cache();
    $self->_navigation_cache({});
    $self->_cache_timestamp(0);
    $c->log->debug("Navigation cache cleared");
}

# Auto method to populate navigation data for all requests
sub auto :Private {
    my ($self, $c) = @_;
    
    # Use eval to catch any errors
    eval {
        $self->populate_navigation_data($c);
    };
    if ($@) {
        $c->log->error("Error in Navigation auto method: $@");
    }
    
    return 1; # Allow the request to proceed
}


