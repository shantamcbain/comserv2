package Comserv::Model::AI::Router;

use Moose;
use namespace::autoclean;
use Try::Tiny;
use JSON qw(encode_json decode_json);
use Comserv::Util::Logging;

extends 'Catalyst::Model';

# Central role-based AI router (like OpenRouter but with membership levels,
# manual override for devs/admins, cost/speed/privacy balancing).
# Thin controllers should call via the facade: $c->model('AI')->route(...)

has 'logging' => (
    is => 'ro',
    lazy => 1,
    default => sub { Comserv::Util::Logging->instance },
);


sub route_request {
    my ($self, $c, %args) = @_;

    my $roles = $self->_normalize_roles($c->session->{roles} || []);
    my $task_type = $args{task_type} || 'general';

    # Quota / role gate
    unless ($self->_check_access($c, $roles, $task_type)) {
        return { error => 'Access denied or quota exceeded' };
    }

    # Manual override for devs/admins
    if ($args{manual_model} && grep { /^(developer|admin)$/i } @$roles) {
        return $self->_execute_provider($c, $args{manual_model}, \%args);
    }

    # Auto-route: score candidates
    my @providers = $self->_get_scored_providers($c, $roles, $task_type);

    for my $prov (@providers) {
        try {
            my $result = $self->_execute_provider($c, $prov, \%args);
            $self->_log_usage($c, $prov, $result);
            return $result;
        } catch {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'route_request',
                "Provider $prov failed: $_");
        };
    }

    # Ultimate fallback (local Ollama)
    return $self->_execute_provider($c, 'ollama', \%args);
}

# --- Helper methods (stubs / minimal implementations) ---
# These should be populated from existing logic in AI.pm / AIAdmin.pm / Membership model

sub _normalize_roles {
    my ($self, $roles) = @_;
    return [ map { lc($_) } @$roles ];
}

sub _check_access {
    my ($self, $c, $roles, $task_type) = @_;
    # TODO: integrate with Membership model quotas
    return 1;  # allow for now
}

sub _get_scored_providers {
    my ($self, $c, $roles, $task_type) = @_;
    # TODO: implement cost/speed/expertise/privacy scoring
    return ['ollama'];  # safe default
}

sub _execute_provider {
    my ($self, $c, $provider, $request) = @_;
    # TODO: dispatch to actual provider (Ollama, Grok, etc.)
    return { provider => $provider, result => 'not_implemented' };
}

sub _log_usage {
    my ($self, $c, $provider, $result) = @_;
    # TODO: integrate with Usage model
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'route_request',
        "Used provider: $provider");
}


# Provider registry with cost/speed/privacy metadata
sub get_provider_registry {
    my $self = shift;

    return {
        ollama => {
            name => 'Ollama (Local)',
            cost => 0,
            speed => 'medium',
            privacy => 'high',
            priority => 10,
        },
        grok => {
            name => 'Grok (xAI)',
            cost => 'medium',
            speed => 'high',
            privacy => 'medium',
            priority => 8,
        },
        openrouter => {
            name => 'OpenRouter',
            cost => 'low',
            speed => 'high',
            privacy => 'low',
            priority => 6,
        },
    };
}

# Enhanced get_models with provider support
sub get_models {
    my ($self, $c, %opts) = @_;

    my $can_select_model = $opts{can_select_model} || 0;
    my $registry = $self->get_provider_registry();

    my $local_models = [
        { name => 'llama3.2', label => 'Llama 3.2 (Local Ollama)', provider => 'ollama' },
        { name => 'llama3',   label => 'Llama 3 (Local Ollama)', provider => 'ollama' },
        { name => 'gemma2',   label => 'Gemma 2 (Local Ollama)', provider => 'ollama' },
    ];

    my $external_models = $can_select_model ? [
        { name => 'grok-4-fast-reasoning', label => 'Grok 4 Fast (xAI)', provider => 'grok' },
        { name => 'openrouter-mixtral', label => 'Mixtral via OpenRouter', provider => 'openrouter' },
    ] : [];

    return {
        local         => $local_models,
        external      => $external_models,
        host          => 'localhost',
        port          => 11434,
        current_model => 'llama3.2',
        registry      => $registry,
    };
}

# ======================================================================
# models() - Model management data for /ai/models page and dropdowns
# ======================================================================
# This method was extracted from Controller::AI to keep the controller thin.
# It returns installed Ollama models + server info with basic caching.
#
# Usage from facade: $c->model('AI')->models($c)
# ======================================================================

has '_models_cache' => (
    is      => 'rw',
    default => sub { {} },
);

has '_models_cache_time' => (
    is      => 'rw',
    default => sub { 0 },
);

