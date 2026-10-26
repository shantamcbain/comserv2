package Comserv::Controller::Admin::SiteModules;

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)
use Try::Tiny;
use Comserv::Util::Logging;

BEGIN { extends 'Comserv::Controller::Base'; }

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub begin :Private {
    my ($self, $c) = @_;

    my $roles    = $c->session->{roles} || [];
    my $is_admin = $c->session->{is_admin}
                || (ref($roles) eq 'ARRAY' && grep { lc($_) eq 'admin' } @$roles)
                || (!ref($roles) && $roles =~ /\badmin\b/i);

    unless ($is_admin) {
        $c->res->redirect($c->uri_for('/user/login', { return_to => $c->req->uri }));
        $c->detach;
    }
}

sub index :Path('/admin/site_modules') :Args(0) {
    my ($self, $c) = @_;

    my $is_csc_admin = (uc($c->stash->{SiteName} || $c->session->{SiteName} || '') eq 'CSC')
                    && $c->stash->{is_admin};

    my @modules;
    try {
        my %search = $is_csc_admin ? () : (sitename => ($c->stash->{SiteName} || $c->session->{SiteName}));
        @modules = $c->model('DBEncy')->resultset('SiteModule')->search(
            \%search,
            { order_by => [qw(sitename module_name)] }
        )->all;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index',
            "Failed to load site_modules: $_");
        $c->stash->{error} = "Could not load module list: $_";
    };

    my @sitenames;
    try {
        @sitenames = $c->model('DBEncy')->resultset('Site')
            ->search({}, { columns => ['name'], order_by => 'name' })
            ->get_column('name')->all;
    } catch {
        @sitenames = ('CSC');
    };

    my $addon_approval_count = 0;
    if ($is_csc_admin) {
        try {
            $addon_approval_count = scalar $self->_pending_addon_requests($c);
        } catch {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'index',
                "Approval queue count failed: $_");
        };
    }

    $c->stash(
        modules              => \@modules,
        sitenames            => \@sitenames,
        is_csc_admin         => $is_csc_admin,
        addon_approval_count => $addon_approval_count,
        template             => 'admin/site_modules/index.tt',
    );
}

sub toggle :Path('/admin/site_modules/toggle') :Args(0) {
    my ($self, $c) = @_;

    my $id      = $c->req->param('id');
    my $enabled = $c->req->param('enabled') ? 1 : 0;
    my $refused = '';

    if ($enabled && !$self->_is_csc_admin($c)) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'toggle',
            "Refused enable id=$id — not a CSC admin");
        $c->flash->{error_msg} = 'Only a CSC admin can enable an add-on. Use the approval queue.';
        $c->res->redirect($c->uri_for('/admin/site_modules/approval_queue'));
        return $c->detach;
    }

    try {
        my $row = $c->model('DBEncy')->resultset('SiteModule')->find($id);
        if ($row && $enabled && !$self->_core_site_name($row->sitename)) {
            $refused = $row->sitename;
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'toggle',
                "Refused enable for site $refused — not 3d, CSC, or Shanta");
        } elsif ($row) {
            $row->update({ enabled => $enabled });
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'toggle',
                "site_modules id=$id set enabled=$enabled by " . ($c->session->{username} || 'unknown'));
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'toggle',
            "Toggle failed for id=$id: $_");
    };

    if ($refused) {
        $c->flash->{error_msg} = "Add-ons are enabled only for 3d, CSC, and Shanta (refused $refused).";
        $c->res->redirect($c->uri_for('/admin/site_modules/approval_queue'));
        return $c->detach;
    }

    $c->res->redirect($c->uri_for('/admin/site_modules'));
    $c->detach;
}

sub set_min_role :Path('/admin/site_modules/set_min_role') :Args(0) {
    my ($self, $c) = @_;

    my $id       = $c->req->param('id');
    my $min_role = $c->req->param('min_role') || 'member';

    try {
        my $row = $c->model('DBEncy')->resultset('SiteModule')->find($id);
        if ($row) {
            $row->update({ min_role => $min_role });
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'set_min_role',
                "site_modules id=$id min_role=$min_role by " . ($c->session->{username} || 'unknown'));
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'set_min_role',
            "set_min_role failed for id=$id: $_");
    };

    $c->res->redirect($c->uri_for('/admin/site_modules'));
    $c->detach;
}

