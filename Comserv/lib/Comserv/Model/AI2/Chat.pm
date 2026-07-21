package Comserv::Model::AI2::Chat;

use Moose;
use namespace::autoclean;

use Try::Tiny;
use JSON qw(encode_json decode_json);

use Comserv::Util::Logging;

extends 'Catalyst::Model';

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

# ===================================================================
# AI2::Chat — role-aware chat brain (v2).
#
# Ported from v1 Model::AI::Chat::process: assembles a system prompt from
# role + agent + page/navigation context, selects provider+model via the v2
# Router, and calls the provider through v1 Model::AI::Provider (reused, not
# duplicated). Keeps Catalyst MVC discipline: this is business logic only.
# ===================================================================

# Role-based system prompt. $roles is an arrayref; admin/dev get the
# "you may use tools / internal data" flavor. Mirrors v1 _build_role_system_prompt.
sub build_role_prompt {
    my ($self, $c, $roles, $model) = @_;
    $roles //= [];
    $roles = [split(/\s*,\s*/, $roles)] unless ref $roles;

    my $is_priv = grep { $_ =~ /^(admin|developer|editor)$/i } @$roles;

    if ($is_priv) {
        return "You are the Comserv AI assistant. The user is a privileged "
             . "member (admin/developer). You may reference internal site "
             . "structure, configuration, and help them navigate or administrate. "
             . "Be concise and practical.";
    }
    return "You are the Comserv AI assistant. Help the user navigate the site, "
         . "fill in forms, and answer questions about Comserv services. Be "
         . "concise, friendly, and practical. Do not expose internal admin "
         . "details.";
}

# Agent-specific prompts (reused verbatim from v1 local prompts).
sub build_agent_prompt {
    my ($self, $c, $agent_id, $existing) = @_;
    return $existing if $existing;

    my $aid = lc($agent_id // '');
    my %agent = (
        helpdesk => "You are a helpful support agent for the Comserv system. Be concise and practical.",
        ency     => "You are an encyclopedia assistant. Provide clear, factual answers.",
        bmaster  => "You are a business master / project assistant. Be professional and concise.",
        planning => "You are a planning assistant. Focus on daily logs, tasks, and clear next steps.",
        code     => "You are a coding assistant. Help write, explain, and debug code. Prefer concise examples.",
        nav      => "You are a navigation assistant. Help the user find the right page or feature in Comserv.",
    );
    return $agent{$aid} if exists $agent{$aid};
    return undef;
}

# Assemble the full system prompt from all context parts.
sub build_system_prompt {
    my ($self, $c, %args) = @_;

    my @parts;
    push @parts, $args{agent_system}        if $args{agent_system};
    push @parts, $self->build_role_prompt($c, $args{roles}, $args{model}) if $args{roles};
    push @parts, $self->build_agent_prompt($c, $args{agent_id}, $args{agent_system}) if $args{agent_id};
    push @parts, $args{module_data}         if $args{module_data};
    push @parts, $args{shared_history}      if $args{shared_history};
    push @parts, $args{page_context}        if $args{page_context};
    push @parts, $args{navigation_hint}     if $args{navigation_hint};

    return join("\n\n", grep { defined && length } @parts);
}

# Build the message array (history + new prompt).
sub build_messages {
    my ($self, $history, $prompt) = @_;
    my @msgs;
    if (ref($history) eq 'ARRAY') {
        for my $m (@$history) {
            next unless ref($m) eq 'HASH' && $m->{role} && $m->{content};
            push @msgs, { role => $m->{role}, content => $m->{content} };
        }
    }
    push @msgs, { role => 'user', content => $prompt };
    return \@msgs;
}

# Select provider+model via the v2 Router (role/context-aware, local-first).
sub select_provider_and_model {
    my ($self, $c, $requested_model, $can_select, %ctx) = @_;
    my $router = $c->model('AI2::Router');
    return $router->select_model($c,
        requested_model => $requested_model,
        can_select      => $can_select,
        %ctx,
    );
}

# Main entry: run a chat turn. Returns { success, response, model, usage? }.
sub process {
    my ($self, $c, %args) = @_;

    my $prompt = $args{prompt} // '';
    return { success => 0, error => 'Prompt is required' } unless $prompt && length $prompt;

    my $username  = $c->session->{username}  || 'Guest';
    my $roles     = $c->session->{roles}     || [];
    my $can_select = $self->_can_select_model($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process',
        "AI2 chat from $username: " . substr($prompt, 0, 80));

    my $messages = $self->build_messages($args{history}, $prompt);

    my $system_prompt = $self->build_system_prompt($c,
        roles          => $roles,
        agent_id       => $args{agent_id},
        agent_system   => $args{system},
        model          => $args{model},
        module_data    => $args{module_data},
        shared_history => $args{shared_history},
        page_context   => $args{page_context},
        navigation_hint=> $args{navigation_hint},
    );
    unshift @$messages, { role => 'system', content => $system_prompt }
        if $system_prompt;

    # Select provider+model (v2 Router)
    my ($provider_name, $use_model) = $self->select_provider_and_model($c,
        $args{model}, $can_select,
        agent_id => $args{agent_id},
    );
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'process',
        "AI2 using provider=$provider_name model=$use_model");

    # Dispatch to the correct self-contained v2 provider client.
    my $dispatch = {
        ollama     => 'AI2::Provider::Ollama',
        grok       => 'AI2::Provider::Grok',
        openrouter => 'AI2::Provider::OpenRouter',
        external   => 'AI2::Provider::OpenRouter',   # openrouter-prefixed models
    };
    my $prov_class = $dispatch->{$provider_name} || 'AI2::Provider::Ollama';
    my $provider = try { $c->model($prov_class) } catch { undef };

    unless ($provider && $provider->can('chat')) {
        return { success => 0, error => "No client available for provider $provider_name" };
    }

    my ($ollama_host, $ollama_port) = ($c->config->{Ollama}{host} || '192.168.1.199',
                                      $c->config->{Ollama}{port} || 11434);

    my $resp = try {
        $provider->chat($c,
            messages => $messages,
            model    => $use_model,
            host     => $ollama_host,
            port     => $ollama_port,
        );
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'process',
            "Provider $provider_name threw: $_");
        undef;
    };

    unless ($resp && $resp->{success}) {
        return { success => 0, error => $resp->{error} // 'AI provider error' };
    }

    return {
        success  => 1,
        response => $resp->{response} // '',
        model    => $resp->{model} || $use_model,
        provider => $provider_name,
        usage    => $resp->{usage} || {},
    };
}

sub _can_select_model {
    my ($self, $c) = @_;
    my $roles = $c->session->{roles} || [];
    $roles = [split(/\s*,\s*/, $roles)] unless ref $roles;
    return grep { $_ =~ /^(admin|developer|editor)$/i } @$roles ? 1 : 0;
}

__PACKAGE__->meta->make_immutable;

1;
