package Comserv::Model::AI2::Chat;

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)

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

    # BMaster gets the full beekeeping-aware prompt (apiary schema, voice
    # inspection workflow, ACTION contract) — ported from v1 (2026-07-24).
    if ($aid eq 'bmaster') {
        my $p = eval { $c->model('AI2::Prompts')->build_bmaster($c) };
        return $p if $p;
    }

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
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process',
        "AI2 chat dispatch: user=$username provider=$provider_name model="
        . ($use_model // '(router-default)') . " can_select=$can_select");

    # Dispatch to the correct self-contained v2 provider client.
    my $dispatch = {
        ollama     => 'AI2::Provider::Ollama',
        grok       => 'AI2::Provider::Grok',
        supergrok  => 'AI2::Provider::Grok',
        openrouter => 'AI2::Provider::OpenRouter',
        external   => 'AI2::Provider::OpenRouter',   # openrouter-prefixed models
    };
    my $prov_class = $dispatch->{$provider_name} || 'AI2::Provider::Ollama';
    my $provider = try { $c->model($prov_class) } catch { undef };

    unless ($provider && $provider->can('chat')) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'process',
            "No client available for provider=$provider_name (class="
            . ($prov_class // 'undef') . ")");
        return { success => 0, error => "No client available for provider $provider_name" };
    }

    # For Ollama, resolve the first reachable workstation address (LAN vs
    # ZeroTier vs OLLAMA_HOST). Non-Ollama providers ignore host/port.
    my ($ollama_host, $ollama_port);
    if ($provider->can('resolve_host')) {
        ($ollama_host, $ollama_port) = $provider->resolve_host($c);
    }

    my $resp = try {
        $provider->chat($c,
            messages => $messages,
            model    => $self->_bare_model($use_model),
            host     => $ollama_host,
            port     => $ollama_port,
        );
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'process',
            "Provider $provider_name threw: $_");
        undef;
    };

    unless ($resp && $resp->{success}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'process',
            "Provider $provider_name failed: " . ($resp->{error} // 'AI provider error')
            . " (model=" . ($use_model // '?') . ", user=$username)");
        return { success => 0, error => $resp->{error} // 'AI provider error' };
    }

    # ── Persist conversation + messages (v2 parity with v1 /ai/chat) ──
    # Without this, no conversation_id is ever created, so the widget can
    # never "start a new conversation" and nothing is saved to history.
    my $conversation_id = $args{conversation_id};
    my $saved_title;
    my $created_at = '';
    try {
        my $schema = $c->model('DBEncy')->schema;
        my $uid    = $c->session->{user_id} // 199;
        my $agent  = $args{agent_id} // 'general';

        # Create a new conversation only when none was supplied (first turn)
        unless ($conversation_id && $conversation_id =~ /^\d+$/) {
            $saved_title = $prompt ? substr($prompt, 0, 80) : 'Chat Conversation';
            $saved_title =~ s/\n/ /g;
            my $conv = $schema->resultset('AiConversation')->create({
                user_id    => $uid,
                title      => $saved_title,
                project_id => $args{project_id},
                task_id    => $args{task_id},
                model      => $resp->{model} // $use_model // '',
                status     => 'active',
                metadata   => encode_json({ agent_id => $agent }),
            });
            $conversation_id = $conv ? $conv->id : undef;
        }

        if ($conversation_id) {
            # Share the id across widget + /ai page (mirrors v1)
            $c->session->{current_conversation_id} = $conversation_id;

            my $model_used = $resp->{model} // $use_model // '';
            # Attach voice recording file refs to the user message when this
            # turn came from a voice transcript. Stored in metadata JSON so the
            # conversation history / voice page can locate and replay the audio.
            my $user_meta;
            if ($args{audio_file_id} || $args{transcript_file_id}) {
                $user_meta = encode_json({
                    ($args{audio_file_id}      ? (audio_file_id      => int($args{audio_file_id}))      : ()),
                    ($args{transcript_file_id} ? (transcript_file_id => int($args{transcript_file_id})) : ()),
                    source => 'voice',
                });
            }
            $schema->resultset('AiMessage')->create({
                conversation_id => $conversation_id,
                user_id         => $uid,
                role            => 'user',
                content         => $prompt,
                agent_type      => $agent,
                model_used      => $model_used,
                ($user_meta ? (metadata => $user_meta) : ()),
            });
            $schema->resultset('AiMessage')->create({
                conversation_id => $conversation_id,
                user_id         => $uid,
                role            => 'assistant',
                content         => $resp->{response} // '',
                agent_type      => $agent,
                model_used      => $model_used,
            });
            $created_at = scalar(localtime);
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'process',
            "Failed to persist v2 conversation: $_");
        # Non-fatal: still return the AI response to the user.
    };

    return {
        success         => 1,
        response        => $resp->{response} // '',
        model           => $resp->{model} || $use_model,
        provider        => $provider_name,
        usage           => $resp->{usage} || {},
        conversation_id => $conversation_id,
        title           => $saved_title,
        created_at      => $created_at,
        thinking        => [],
    };
}

sub _can_select_model {
    my ($self, $c) = @_;
    my $roles = $c->session->{roles} || [];
    $roles = [split(/\s*,\s*/, $roles)] unless ref $roles;
    return grep { $_ =~ /^(admin|developer|editor)$/i } @$roles ? 1 : 0;
}

# The Router identifies external models as "provider|slug" (e.g.
# "openrouter|tencent/hy3"). Providers want the BARE slug ("tencent/hy3") —
# sending the prefixed form to OpenRouter returns HTTP 400 "not a valid model
# ID". This mirrors Router::_bare_model and MUST exist here too: process()
# calls $self->_bare_model(...), and Chat.pm extends Catalyst::Model (it does
# NOT inherit from Router), so without this the call dies with "Can't locate
# object method _bare_model". The enclosing try{} swallowed that exception and
# reported a misleading generic "OpenRouter provider error" instead.
sub _bare_model {
    my ($self, $model) = @_;
    return $model unless defined $model;
    $model =~ s/^[^|]+\|//;   # drop leading "provider|"
    return $model;
}

__PACKAGE__->meta->make_immutable;

1;