sub add :Path('/admin/site_modules/add') :Args(0) {
    my ($self, $c) = @_;

    if ($c->req->method eq 'POST') {
        my $sitename    = $c->req->param('sitename')    || '';
        my $module_name = $c->req->param('module_name') || '';
        my $enabled     = $c->req->param('enabled')  ? 1 : 0;
        my $min_role    = $c->req->param('min_role')    || 'member';

        if ($module_name eq '_custom_') {
            $module_name = $c->req->param('module_name_custom') || '';
        }

        if ($sitename && $module_name) {
            if ($enabled) {
                my $canon = $self->_core_site_name($sitename);
                unless ($self->_is_csc_admin($c) && $canon) {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'add',
                        "Refused enable site=$sitename module=$module_name — CSC admin and core site required");
                    $c->flash->{error_msg} = 'Only a CSC admin can enable an add-on, and only for 3d, CSC, or Shanta. Use the approval queue.';
                    $c->res->redirect($c->uri_for('/admin/site_modules/approval_queue'));
                    return $c->detach;
                }
                $sitename = $canon;
            }
            try {
                $c->model('DBEncy')->resultset('SiteModule')->update_or_create(
                    {
                        sitename    => $sitename,
                        module_name => $module_name,
                        enabled     => $enabled,
                        min_role    => $min_role,
                    },
                    { key => 'site_module_unique' }
                );
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add',
                    "site_module added/updated: site=$sitename module=$module_name enabled=$enabled min_role=$min_role");
            } catch {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add',
                    "add failed: $_");
            };
        }
        $c->res->redirect($c->uri_for('/admin/site_modules'));
        $c->detach;
    }

    $c->res->redirect($c->uri_for('/admin/site_modules'));
    $c->detach;
}

sub user_overrides :Path('/admin/site_modules/user_overrides') :Args(0) {
    my ($self, $c) = @_;

    my $filter_user = $c->req->param('username') || '';
    my $filter_site = $c->req->param('sitename') || '';

    my @overrides;
    try {
        my %where;
        $where{username} = $filter_user if $filter_user;
        $where{sitename} = $filter_site if $filter_site;
        unless ($c->stash->{is_admin} && uc($c->stash->{SiteName} || '') eq 'CSC') {
            $where{sitename} = $c->stash->{SiteName} || $c->session->{SiteName};
        }
        @overrides = $c->model('DBEncy')->resultset('UserModuleAccess')->search(
            \%where,
            { order_by => [qw(sitename username module_name)] }
        )->all;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'user_overrides',
            "Failed to load user_module_access: $_");
        $c->stash->{error} = "Could not load overrides: $_";
    };

    my @sitenames;
    try {
        @sitenames = $c->model('DBEncy')->resultset('Site')
            ->search({}, { columns => ['name'], order_by => 'name' })
            ->get_column('name')->all;
    } catch { @sitenames = ('CSC'); };

    $c->stash(
        overrides    => \@overrides,
        sitenames    => \@sitenames,
        filter_user  => $filter_user,
        filter_site  => $filter_site,
        template     => 'admin/site_modules/user_overrides.tt',
    );
}

sub grant_user :Path('/admin/site_modules/grant_user') :Args(0) {
    my ($self, $c) = @_;

    if ($c->req->method eq 'POST') {
        my $username    = $c->req->param('username')    || '';
        my $sitename    = $c->req->param('sitename')    || '';
        my $module_name = $c->req->param('module_name') || '';
        my $granted     = $c->req->param('granted') ? 1 : 0;

        if ($username && $sitename && $module_name) {
            try {
                $c->model('DBEncy')->resultset('UserModuleAccess')->update_or_create(
                    {
                        username    => $username,
                        sitename    => $sitename,
                        module_name => $module_name,
                        granted     => $granted,
                        granted_by  => $c->session->{username} || 'admin',
                    },
                    { key => 'user_module_unique' }
                );
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'grant_user',
                    "user_module_access: username=$username site=$sitename module=$module_name granted=$granted");
            } catch {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'grant_user',
                    "grant_user failed: $_");
            };
        }
    }

    $c->res->redirect($c->uri_for('/admin/site_modules/user_overrides'));
    $c->detach;
}