sub models {
    my ($self, $c, %opts) = @_;

    my $cache_ttl = $opts{cache_ttl} // 30;   # seconds
    my $now = time();

    # Return cached data if still fresh
    if ($now - $self->_models_cache_time < $cache_ttl &&
        keys %{ $self->_models_cache })
    {
        return $self->_models_cache;
    }

    my $data;
    try {
        my $ollama = $c->model('Ollama');
        my $installed = [];

        # Guarded call with short timeout to avoid hanging the UI
        if ($ollama && $ollama->can('list_models')) {
            $installed = eval { $ollama->list_models() } || [];
        }

        $data = {
            installed_models => $installed,
            servers          => [{ host => 'localhost', port => 11434 }],
            last_updated     => $now,
        };

        # Update cache
        $self->_models_cache($data);
        $self->_models_cache_time($now);

    } catch {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'models',
            'Failed to fetch model list: ' . $_);
        $data = {
            installed_models => [],
            servers          => [{ host => 'localhost', port => 11434 }],
            error            => "$_",
        };
    };

    return $data;
}

# Legacy helper (kept for compatibility)
sub get_model_management_data {
    my ($self, $c) = @_;
    return $self->models($c);
}

# ----------------------------------------------------------------------
# Provider-specific listing helpers (for future thin-controller usage)
# ----------------------------------------------------------------------
sub list_grok_models {
    my ($self, $c, $api_key) = @_;
    return [] unless $api_key;
    require LWP::UserAgent;
    my $ua = LWP::UserAgent->new(timeout => 8);
    my $res = $ua->get('https://api.x.ai/v1/models',
        'Authorization' => "Bearer $api_key",
        'Content-Type'  => 'application/json',
    );
    return [] unless $res->is_success;
    my $data = decode_json($res->decoded_content);
    return $data->{data} || [];
}

sub list_ollama_models {
    my ($self, $c, $host, $port) = @_;
    $host ||= 'localhost';
    $port ||= 11434;
    require LWP::UserAgent;
    my $ua = LWP::UserAgent->new(timeout => 5);
    my $url = "http://$host:$port/api/tags";
    my $res = $ua->get($url);
    return [] unless $res->is_success;
    my $data = decode_json($res->decoded_content);
    return $data->{models} || [];
}

# ----------------------------------------------------------------------
# sync_models() – moved from Controller
# ----------------------------------------------------------------------
sub sync_models {
    my ($self, $c, $service) = @_;
    $service ||= 'grok';

    my $user_id = $c->session->{user_id};
    my $roles   = $c->session->{roles} || [];
    $roles = [split(/\s*,\s*/, $roles)] unless ref $roles;
    my $is_admin = grep { $_ =~ /^(admin|developer)$/i } @$roles;
    return { success => JSON::false, error => 'Admin access required' } unless $is_admin;

    my $schema = $c->model('DBEncy')->schema;
    my $key_obj = $schema->resultset('UserApiKeys')->search(
        { user_id => $user_id, service => $service, is_active => '1' }
    )->first
      || $schema->resultset('UserApiKeys')->search(
            { service => $service, is_active => '1' }
         )->first;

    return { success => JSON::false, error => "No active $service API key found" }
        unless $key_obj && $key_obj->api_key_encrypted;

    my $api_key = $key_obj->get_api_key() || '';
    return { success => JSON::false, error => "Failed to decrypt $service API key" }
        unless $api_key;

    my %endpoint = (
        grok   => 'https://api.x.ai/v1/models',
        openai => 'https://api.openai.com/v1/models',
    );
    my $url = $endpoint{lc $service};
    return { success => JSON::false, error => "Model sync not supported for $service" }
        unless $url;

    require LWP::UserAgent;
    my $ua = LWP::UserAgent->new(timeout => 10);
    my $res = $ua->get($url, Authorization => "Bearer $api_key");
    return { success => JSON::false, error => 'Provider API error: ' . $res->status_line }
        unless $res->is_success;

    my $models = decode_json($res->decoded_content)->{data} || [];
    # store in metadata if desired...
    return { success => JSON::true, models => $models, count => scalar(@$models) };
}

# ----------------------------------------------------------------------
# get_api_keys() helper (thin wrapper around DB)
# ----------------------------------------------------------------------
sub get_api_keys {
    my ($self, $c, $service) = @_;
    my $schema = $c->model('DBEncy')->schema;
    my $rs = $schema->resultset('UserApiKeys')->search(
        { ($service ? (service => $service) : ()), is_active => '1' },
        { order_by => 'service' }
    );
    return [ map { { service => $_->service, has_key => 1 } } $rs->all ];
}

__PACKAGE__->meta->make_immutable;

1;