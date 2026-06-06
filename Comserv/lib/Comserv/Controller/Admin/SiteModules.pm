package Comserv::Controller::Admin::SiteModules;

use Moose;
use namespace::autoclean;
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

    $c->stash(
        modules      => \@modules,
        sitenames    => \@sitenames,
        is_csc_admin => $is_csc_admin,
        template     => 'admin/site_modules/index.tt',
    );
}

sub toggle :Path('/admin/site_modules/toggle') :Args(0) {
    my ($self, $c) = @_;

    my $id      = $c->req->param('id');
    my $enabled = $c->req->param('enabled');  # 0 or 1

    try {
        my $row = $c->model('DBEncy')->resultset('SiteModule')->find($id);
        if ($row) {
            $row->update({ enabled => $enabled ? 1 : 0 });
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'toggle',
                "site_modules id=$id set enabled=$enabled by " . ($c->session->{username} || 'unknown'));
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'toggle',
            "Toggle failed for id=$id: $_");
    };

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

sub edit_addon :Path('/admin/site_modules/edit_addon') :Args(0) {
    my ($self, $c) = @_;

    my $key = $c->req->param('key') || '';
    unless ($key) {
        $c->flash->{error_msg} = "No module key specified.";
        return $c->res->redirect($c->uri_for('/membership/addons'));
    }

    # Ensure system_modules table exists
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

    my $addon = undef;
    try {
        $addon = $c->model('DBEncy')->resultset('SystemModule')->find($key);
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_addon',
            "Failed to load SystemModule: $_");
    };

    # Default values fallback
    unless ($addon) {
        my @defaults = (
            { key => 'beekeeping', name => 'Beekeeping & Apiary Management', owner => 'BMaster', description => 'Track bee hives, apiaries, queen logs, and inspections.', route => '/apiary' },
            { key => 'planning', name => 'AI Planning & Project System', owner => 'CSC', description => 'Advanced project planning, todo tracking, and AI-assisted workflows.', route => '/todo' },
            { key => 'accounting', name => 'Accounting & Ledger System', owner => 'CSC', description => 'Chart of accounts, general ledger entries, inventory items, and suppliers.', route => '/Accounting' },
            { key => 'ency', name => 'Encyclopedia & Herbal Database', owner => 'ENCY', description => 'Share scientific crop data, botanical encyclopedia, and medicinal herb logs.', route => '/ency' },
            { key => 'ecommerce', name => 'E-Commerce & Store', owner => 'CSC', description => 'Sell products, list items, handle currency checkout, and manage shipping.', route => '/shop' },
            { key => 'helpdesk', name => 'HelpDesk Support & Guide system', owner => 'CSC', description => 'Issue ticket tracking, linux guides, and support desk system.', route => '/helpdesk' },
            { key => 'foraging', name => 'Foraging & Wild Harvesting Log', owner => 'Forager', description => 'Map and log foraging spots, wild harvest logs, and seasonal wild botany.', route => '/foraging' },
            { key => 'membership', name => 'Multi-Site Membership System', owner => 'CSC', description => 'Set up recurring billing, regional pricing, payment gateways, and coins.', route => '/membership' },
            { key => '3d', name => '3D Printing & Custom Fabrication', owner => '3D', description => 'Order 3D prints, upload design models, and track build queues.', route => '/3d' },
        );
        my ($found) = grep { $_->{key} eq $key } @defaults;
        if ($found) {
            $addon = {
                key          => $found->{key},
                name         => $found->{name},
                owner        => $found->{owner},
                description  => $found->{description},
                route        => $found->{route},
                monthly_cost => 0,
            };
        }
    }

    if ($c->req->method eq 'POST') {
        my $name         = $c->req->param('name') || '';
        my $owner        = $c->req->param('owner') || '';
        my $description  = $c->req->param('description') || '';
        my $route        = $c->req->param('route') || '';
        my $monthly_cost = $c->req->param('monthly_cost') || 0;

        try {
            $c->model('DBEncy')->resultset('SystemModule')->update_or_create(
                {
                    key          => $key,
                    name         => $name,
                    owner        => $owner,
                    description  => $description,
                    route        => $route,
                    monthly_cost => $monthly_cost,
                    is_active    => 1,
                },
                { key => 'primary' }
            );
            $c->flash->{success_msg} = "Add-on '$key' updated successfully!";
            return $c->res->redirect($c->uri_for('/membership/addons'));
        } catch {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_addon',
                "Failed to save SystemModule: $_");
            $c->stash->{error_msg} = "Failed to save addon: $_";
        };
    }

    $c->stash(
        addon    => $addon,
        template => 'admin/site_modules/edit_addon.tt',
    );
}

__PACKAGE__->meta->make_immutable;
1;
