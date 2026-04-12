package Comserv::Controller::Admin::EnvironmentVariables;

use Moose;
use namespace::autoclean;
use Try::Tiny;
use POSIX qw(strftime);
use Comserv::Util::Logging;
use Comserv::Util::AdminAuth;
use Comserv::Util::EnvFileManager;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has 'env_manager' => (
    is      => 'ro',
    default => sub { Comserv::Util::EnvFileManager->new }
);

my @SECRET_PATTERNS = qw(PASSWORD SECRET TOKEN KEY PASS);

sub _is_secret {
    my ($key) = @_;
    my $upper = uc($key);
    for my $pat (@SECRET_PATTERNS) {
        return 1 if index($upper, $pat) >= 0;
    }
    return 0;
}

sub _require_admin {
    my ($self, $c) = @_;
    my $admin_auth = Comserv::Util::AdminAuth->new();
    my $admin_type = $admin_auth->get_admin_type($c);
    unless ($admin_type && $admin_type ne 'none') {
        $c->flash->{error_msg} = 'Access denied. Administrator rights required.';
        $c->response->redirect($c->uri_for('/user/login'));
        $c->detach();
    }
    return 1;
}

sub list : Path('/admin/environment_variables') : Args(0) {
    my ($self, $c) = @_;

    return unless $self->_require_admin($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list',
        'Admin accessed environment variables');

    my $env_vars = {};
    try { $env_vars = $self->env_manager->read_env_file() };

    my @variables = map {
        {
            key        => $_,
            value      => $env_vars->{$_},
            is_secret  => _is_secret($_),
            updated_at => '',
            id         => $_,
        }
    } sort keys %$env_vars;

    $c->stash(
        env_variables => \@variables,
        env_file_path => $self->env_manager->env_path,
        success_msg   => $c->flash->{success_msg},
        error_msg     => $c->flash->{error_msg},
        template      => 'admin/environment_variables/list.tt',
    );
}

sub create : Path('/admin/environment_variables/create') : Args(0) {
    my ($self, $c) = @_;

    return unless $self->_require_admin($c);

    if ($c->req->method eq 'POST') {
        my $key   = $c->req->param('key')   // '';
        my $value = $c->req->param('value') // '';

        unless ($key =~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
            $c->stash(
                error_msg => 'Invalid variable name. Use letters, numbers, underscores only.',
                template  => 'admin/environment_variables/edit.tt',
                variable  => { key => $key, value => $value, is_secret => _is_secret($key), id => undef },
                is_edit   => 0,
            );
            return;
        }

        try {
            my $env_vars = $self->env_manager->read_env_file();
            $env_vars->{$key} = $value;
            $self->env_manager->write_env_file($env_vars);
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create',
                "Created env var: $key");
            $c->flash->{success_msg} = "Variable '$key' created. Restart the server/container for it to take effect.";
            $c->response->redirect($c->uri_for('/admin/environment_variables'));
        } catch {
            $c->stash(
                error_msg => "Error saving variable: $_",
                template  => 'admin/environment_variables/edit.tt',
                variable  => { key => $key, value => $value, is_secret => _is_secret($key), id => undef },
                is_edit   => 0,
            );
        };
        return;
    }

    $c->stash(
        variable => { key => '', value => '', is_secret => 0, id => undef },
        is_edit  => 0,
        template => 'admin/environment_variables/edit.tt',
    );
}

sub edit : Path('/admin/environment_variables/edit') : Args(1) {
    my ($self, $c, $key) = @_;

    return unless $self->_require_admin($c);

    my $env_vars = {};
    try { $env_vars = $self->env_manager->read_env_file() };

    unless (exists $env_vars->{$key}) {
        $c->flash->{error_msg} = "Variable '$key' not found.";
        $c->response->redirect($c->uri_for('/admin/environment_variables'));
        return;
    }

    if ($c->req->method eq 'POST') {
        my $new_value = $c->req->param('value') // '';
        try {
            $env_vars->{$key} = $new_value;
            $self->env_manager->write_env_file($env_vars);
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit',
                "Updated env var: $key");
            $c->flash->{success_msg} = "Variable '$key' updated. Restart the server/container for it to take effect.";
            $c->response->redirect($c->uri_for('/admin/environment_variables'));
        } catch {
            $c->stash(
                error_msg => "Error saving variable: $_",
                template  => 'admin/environment_variables/edit.tt',
                variable  => { key => $key, value => $env_vars->{$key}, is_secret => _is_secret($key), id => $key },
                is_edit   => 1,
            );
        };
        return;
    }

    $c->stash(
        variable => {
            key       => $key,
            value     => _is_secret($key) ? '' : $env_vars->{$key},
            is_secret => _is_secret($key),
            id        => $key,
        },
        is_edit  => 1,
        template => 'admin/environment_variables/edit.tt',
    );
}

sub delete : Path('/admin/environment_variables/delete') : Args(1) {
    my ($self, $c, $key) = @_;

    return unless $self->_require_admin($c);

    try {
        my $env_vars = $self->env_manager->read_env_file();
        if (exists $env_vars->{$key}) {
            delete $env_vars->{$key};
            $self->env_manager->write_env_file($env_vars);
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete',
                "Deleted env var: $key");
            $c->flash->{success_msg} = "Variable '$key' deleted.";
        } else {
            $c->flash->{error_msg} = "Variable '$key' not found.";
        }
    } catch {
        $c->flash->{error_msg} = "Error deleting variable: $_";
    };

    $c->response->redirect($c->uri_for('/admin/environment_variables'));
}

sub export : Path('/admin/environment_variables/export') : Args(0) {
    my ($self, $c) = @_;

    return unless $self->_require_admin($c);

    try {
        my $env_vars = $self->env_manager->read_env_file();
        my $content  = $self->env_manager->_generate_env_content($env_vars);
        $c->response->content_type('text/plain');
        $c->response->header('Content-Disposition' => 'attachment; filename=.env');
        $c->response->body($content);
    } catch {
        $c->flash->{error_msg} = "Error exporting .env file: $_";
        $c->response->redirect($c->uri_for('/admin/environment_variables'));
    };
}

__PACKAGE__->meta->make_immutable;
1;
