package Comserv::Controller::Admin::EnvironmentVariables;

use Moose;
use namespace::autoclean;
use Try::Tiny;
use POSIX qw(strftime);
use JSON;
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

my %VAR_DESCRIPTIONS = (
    APP_MOUNT                              => 'Docker bind-mount path for the application source code',
    CATALYST_DEBUG                         => 'Enable Catalyst framework debug mode (1=on, 0=off)',
    CATALYST_ENV                           => 'Catalyst environment name (development, production, test)',
    CATALYST_HOME                          => 'Absolute path to the Catalyst application home directory inside the container',
    COMSERV_BACKUPS_PATH                   => 'Host path where database backups are stored',
    COMSERV_LOGS_PATH                      => 'Host path where application log files are written',
    COMSERV_SESSIONS_PATH                  => 'Host path where user session files are stored',
    COMSERV_DB_PRODUCTION_SERVER_HOST      => 'Production ENCY (ency) database server hostname/IP',
    COMSERV_DB_PRODUCTION_SERVER_PORT      => 'Production ENCY database server port',
    COMSERV_DB_PRODUCTION_SERVER_DATABASE  => 'Production ENCY database name',
    COMSERV_DB_PRODUCTION_SERVER_USERNAME  => 'Production ENCY database login username',
    COMSERV_DB_PRODUCTION_SERVER_PASSWORD  => 'Production ENCY database login password (secret)',
    COMSERV_DB_PRODUCTION_FORAGER_HOST     => 'Production Forager database server hostname/IP',
    COMSERV_DB_PRODUCTION_FORAGER_PORT     => 'Production Forager database server port',
    COMSERV_DB_PRODUCTION_FORAGER_DATABASE => 'Production Forager database name',
    COMSERV_DB_PRODUCTION_FORAGER_USERNAME => 'Production Forager database login username',
    COMSERV_DB_PRODUCTION_FORAGER_PASSWORD => 'Production Forager database login password (secret)',
    DB_HOST                                => 'Legacy: primary database host (use COMSERV_DB_* instead)',
    DB_HOST_PORT                           => 'Legacy: database host:port binding (use COMSERV_DB_* instead)',
    DB_HOST_PROD                           => 'Legacy: production database host (use COMSERV_DB_* instead)',
    DB_NAME                                => 'Legacy: primary database name (use COMSERV_DB_* instead)',
    DB_NAME_PROD                           => 'Legacy: production database name (use COMSERV_DB_* instead)',
    DB_PASS                                => 'Legacy: primary database password — SECRET (use COMSERV_DB_* instead)',
    DB_PASS_PROD                           => 'Legacy: production database password — SECRET (use COMSERV_DB_* instead)',
    DB_PORT                                => 'Legacy: primary database port (use COMSERV_DB_* instead)',
    DB_PORT_PROD                           => 'Legacy: production database port (use COMSERV_DB_* instead)',
    DB_USER                                => 'Legacy: primary database username (use COMSERV_DB_* instead)',
    DB_USER_PROD                           => 'Legacy: production database username (use COMSERV_DB_* instead)',
    MIGRATION_MYSQL_HOST                   => 'New MySQL Docker server host (192.168.1.20) — migration target',
    MIGRATION_MYSQL_PORT                   => 'New MySQL Docker server port (3307) — migration target',
    MIGRATION_MYSQL_USER                   => 'Root username for the new MySQL Docker server',
    MIGRATION_MYSQL_PASSWORD               => 'Root password for the new MySQL Docker server — SECRET',
    MIGRATION_POSTGRES_HOST                => 'New PostgreSQL Docker server host (192.168.1.20) — migration target',
    MIGRATION_POSTGRES_PORT                => 'New PostgreSQL Docker server port (5433) — migration target',
    MIGRATION_POSTGRES_USER                => 'Root username for the new PostgreSQL Docker server',
    MIGRATION_POSTGRES_PASSWORD            => 'Root password for the new PostgreSQL Docker server — SECRET',
    MYSQL_DATA_PATH                        => 'Host path for MySQL Docker data volume',
    NGINX_CACHE_PATH                       => 'Host path for Nginx cache files',
    NGINX_PORT                             => 'Nginx HTTP port exposed on the host',
    NGINX_SSL_PORT                         => 'Nginx HTTPS port exposed on the host',
    REDIS_DATA_PATH                        => 'Host path for Redis data persistence',
    REDIS_HOST                             => 'Redis cache server hostname (within Docker network)',
    REDIS_PASSWORD                         => 'Redis cache server authentication password — SECRET',
    REDIS_PORT                             => 'Redis cache server port',
    TZ                                     => 'Timezone for the container (e.g., UTC, America/Vancouver)',
    WEB_CPU_LIMIT                          => 'Docker: max CPU cores allocated to the web container',
    WEB_CPU_REQUEST                        => 'Docker: min CPU cores reserved for the web container',
    WEB_MEMORY_LIMIT                       => 'Docker: max memory allocated to the web container',
    WEB_MEMORY_REQUEST                     => 'Docker: min memory reserved for the web container',
    WEB_PORT                               => 'Port exposed by the Catalyst web container (not Nginx)',
);