sub revoke_user :Path('/admin/site_modules/revoke_user') :Args(1) {
    my ($self, $c, $id) = @_;

    try {
        my $row = $c->model('DBEncy')->resultset('UserModuleAccess')->find($id);
        $row->delete if $row;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'revoke_user',
            "UserModuleAccess id=$id deleted by " . ($c->session->{username} || 'unknown'));
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'revoke_user',
            "revoke_user failed for id=$id: $_");
    };

    $c->res->redirect($c->uri_for('/admin/site_modules/user_overrides'));
    $c->detach;
}

sub _ensure_system_modules_table {
    my ($self, $c) = @_;
    eval {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        $dbh->do(q{
            CREATE TABLE IF NOT EXISTS `system_modules` (
                `key` VARCHAR(100) NOT NULL,
                `name` VARCHAR(255) NOT NULL,
                `owner` VARCHAR(100) NOT NULL,
                `description` TEXT,
                `route` VARCHAR(255) NOT NULL,
                `monthly_cost` DECIMAL(10,2) NOT NULL DEFAULT '0.00',
                `is_active` TINYINT(1) NOT NULL DEFAULT '1',
                `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                PRIMARY KEY (`key`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        });
    };
}

sub _default_addon_catalog {
    return (
        { key => 'beekeeping', name => 'Beekeeping & Apiary Management', owner => 'BMaster', description => 'Track bee hives, apiaries, queen logs, and inspections.', route => '/apiary' },
        { key => 'planning', name => 'AI Planning & Project System', owner => 'CSC', description => 'Advanced project planning, todo tracking, and AI-assisted workflows.', route => '/todo' },
        { key => 'accounting', name => 'Accounting & Ledger System', owner => 'CSC', description => 'Chart of accounts, general ledger entries, inventory items, and suppliers.', route => '/Accounting' },
        { key => 'ency', name => 'Encyclopedia & Herbal Database', owner => 'ENCY', description => 'Share scientific crop data, botanical encyclopedia, and medicinal herb logs.', route => '/ency' },
        { key => 'healthkitchen', name => 'Health Kitchen', owner => 'ENCY', description => 'Personal pantry of foods and herbs, ENCY-linked knowledge, and wellness menus from active symptoms.', route => '/healthkitchen' },
        { key => 'ecommerce', name => 'E-Commerce & Store', owner => 'CSC', description => 'Sell products, list items, handle currency checkout, and manage shipping.', route => '/shop' },
        { key => 'helpdesk', name => 'HelpDesk Support & Guide system', owner => 'CSC', description => 'Issue ticket tracking, linux guides, and support desk system.', route => '/helpdesk' },
        { key => 'foraging', name => 'Foraging & Wild Harvesting Log', owner => 'Forager', description => 'Map and log foraging spots, wild harvest logs, and seasonal wild botany.', route => '/foraging' },
        { key => 'brew', name => 'Brew — Brewhouse Management', owner => 'Brew', description => 'Beer, mead, wine, and brewhouse operations. Use brew.yourdomain.com.', route => '/brew' },
        { key => 'membership', name => 'Multi-Site Membership System', owner => 'CSC', description => 'Set up recurring billing, regional pricing, payment gateways, and coins.', route => '/membership' },
        { key => '3d', name => '3D Printing & Custom Fabrication', owner => '3D', description => 'Order 3D prints, upload design models, and track build queues.', route => '/3d' },
    );
}

sub _addon_to_hash {
    my ( $self, $addon ) = @_;
    return unless $addon;
    if ( ref($addon) eq 'HASH' ) {
        return $addon;
    }
    return {
        key          => $addon->get_column('key'),
        name         => $addon->get_column('name'),
        owner        => $addon->get_column('owner'),
        description  => $addon->get_column('description'),
        route        => $addon->get_column('route'),
        monthly_cost => $addon->get_column('monthly_cost'),
        is_active    => $addon->get_column('is_active'),
    };
}

sub edit_addon :Path('/admin/site_modules/edit_addon') :Args(0) {
    my ($self, $c) = @_;

    my $key = $c->req->param('key') || '';
    unless ($key) {
        $c->flash->{error_msg} = "No module key specified.";
        $c->res->redirect($c->uri_for('/membership/addons'));
        return $c->detach;
    }

    $self->_ensure_system_modules_table($c);

    my $addon_row;
    try {
        $addon_row = $c->model('DBEncy')->resultset('SystemModule')->find($key);
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_addon',
            "Failed to load SystemModule: $_");
    };

    my $addon = $self->_addon_to_hash($addon_row);
    unless ($addon) {
        my ($found) = grep { $_->{key} eq $key } $self->_default_addon_catalog();
        if ($found) {
            $addon = { %$found, monthly_cost => 0, is_active => 1, catalog_source => 'builtin' };
        }
    } else {
        $addon->{catalog_source} = 'database';
    }

    my @sitenames;
    try {
        @sitenames = $c->model('DBEncy')->resultset('Site')
            ->search({}, { columns => ['name'], order_by => 'name' })
            ->get_column('name')->all;
    } catch {
        @sitenames = ($c->stash->{SiteName} || $c->session->{SiteName} || 'CSC');
    };

    my $edit_site = $c->req->param('sitename')
        || $c->stash->{SiteName}
        || $c->session->{SiteName}
        || 'CSC';

    my $site_module;
    try {
        $site_module = $c->model('DBEncy')->resultset('SiteModule')->search({
            sitename    => $edit_site,
            module_name => $key,
        }, { rows => 1 })->single;
    } catch { };

    if ($c->req->method eq 'POST') {
        my $name         = $c->req->param('name') || '';
        my $owner        = $c->req->param('owner') || '';
        my $description  = $c->req->param('description') || '';
        my $route        = $c->req->param('route') || '';
        my $monthly_cost = $c->req->param('monthly_cost') || 0;
        my $is_active    = $c->req->param('is_active') ? 1 : 0;
        my $site_enabled = $c->req->param('site_enabled') ? 1 : 0;
        my $min_role     = $c->req->param('min_role') || 'member';
        my $posted_site  = $c->req->param('sitename') || '';
        $edit_site       = $posted_site || $edit_site;

        if ($site_enabled) {
            my $canon = $self->_core_site_name($posted_site);
            unless ($self->_is_csc_admin($c) && $posted_site && $canon) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'edit_addon',
                    "Refused enable key=$key sitename=$posted_site — CSC admin must name 3d, CSC, or Shanta");
                $c->flash->{error_msg} = 'Only a CSC admin can enable an add-on, and the target SiteName must be posted (3d, CSC, or Shanta). The session site is not the target.';
                $c->res->redirect($c->uri_for('/admin/site_modules/approval_queue'));
                return $c->detach;
            }
            $edit_site = $canon;
        }

        my $saved_ok = 0;
        try {
            $c->model('DBEncy')->resultset('SystemModule')->update_or_create(
                {
                    key          => $key,
                    name         => $name,
                    owner        => $owner,
                    description  => $description,
                    route        => $route,
                    monthly_cost => $monthly_cost,
                    is_active    => $is_active,
                },
                { key_cols => ['key'] }
            );
            $c->model('DBEncy')->resultset('SiteModule')->update_or_create(
                {
                    sitename    => $edit_site,
                    module_name => $key,
                    enabled     => $site_enabled,
                    min_role    => $min_role,
                },
                { key => 'site_module_unique' }
            );
            $saved_ok = 1;
        } catch {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_addon',
                "Failed to save addon: $_");
            $c->stash->{error_msg} = "Failed to save addon: $_";
        };
        # Redirect/detach OUTSIDE try: detach throws catalyst_detach, which the
        # catch block above would otherwise log as a save failure (#2600).
        if ($saved_ok) {
            $c->flash->{success_msg} = "Add-on '$key' saved (catalog + site $edit_site).";
            $c->res->redirect($c->uri_for('/membership/addons'));
            return $c->detach;
        }
    }

    unless ($addon) {
        $c->stash(
            error_msg => "Unknown add-on key '$key'. Add it under Module Access Control or choose a key from the catalog list.",
            template  => 'admin/site_modules/edit_addon.tt',
        );
        $c->forward($c->view('TT'));
        return;
    }

    $c->stash(
        addon         => $addon,
        sitenames     => \@sitenames,
        edit_site     => $edit_site,
        site_enabled  => $site_module ? ($site_module->enabled ? 1 : 0) : 0,
        site_min_role => $site_module ? ($site_module->min_role || 'member') : 'member',
        template      => 'admin/site_modules/edit_addon.tt',
    );
    $c->forward($c->view('TT'));
}

sub _is_csc_admin {
    my ($self, $c) = @_;
    my $site = uc($c->stash->{SiteName} || $c->session->{SiteName} || '');
    return 0 unless $site eq 'CSC';
    return 1 if $c->stash->{is_admin} || $c->session->{is_admin};
    my $roles = $c->session->{roles} || [];
    if (ref $roles eq 'ARRAY') {
        return 1 if grep { lc($_) eq 'admin' } @$roles;
    } elsif ($roles && lc($roles) =~ /\badmin\b/) {
        return 1;
    }
    return 0;
}

# Same core-site list MailInvoiceStock uses. Other sites are not enabled here.
sub _core_site_name {
    my ($self, $name) = @_;
    my %canon = ( '3d' => '3d', csc => 'CSC', shanta => 'Shanta' );
    return $canon{ lc($name // '') } || '';
}

sub _enable_module_name {
    my ($self, $key) = @_;
    $key = lc($key // '');
    return '3d'         if $key eq '3d' || $key eq 'printing_3d';
    return 'planning'   if $key eq 'planning' || $key eq 'ai';
    return 'workshops'  if $key eq 'workshops' || $key eq 'workshop';
    return 'accounting' if $key eq 'accounting';
    return $key;
}

sub _module_aliases {
    my ($self, $key) = @_;
    my $write = $self->_enable_module_name($key);
    my %extra = (
        '3d'        => [qw(3d printing_3d)],
        planning    => [qw(planning ai)],
        workshops   => [qw(workshops workshop)],
        accounting  => [qw(accounting Accounting)],
    );
    return @{ $extra{$write} || [$write] };
}

sub _feature_label {
    my ($self, $key) = @_;
    my $write = $self->_enable_module_name($key);
    for my $row ($self->_default_addon_catalog()) {
        return $row->{name} if $row->{key} eq $write;
    }
    return $write;
}

sub _addon_enabled {
    my ($self, $c, $canon, $key) = @_;
    my @aliases = $self->_module_aliases($key);
    my $rs = $c->model('DBEncy')->resultset('SiteModule')->search({
        module_name => { -in => \@aliases },
        enabled     => 1,
    });
    while (my $row = $rs->next) {
        return 1 if lc($row->sitename) eq lc($canon);
    }
    return 0;
}

sub _pending_addon_requests {
    my ($self, $c) = @_;
    my @pending;
    my @accounts = $c->model('DBEncy')->resultset('Accounting::HostingAccount')->search(
        { requested_addons => { '!=' => '' } },
        { order_by => 'sitename' },
    )->all;
    for my $acct (@accounts) {
        my $raw = $acct->requested_addons || '';
        next if $raw =~ /^\s*$/;
        my $canon = $self->_core_site_name($acct->sitename);
        next unless $canon;
        my $subscriber = $acct->created_by || $acct->contact_email || '';
        my $when = $acct->updated_at || $acct->created_at || '';
        for my $key (split /\s*,\s*/, $raw) {
            $key =~ s/^\s+|\s+$//g;
            next unless length $key;
            $key = lc $key;
            next if $self->_addon_enabled($c, $canon, $key);
            push @pending, {
                sitename    => $canon,
                module_name => $key,
                feature     => $self->_feature_label($key),
                subscriber  => $subscriber,
                when        => "$when",
            };
        }
    }
    return @pending;
}

sub approval_queue :Path('/admin/site_modules/approval_queue') :Args(0) {
    my ($self, $c) = @_;

    unless ($self->_is_csc_admin($c)) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'approval_queue',
            'Refused approval queue — not a CSC admin');
        $c->flash->{error_msg} = 'The add-on approval queue is only for a CSC admin on the CSC site.';
        $c->res->redirect($c->uri_for('/admin/site_modules'));
        return $c->detach;
    }

    my @pending;
    my $error = '';
    try {
        @pending = $self->_pending_addon_requests($c);
    } catch {
        $error = "$_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'approval_queue',
            "Failed to load approval queue: $_");
    };

    $c->stash(
        pending    => \@pending,
        error_msg  => $error,
        template   => 'admin/site_modules/approval_queue.tt',
    );
    $c->forward($c->view('TT'));
}

sub approve_addon :Path('/admin/site_modules/approve_addon') :Args(0) {
    my ($self, $c) = @_;

    unless ($c->req->method eq 'POST' && $self->_is_csc_admin($c)) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'approve_addon',
            'Refused addon approve — CSC admin POST required');
        $c->flash->{error_msg} = 'Only a CSC admin can approve an add-on.';
        $c->res->redirect($c->uri_for('/admin/site_modules/approval_queue'));
        return $c->detach;
    }

    my $posted_site = $c->req->body_parameters->{sitename} || '';
    my $posted_mod  = lc($c->req->body_parameters->{module_name} || '');
    my $canon       = $self->_core_site_name($posted_site);
    unless ($canon && $posted_mod) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'approve_addon',
            "Refused approve sitename=$posted_site module=$posted_mod — name a core site and a module");
        $c->flash->{error_msg} = 'Name the target SiteName (3d, CSC, or Shanta) and the add-on. Other sites are not enabled from this queue.';
        $c->res->redirect($c->uri_for('/admin/site_modules/approval_queue'));
        return $c->detach;
    }

    my $acct;
    my $lookup_failed = 0;
    try {
        my @accounts = $c->model('DBEncy')->resultset('Accounting::HostingAccount')->search(
            { requested_addons => { '!=' => '' } },
        )->all;
        for my $row (@accounts) {
            if (lc($row->sitename) eq lc($canon)) {
                $acct = $row;
                last;
            }
        }
    } catch {
        $lookup_failed = 1;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'approve_addon',
            "Hosting account lookup failed: $_");
    };
    if ($lookup_failed) {
        $c->flash->{error_msg} = 'Could not read the subscribe list.';
        $c->res->redirect($c->uri_for('/admin/site_modules/approval_queue'));
        return $c->detach;
    }

    my %wanted;
    if ($acct) {
        $wanted{lc $_} = 1 for grep { length } map { s/^\s+|\s+$//gr } split /\s*,\s*/, ($acct->requested_addons || '');
    }
    my $requested = 0;
    for my $alias ($self->_module_aliases($posted_mod)) {
        $requested = 1 if $wanted{lc $alias};
    }
    unless ($acct && $requested) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'approve_addon',
            "Refused approve $canon/$posted_mod — not on requested_addons");
        $c->flash->{error_msg} = "No subscribe request for $posted_mod on $canon.";
        $c->res->redirect($c->uri_for('/admin/site_modules/approval_queue'));
        return $c->detach;
    }

    my $write_name = $self->_enable_module_name($posted_mod);
    my $saved = 0;
    try {
        $c->model('DBEncy')->resultset('SiteModule')->update_or_create(
            {
                sitename    => $canon,
                module_name => $write_name,
                enabled     => 1,
            },
            { key => 'site_module_unique' }
        );
        $saved = 1;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'approve_addon',
            "Enabled $write_name for $canon (requested $posted_mod) by "
            . ($c->session->{username} || 'unknown'));
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'approve_addon',
            "Enable failed for $canon/$write_name: $_");
        $c->flash->{error_msg} = "Could not enable $write_name for $canon.";
    };
    if ($saved) {
        $c->flash->{success_msg} = "Enabled $write_name for $canon. Subscription was not treated as access until this approve.";
    }
    $c->res->redirect($c->uri_for('/admin/site_modules/approval_queue'));
    return $c->detach;
}

__PACKAGE__->meta->make_immutable;
1;
