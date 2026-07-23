package Comserv::Model::AI::Config;
use Moose;
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)
use Try::Tiny;
use Comserv::Util::Logging;

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

=head1 NAME

Comserv::Model::AI::Config - Configuration and host selection for AI providers

=head1 DESCRIPTION

Handles reading comserv.conf <Ollama> block, session overrides,
fallback logic, and determining the current active Ollama (or other) backend.

This is the single source of truth for "which host/port/model should we talk to right now".

=cut

=head2 get_current_ollama_config

    my ($host, $port, $model, $installed_models) = $config->get_current_ollama_config($c, $can_select_model);

Returns the effective Ollama connection details for the current request.

=cut

sub get_current_ollama_config {
    my ($self, $c, $can_select_model) = @_;

    # ── Single source of truth: comserv.conf <Ollama> block ──────────────────
    my $ollama_cfg      = $c->config->{Ollama} || {};
    my $primary_host    = $ollama_cfg->{host}          || '192.168.1.199';
    my $fallback_host   = $ollama_cfg->{fallback_host} || $primary_host;
    my $config_port     = $ollama_cfg->{port}          || 11434;

    # Never silently fall back to localhost — production Docker has no local Ollama.
    if ($fallback_host =~ /^(localhost|127\.0\.0\.1)$/i && $primary_host !~ /^(localhost|127\.0\.0\.1)$/i) {
        $fallback_host = $primary_host;
    }

    my $ollama = $c->model('Ollama');
    my $current_host  = $primary_host;
    my $current_port  = $config_port;
    my $current_model = 'llama3.1:8b';  # known good installed model on dev workstation
    my $installed_models = [];

    # Session override (admin/privileged users can switch host via /ai/models UI)
    if ($can_select_model && $c->session->{ollama_host}) {
        $current_host = $c->session->{ollama_host};
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__,
            'get_current_ollama_config', "Using session preferred host: $current_host");
    } else {
        # Try primary host; fall back to fallback_host if unreachable
        my $test = Comserv::Model::Ollama->new(
            host    => $primary_host,
            port    => $config_port,
            timeout => 3
        );
        if ($test && $test->check_connection()) {
            $current_host = $primary_host;
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__,
                'get_current_ollama_config', "Primary host $primary_host available");
        } elsif ($fallback_host ne $primary_host) {
            $current_host = $fallback_host;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                'get_current_ollama_config', "Primary host $primary_host unavailable, using fallback $fallback_host");
        } else {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                'get_current_ollama_config', "Ollama host $primary_host is not reachable");
        }
    }

    # Configure the ollama model with the determined host
    try {
        $ollama->set_host($current_host);
        $ollama->port($config_port);
        $current_port = $config_port;

        # Ollama model role does not expose ->model; use a sensible default
        $current_model ||= 'llama3.1:latest';

        # Quick connection check (uses 3s timeout via temporary UA)
        my $check_ollama = Comserv::Model::Ollama->new(
            host    => $current_host,
            port    => $config_port,
            timeout => 3
        );
        if ($check_ollama && $check_ollama->check_connection()) {
            my $models = $ollama->list_models();
            $installed_models = $models if $models && ref($models) eq 'ARRAY';
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__,
                'get_current_ollama_config',
                "Ollama configured: $current_host:$current_port, model: $current_model, installed: " . scalar(@$installed_models));
        } else {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                'get_current_ollama_config', "Ollama unavailable at $current_host - no local models available");
        }

    } catch {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'get_current_ollama_config', "Failed to configure Ollama: $_");
    };

    return ($current_host, $current_port, $current_model, $installed_models);
}

=head2 get_ollama_config_from_conf

Helper to just read the raw <Ollama> block without any runtime checks.

=cut

sub get_ollama_config_from_conf {
    my ($self, $c) = @_;
    return $c->config->{Ollama} || {};
}