my %GROUP_LABELS = (
    'COMSERV_DB_PRODUCTION'  => { label => 'Production DB Connections',        icon => 'fa-database',  order => 1 },
    'COMSERV_DB'             => { label => 'Custom DB Environments',            icon => 'fa-plus-circle', order => 2 },
    'MIGRATION'              => { label => 'Migration Target Servers',          icon => 'fa-server',    order => 3 },
    'DB'                     => { label => 'Legacy DB Variables (phase-out)',   icon => 'fa-exclamation-triangle', order => 4 },
    'REDIS'                  => { label => 'Redis Cache',                       icon => 'fa-memory',    order => 5 },
    'NGINX'                  => { label => 'Nginx Proxy',                       icon => 'fa-shield-alt', order => 6 },
    'CATALYST'               => { label => 'Catalyst Framework',                icon => 'fa-cog',       order => 7 },
    'COMSERV'                => { label => 'Application Paths & Config',        icon => 'fa-folder',    order => 8 },
    'WEB'                    => { label => 'Container Resource Limits',         icon => 'fa-microchip', order => 9 },
    'APP'                    => { label => 'Application Mount',                 icon => 'fa-hdd',       order => 10 },
    'OTHER'                  => { label => 'Other Variables',                   icon => 'fa-ellipsis-h', order => 99 },
);

sub _classify_var {
    my ($key) = @_;
    return 'COMSERV_DB_PRODUCTION' if $key =~ /^COMSERV_DB_PRODUCTION/;
    return 'COMSERV_DB'            if $key =~ /^COMSERV_DB_/;
    return 'MIGRATION'             if $key =~ /^MIGRATION_/;
    return 'DB'                    if $key =~ /^DB_/;
    return 'REDIS'                 if $key =~ /^REDIS_/;
    return 'NGINX'                 if $key =~ /^NGINX_/;
    return 'CATALYST'              if $key =~ /^CATALYST_/;
    return 'COMSERV'               if $key =~ /^COMSERV_/;
    return 'WEB'                   if $key =~ /^WEB_/;
    return 'APP'                   if $key =~ /^APP_/;
    return 'OTHER';
}

sub list : Path('/admin/environment_variables') : Args(0) {
    my ($self, $c) = @_;

    return unless $self->_require_admin($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list',
        'Admin accessed environment variables');

    my $env_vars = {};
    try { $env_vars = $self->env_manager->read_env_file() };

    my %groups;
    for my $key (sort keys %$env_vars) {
        my $group = _classify_var($key);
        push @{ $groups{$group} }, {
            key         => $key,
            value       => $env_vars->{$key},
            is_secret   => _is_secret($key),
            description => $VAR_DESCRIPTIONS{$key} // '',
            updated_at  => '',
            id          => $key,
        };
    }

    my @grouped = map {
        my $g = $_;
        {
            group_key  => $g,
            label      => $GROUP_LABELS{$g}{label},
            icon       => $GROUP_LABELS{$g}{icon},
            order      => $GROUP_LABELS{$g}{order},
            variables  => $groups{$g},
        }
    } sort { ($GROUP_LABELS{$a}{order}//99) <=> ($GROUP_LABELS{$b}{order}//99) } keys %groups;

    my @all_variables = map {
        {
            key        => $_,
            value      => $env_vars->{$_},
            is_secret  => _is_secret($_),
            updated_at => '',
            id         => $_,
        }
    } sort keys %$env_vars;

    $c->stash(
        env_variables  => \@all_variables,
        grouped_vars   => \@grouped,
        env_file_path  => $self->env_manager->env_path,
        success_msg    => $c->flash->{success_msg},
        error_msg      => $c->flash->{error_msg},
        template       => 'admin/environment_variables/list.tt',
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
            $ENV{$key} = $value;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create',
                "Created env var: $key");
            $c->flash->{success_msg} = "Variable '$key' created. Value is active immediately.";
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
            $ENV{$key} = $new_value;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit',
                "Updated env var: $key");
            $c->flash->{success_msg} = "Variable '$key' updated. Value is active immediately.";
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

sub set_single :Path('/admin/environment_variables/set_single') :Args(0) {
    my ($self, $c) = @_;

    $c->response->content_type('application/json; charset=utf-8');

    return unless $self->_require_admin($c);

    unless ($c->req->method eq 'POST') {
        $c->response->status(405);
        $c->response->body('{"error":"Method not allowed"}');
        return;
    }

    my $fh  = $c->req->body;
    my $raw = ref($fh) ? do { local $/; <$fh> } : ($fh // '{}');
    my $body  = eval { JSON::decode_json($raw) } // {};
    my $key   = $body->{key}   // '';
    my $value = $body->{value} // '';

    unless ($key =~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
        $c->response->status(400);
        $c->response->body(JSON::encode_json({ error => "Invalid variable name: '$key'" }));
        return;
    }

    my $result = eval {
        my $env_vars = $self->env_manager->read_env_file();
        $env_vars->{$key} = $value;
        $self->env_manager->write_env_file($env_vars);
        $ENV{$key} = $value;
        1;
    };

    if ($@ || !$result) {
        my $err = "$@"; $err =~ s/\n/ /g;
        $c->response->status(500);
        $c->response->body(JSON::encode_json({ error => "Save failed: $err" }));
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'set_single',
        "Set env var via modal: $key");

    $c->response->status(200);
    $c->response->body(JSON::encode_json({ success => 1, no_restart_needed => 1 }));
}

__PACKAGE__->meta->make_immutable;
1;
