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

sub get_models {
    my ($self, $c, %opts) = @_;

    my $can_select_model = $opts{can_select_model} || 0;

    # Local Ollama models (expand this list as needed)
    my $local_models = [
        { name => 'llama3.2', label => 'Llama 3.2 (Local Ollama)' },
        { name => 'llama3',   label => 'Llama 3 (Local Ollama)' },
        { name => 'gemma2',   label => 'Gemma 2 (Local Ollama)' },
        { name => 'phi3',     label => 'Phi 3 (Local Ollama)' },
    ];

    return {
        local         => $local_models,
        host          => 'localhost',
        port          => 11434,
        current_model => 'llama3.2',
    };
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
__PACKAGE__->meta->make_immutable;

1;