# ============================================================
# Coding / Grok / Editor helpers (ported from old AI controller)
# These are now the single source of truth.
# Call via: $c->model('AI')->config->_project_root_path($c)
# ============================================================

sub _project_root_path {
    my ($self, $c) = @_;
    return $c->config->{home}
        || do { (my $p = __FILE__) =~ s{/lib/Comserv.*}{}; $p };
}

sub _grok_home {
    my ($self) = @_;
    if ($ENV{GROK_CLI_HOME} && -d $ENV{GROK_CLI_HOME}) {
        return $ENV{GROK_CLI_HOME};
    }
    if ($ENV{GROK_HOME} && -d $ENV{GROK_HOME}) {
        my $gh = $ENV{GROK_HOME};
        $gh =~ s{/.grok/?\z}{};
        return $gh;
    }
    if (-d '/home/shanta/.grok') {
        return '/home/shanta';
    }
    my $home = $ENV{HOME} || '';
    return $home if $home && -d "$home/.grok";
    return $home || '/home/shanta';
}

sub _grok_cli_api_key {
    my ($self, $c) = @_;
    return $ENV{XAI_API_KEY} if $ENV{XAI_API_KEY} && $ENV{XAI_API_KEY} =~ /\S/;
    my $cfg_key = $c->config->{grok_cli_xai_api_key} || $c->config->{xai_api_key};
    return $cfg_key if $cfg_key && $cfg_key =~ /\S/;

    my $user_id = $c->session->{user_id} || 0;
    return '' unless $user_id;

    try {
        my $schema = $c->model('DBEncy')->schema;
        my $key_obj = $schema->resultset('UserApiKeys')->search(
            { user_id => $user_id, service => 'grok', is_active => '1' },
            { rows => 1 }
        )->first;
        $key_obj ||= $schema->resultset('UserApiKeys')->search(
            { service => 'grok', is_active => '1' },
            { rows => 1 }
        )->first;
        return $key_obj ? ($key_obj->get_api_key() || '') : '';
    } catch {
        return '';
    };
}

sub _interactive_ws_available {
    my ($self, $c) = @_;
    my $host = lc( $c->req->uri->host || '' );
    $host =~ s/:\d+\z//;
    return 1 if $host =~ /workstation|172\.30\.131\.126/;
    return 1 if $c->config->{coding_interactive_ws};
    return 0;
}

sub _editor_enabled {
    my ($self, $c) = @_;
    return 0 unless $self->_is_shanta_editor($c);
    return 1 if $self->_is_dev_mode($c);
    return 1 if $c->config->{remote_code_editor};
    return 0;
}

sub _is_dev_mode {
    my ($self, $c) = @_;
    return 1 if $c->config->{developer_mode};
    return 1 if $ENV{CATALYST_DEBUG};
    my $hostname = eval {
        require Comserv::Util::SystemInfo;
        Comserv::Util::SystemInfo::get_server_hostname();
    } || '';
    return 1 if $hostname =~ /workstation|localhost/i;
    return 1 if ($ENV{SYSTEM_IDENTIFIER} || '') =~ /^(dev|development|workstation)/i;
    return 0;
}

sub _is_shanta_editor {
    my ($self, $c) = @_;
    eval {
        require Comserv::Util::AdminAuth;
        my $auth = Comserv::Util::AdminAuth->new();
        return 1 if $auth->is_csc_admin($c);
    };
    my $username = $c->session->{username} || ($c->user ? $c->user->username : '') || '';
    return 1 if lc($username) eq 'shanta';
    if ($self->_is_dev_mode($c)) {
        return 1 if $c->stash->{is_admin};
    }
    return 0;
}

1;
__PACKAGE__->meta->make_immutable;

__END__

=head1 USAGE (from thin controller)

    my $ai = $c->model('AI');
    my ($host, $port, $model, $installed) = $ai->config->get_current_ollama_config($c, $can_select);

Or via facade:

    my ($host, $port, $model, $installed) = $c->model('AI')->get_current_config($c, $can_select);

=cut
