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
        todo     => "You are the Comserv todo agent. When the user wants a todo created, the server already performs that job — confirm the result, do not invent a form.",
        code     => "You are a coding assistant for the Comserv2 Catalyst app. The server already loads source into [FILE:] blocks. NEVER say you lack filesystem access or ask the user to paste files. Load other sources with [READ_FILE: lib/...] (optional :START-END). Prefer concise examples and one fenced code block so Approve can apply it.",
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

    # Logged-in users can create todos from this same chat (widget + editor).
    my $uname = eval { $c->session->{username} } || '';
    if ($uname && lc($uname) ne 'guest') {
        my $contract = eval {
            require Comserv::Model::AI2::TodoCreate;
            my $brain = eval { $c->model('AI2::TodoCreate') };
            $brain = Comserv::Model::AI2::TodoCreate->new if !$brain || !ref $brain;
            $brain->chat_contract($c);
        };
        if ($@) {
            $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__,
                'build_system_prompt', "TodoCreate chat_contract failed: $@");
        }
        push @parts, $contract if $contract;
    }

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

    # Todo-create AGENT (in-chat job). Deterministic — does NOT use the
    # picker model. Free models invent a fake "Add" box; this runs first.
    my $todo_hit = eval {
        require Comserv::Model::AI2::TodoCreate;
        Comserv::Model::AI2::TodoCreate->new->try_chat_create($c,
            prompt    => $prompt,
            page_path => $args{page_path} || '',
        );
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'process',
            "TodoCreate try_chat_create threw: $@");
    }
    if ($todo_hit && $todo_hit->{handled}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process',
            'Todo-create agent handled chat (no LLM)');
        return {
            success     => 1,
            response    => $todo_hit->{response} // '',
            model       => $todo_hit->{model} // '(todo-create)',
            provider    => $todo_hit->{provider} // 'ai2-todo',
            todo_action => $todo_hit->{todo_action},
            thinking    => [],
        };
    }

    # Code-read AGENT. Hy3 invents "I have no filesystem access" — do not
    # send "can you read the files" to the picker model.
    my $read_hit = eval {
        require Comserv::Model::AI2::CodeRead;
        my $brain = eval { $c->model('AI2::CodeRead') };
        $brain = Comserv::Model::AI2::CodeRead->new if !$brain || !ref $brain;
        $brain->try_chat_read($c,
            prompt       => $prompt,
            page_path    => $args{page_path} || '',
            page_content => $args{page_content} || '',
        );
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'process',
            "CodeRead try_chat_read threw: $@");
    }
    if ($read_hit && $read_hit->{handled}) {
        return {
            success    => 1,
            response   => $read_hit->{response} // '',
            model      => $read_hit->{model} // '(code-read)',
            provider   => $read_hit->{provider} // 'ai2-coderead',
            files_read => $read_hit->{files_read} || [],
            thinking   => [],
        };
    }

    my $username  = $c->session->{username}  || 'Guest';
    my $roles     = $c->session->{roles}     || [];
    my $can_select = $self->_can_select_model($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process',
        "AI2 chat from $username: " . substr($prompt, 0, 80));

    # Editor coding agent: inject the open buffer INTO THE USER MESSAGE.
    # Hy3 ignores system-only context and says "paste the code".
    my @files_read;
    my $code_read;
    my $code_skip;
    my $uname = $c->session->{username} || '';
    my $code_ok = (lc($args{agent_id} // '') eq 'code')
        && $uname && lc($uname) ne 'guest';
    if ($code_ok) {
        $code_read = eval {
            require Comserv::Model::AI2::CodeRead;
            my $brain = eval { $c->model('AI2::CodeRead') };
            $brain = Comserv::Model::AI2::CodeRead->new if !$brain || !ref $brain;
            $brain;
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'process',
                "CodeRead init failed: $@");
            $code_read = undef;
        }
        if ($code_read) {
            my $prep = eval {
                $code_read->prepare_turn($c,
                    prompt       => $prompt,
                    page_path    => $args{page_path} || '',
                    page_content => $args{page_content} || '',
                );
            };
            if ($@) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'process',
                    "CodeRead prepare_turn threw: $@");
            }
            elsif ($prep) {
                $args{page_context} = $prep->{page_context} if $prep->{page_context};
                push @files_read, @{ $prep->{files_read} || [] };
                $code_skip = $prep->{skip};
                if ($prep->{user_files} && length $prep->{user_files}) {
                    $prompt .= "\n\n---\nThe server already loaded these files from disk. "
                        . "They ARE in this message. Never say you cannot see them or ask the user to paste.\n\n"
                        . $prep->{user_files};
                }
            }
        }
    }

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

    # One dispatch+fallback path (chat widget and FocusTune share Router).
    # SuperGrok / OpenRouter (no auto-fill) fall back to :free then Ollama.
    # xAI grok auto-fills — not the same provider as SuperGrok.
    my $router = $c->model('AI2::Router');
    my $resp = try {
        $router->chat_with_fallback($c, $provider_name, $use_model, $messages);
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'process',
            "Provider $provider_name threw: $_");
        undef;
    };

    unless ($resp && $resp->{success}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'process',
            "Provider $provider_name failed: " . ($resp->{error} // 'AI provider error')
            . " (model=" . ($use_model // '?') . ", user=$username)");
        eval {
            $c->model('AI')->log_usage($c,
                provider          => $provider_name,
                model             => $use_model || 'unknown',
                status            => 'error',
                error_message     => $resp->{error} // 'AI provider error',
                request_type      => 'chat',
            );
        };
        return { success => 0, error => $resp->{error} // 'AI provider error' };
    }

    if ($resp->{fallback}) {
        $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__, 'process',
            "Fell back from $resp->{fallback_from} ($resp->{original_error}) to "
            . ($resp->{provider} // '') . '/' . ($resp->{model} // ''));
        eval {
            $c->model('AI')->log_usage($c,
                provider          => $resp->{fallback_from} || $provider_name,
                model             => $resp->{original_model} || $use_model || 'unknown',
                status            => 'error',
                error_message     => $resp->{original_error} || 'credits exhausted, fell back',
                request_type      => 'chat',
                metadata          => { fallback_to => $resp->{provider} },
            );
        };
        $provider_name = $resp->{provider} if $resp->{provider};
        $use_model     = $resp->{model}     if $resp->{model};
    }

    # Coding agent: if the model asked [READ_FILE:], load and continue (bounded).
    if ($code_read && $resp && $resp->{success}) {
        my $loop = 0;
        my $max_fu = eval { $code_read->max_followups } || 2;
        while ($loop < $max_fu) {
            my $fu = eval { $code_read->follow_up_context($c, $resp->{response}, $code_skip) };
            if ($@) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'process',
                    "CodeRead follow_up_context threw: $@");
                last;
            }
            last unless $fu && $fu->{user_message};
            push @$messages, { role => 'assistant', content => $resp->{response} // '' };
            push @$messages, { role => 'user',      content => $fu->{user_message} };
            push @files_read, @{ $fu->{files_read} || [] };
            $code_skip = $fu->{skip} || $code_skip;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process',
                'CodeRead follow-up loaded: ' . join(', ', @{ $fu->{files_read} || [] }));
            my $again = try {
                $router->chat_with_fallback($c, $provider_name, $use_model, $messages);
            } catch {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'process',
                    "CodeRead follow-up provider threw: $_");
                undef;
            };
            last unless $again && $again->{success};
            $resp = $again;
            if ($resp->{provider}) { $provider_name = $resp->{provider}; }
            if ($resp->{model})     { $use_model     = $resp->{model}; }
            $loop++;
        }
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

    eval {
        my $usage_info = $resp->{usage} || {};
        $c->model('AI')->log_usage($c,
            provider          => $provider_name,
            model             => $resp->{model} || $use_model || 'unknown',
            prompt_tokens     => $usage_info->{prompt_tokens} || 0,
            completion_tokens => $usage_info->{completion_tokens} || 0,
            total_tokens      => $usage_info->{total_tokens} || 0,
            request_type      => 'chat',
            conversation_id   => $conversation_id,
            status            => 'success',
            metadata          => {
                agent_id      => $args{agent_id},
                ($resp->{fallback} ? (
                    fallback      => 1,
                    fallback_from => $resp->{fallback_from},
                ) : ()),
            },
        );
        # SuperGrok ≠ xAI grok. Only SuperGrok (prepaid, no auto-fill) trips the 80% alert.
        my $from = $resp->{fallback_from} || $provider_name || '';
        if ($from eq 'supergrok' || $provider_name eq 'supergrok') {
            $c->model('AI')->usage->maybe_alert_supergrok($c);
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'process',
            "Failed to record AI usage: $@");
    }

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
        files_read      => \@files_read,
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
