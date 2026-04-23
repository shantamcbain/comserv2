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

__PACKAGE__->meta->make_immutable;
1;
