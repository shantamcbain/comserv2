package Comserv::Model::AI;
use Moose;
use namespace::autoclean;

extends 'Catalyst::Model';

# Facade / central entry point for all AI functionality.
# Thin controller should call methods on this model instead of implementing logic.

# We deliberately do NOT use has 'config' or has 'ai_config' because
# Catalyst::Component already provides a 'config' class/instance method,
# and Moose readers blow up with "string as HASH ref" when Catalyst
# calls ClassName->method during component registration.
#
# Instead we use a private slot + safe accessor methods that guard
# against being called on the bare class name.

sub ai_config {
    my $self = shift;
    # If called as Class->ai_config during loading, just give a fresh one
    return Comserv::Model::AI::Config->new unless ref $self;
    if (exists $self->{_ai_cfg} && $self->{_ai_cfg}) {
        return $self->{_ai_cfg};
    }
    require Comserv::Model::AI::Config;
    return $self->{_ai_cfg} = Comserv::Model::AI::Config->new;
}

# Backward compat for all the existing $c->model('AI')->config calls
sub config { shift->ai_config(@_) }

has 'provider' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        require Comserv::Model::AI::Provider;
        Comserv::Model::AI::Provider->new;
    },
);

has 'chat' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        require Comserv::Model::AI::Chat;
        Comserv::Model::AI::Chat->new;
    },
);

has 'conversation' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        require Comserv::Model::AI::Conversation;
        Comserv::Model::AI::Conversation->new;
    },
);

has 'knowledge_base' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        require Comserv::Model::AI::KnowledgeBase;
        Comserv::Model::AI::KnowledgeBase->new;
    },
);

has 'coding' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        require Comserv::Model::AI::Coding;
        Comserv::Model::AI::Coding->new;
    },
);

has 'access' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        require Comserv::Model::AI::Access;
        Comserv::Model::AI::Access->new;
    },
);

has 'usage' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        require Comserv::Model::AI::Usage;
        Comserv::Model::AI::Usage->new;
    },
);

has 'model_manager' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        require Comserv::Model::AI::ModelManager;
        Comserv::Model::AI::ModelManager->new;
    },
);

# Central role-based AI router (like OpenRouter but with membership levels,
# manual override for devs/admins, cost/speed/privacy balancing).
# Thin controllers should call: $c->model('AI')->route(...)
has 'router' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        require Comserv::Model::AI::Router;
        Comserv::Model::AI::Router->new;
    },
);

# Public delegation method for controllers
sub route {
    my ($self, $c, %args) = @_;
    return $self->router->route_request($c, %args);
}

# Convenience delegation methods (controller can call $c->model('AI')->chat(...) etc.)
sub chat_message {
    my ($self, $c, %args) = @_;
    return $self->chat->process($c, %args);
}

sub get_conversations {
    my ($self, $c, %args) = @_;
    return $self->conversation->list($c, %args);
}

sub get_conversation_messages {
    my ($self, $c, $conv_id) = @_;
    return $self->conversation->get_messages($c, $conv_id);
}

sub log_usage {
    my ($self, $c, %args) = @_;
    return $self->usage->log($c, %args);
}

sub select_model {
    my ($self, $c, %args) = @_;
    return $self->chat->select_model($c, %args);
}

sub build_system_prompt {
    my ($self, $c, $agent_type, %args) = @_;
    return $self->chat->build_system_prompt($c, $agent_type, %args);
}

# Provider management
sub get_available_providers {
    my ($self, $c) = @_;
    return $self->provider->list_available($c);
}

sub get_current_config {
    my ($self, $c, $can_select_model) = @_;
    return $self->config->get_current_ollama_config($c, $can_select_model);
}

# === Safe model listing (the fix for the crashy UserApiKeys + metadata code) ===


sub get_available_models {
    my ($self, $c, %opts) = @_;

    # Delegate to Router or ModelManager
    my $router_result = $self->router ? $self->router->get_models($c, %opts) : {};

    return {
        local   => $router_result->{local} || [],
        host    => $router_result->{host} || 'localhost',
        port    => $router_result->{port} || 11434,
        current_model => $router_result->{current} || 'llama3',
    };
}

__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 NAME

Comserv::Model::AI - Central facade for all AI functionality

=head1 DESCRIPTION

This model provides a thin, stable API for controllers.
All heavy logic lives in the sub-modules under Comserv::Model::AI::*

Controllers (AI.pm, AIAdmin.pm, Chat.pm, Coding.pm, etc.) should delegate here.

=cut