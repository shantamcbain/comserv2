package Comserv::Model::AI2::Chat;

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)

use Try::Tiny;
use JSON qw(encode_json decode_json);
use Comserv::Model::AI::ConversationScope qw(is_guest_session ensure_guest_session_id conversation_owned_by_session);

use Comserv::Util::Logging;
use Comserv::Util::ModelCatalog;

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
        programming => "You are the AI Editor programming agent for Comserv2. Use loaded [FILE:] buffers; never claim no filesystem access. Plan then code only when phase is implement.",
        documentation => "You are the AI Editor documentation agent. Prefer docs/changelog/planning guidance; avoid code file rewrites unless asked.",
        analyze => "You are the AI Editor Analyze worker. Read loaded [FILE:] buffers and named paths only. Return root cause + short plan. Never rewrite files, never emit ## FIX / full-file patches, never ask the user to paste files already provided.",
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

    # Logged-in users can create HelpDesk tickets + todos from this same chat
    # (widget + editor). Ticket contract always applies (editor may file bugs).
    # Skip TodoCreate contract for AI Editor agents — they plan/analyze code,
    # and "create todos" in those prompts must not become a todo agent contract.
    my $uname = eval { $c->session->{username} } || '';
    require Comserv::Model::AI2::ChatIntent;
    my $editor_todo_skip = Comserv::Model::AI2::ChatIntent::is_editor_agent($args{agent_id});
    if ($uname && lc($uname) ne 'guest') {
        my $hd_contract = eval {
            require Comserv::Model::AI2::HelpDeskTicketCreate;
            my $hbrain = eval { $c->model('AI2::HelpDeskTicketCreate') };
            $hbrain = Comserv::Model::AI2::HelpDeskTicketCreate->new if !$hbrain || !ref $hbrain;
            $hbrain->chat_contract($c);
        };
        if ($@) {
            $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__,
                'build_system_prompt', "HelpDeskTicketCreate chat_contract failed: $@");
        }
        push @parts, $hd_contract if $hd_contract;

        if (!$editor_todo_skip) {
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

        my $inv_contract = eval {
            require Comserv::Model::AI2::InvoiceCreate;
            my $ibrain = eval { $c->model('AI2::InvoiceCreate') };
            $ibrain = Comserv::Model::AI2::InvoiceCreate->new if !$ibrain || !ref $ibrain;
            $ibrain->chat_contract($c);
        };
        if ($@) {
            $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__,
                'build_system_prompt', "InvoiceCreate chat_contract failed: $@");
        }
        push @parts, $inv_contract if $inv_contract;
    }

    # Positive-learning retrieval (proj #288): reuse what the app already knows
    # (documentation / planning / KB) so the model stops re-deriving it. Role +
    # branch gated; every snippet is labelled UNVERIFIED/INTERNAL by design —
    # nothing here is yet authoritative. Public callers never see INTERNAL.
    my $recall = eval {
        require Comserv::Model::AI2::KnowledgeRecall;
        my $brain = eval { $c->model('AI2::KnowledgeRecall') };
        $brain = Comserv::Model::AI2::KnowledgeRecall->new if !$brain || !ref $brain;
        my $q = defined $args{prompt} ? $args{prompt}
              : (defined $args{agent_system} ? $args{agent_system} : '');
        $brain->recall_block($c, query => $q, roles => $args{roles});
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__,
            'build_system_prompt', "KnowledgeRecall failed: $@");
    }
    push @parts, $recall if $recall && length $recall;

    # BRANCH/SITE CONTEXT (AISYSTEM §3d): the widget cannot see its own URL,
    # so the SERVER states which branch instance and SiteName it serves
    # (resolved from root/config/worktrees.json by port+sitename). Without
    # this the model says "I can't detect the port" even though the answer is
    # deterministic server-side.
    my $site_ctx = eval { $self->branch_context_block($c) };
    push @parts, $site_ctx if $site_ctx;

    return join("\n\n", grep { defined && length } @parts);
}

# Server-side branch context: "You are running on branch X (SiteName Y),
# coordination project #N". Resolved from worktrees.json; never guesses.
sub branch_context_block {
    my ($self, $c) = @_;
    my $rank = eval { $c->model('AI2::TodoRank') } or return '';
    my $bctx = $rank->branch_context($c) or return '';
    return '' unless $bctx->{branch};

    my $block = "RUNTIME CONTEXT (from the server — authoritative):\n"
             .  "- App instance / git branch: $bctx->{branch}\n"
             .  "- SiteName: " . ($rank->_sitename($c)) . "\n";
    $block .= "- Branch coordination project: #$bctx->{project_id}"
           .  ($bctx->{project_name} ? " ($bctx->{project_name})" : '') . "\n"
        if $bctx->{project_id};
    $block .= "When the user asks about 'this branch', they mean the instance above. "
           .  "Todos for this branch live under that project unless they say otherwise.";
    return $block;
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

    my @thinking;
    push @thinking, 'Received prompt (' . length($prompt) . ' chars)';
    push @thinking, 'agent_id=' . ($args{agent_id} // '(none)');

    # HelpDesk-ticket AGENT first — must beat TodoCreate when the prompt
    # mentions both "ticket" and "todo" (3180 / 6510 hijack).
    my $hd_hit = eval {
        require Comserv::Model::AI2::HelpDeskTicketCreate;
        my $hbrain = eval { $c->model('AI2::HelpDeskTicketCreate') };
        $hbrain = Comserv::Model::AI2::HelpDeskTicketCreate->new if !$hbrain || !ref $hbrain;
        $hbrain->try_chat_create($c,
            prompt    => $prompt,
            page_path => $args{page_path} || '',
        );
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'process',
            "HelpDeskTicketCreate try_chat_create threw: $@");
    }
    if ($hd_hit && $hd_hit->{handled}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process',
            'HelpDesk-ticket agent handled chat (no LLM)');
        push @thinking, 'Handled by HelpDesk-ticket agent (no LLM)';
        return {
            success       => 1,
            response      => $hd_hit->{response} // '',
            model         => $hd_hit->{model} // '(helpdesk-ticket-create)',
            provider      => $hd_hit->{provider} // 'ai2-helpdesk',
            ticket_action => $hd_hit->{ticket_action},
            thinking      => \@thinking,
        };
    }

    # Todo-create AGENT (in-chat job). Deterministic — does NOT use the
    # picker model. Free models invent a fake "Add" box; this runs next.
    # Skip for AI Editor agents (programming/coding/code/documentation).
    require Comserv::Model::AI2::ChatIntent;
    my $editor_todo_skip = Comserv::Model::AI2::ChatIntent::is_editor_agent($args{agent_id});
    my $todo_hit;
    if (!$editor_todo_skip) {
        $todo_hit = eval {
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
            push @thinking, 'Handled by Todo-create agent (no LLM)';
            return {
                success     => 1,
                response    => $todo_hit->{response} // '',
                model       => $todo_hit->{model} // '(todo-create)',
                provider    => $todo_hit->{provider} // 'ai2-todo',
                todo_action => $todo_hit->{todo_action},
                thinking    => \@thinking,
            };
        }
    }

    # Invoice-create AGENT. Same intercept as todos — draft only, never posts GL.
    my $inv_hit = eval {
        require Comserv::Model::AI2::InvoiceCreate;
        my $ibrain = eval { $c->model('AI2::InvoiceCreate') };
        $ibrain = Comserv::Model::AI2::InvoiceCreate->new if !$ibrain || !ref $ibrain;
        $ibrain->try_chat_create($c, prompt => $prompt);
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'process',
            "InvoiceCreate try_chat_create threw: $@");
    }
    if ($inv_hit && $inv_hit->{handled}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process',
            'Invoice-create agent handled chat (no LLM)');
        push @thinking, 'Handled by Invoice-create agent (no LLM)';
        return {
            success        => 1,
            response       => $inv_hit->{response} // '',
            model          => $inv_hit->{model} // '(invoice-create)',
            provider       => $inv_hit->{provider} // 'ai2-invoice',
            invoice_action => $inv_hit->{invoice_action},
            thinking       => \@thinking,
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
        push @thinking, 'Handled by Code-read agent (no LLM)';
        push @thinking, 'files_read=' . join(', ', @{ $read_hit->{files_read} || [] })
            if $read_hit->{files_read} && @{ $read_hit->{files_read} };
        return {
            success    => 1,
            response   => $read_hit->{response} // '',
            model      => $read_hit->{model} // '(code-read)',
            provider   => $read_hit->{provider} // 'ai2-coderead',
            files_read => $read_hit->{files_read} || [],
            thinking   => \@thinking,
        };
    }

    my $username  = $c->session->{username}  || 'Guest';
    my $roles     = $c->session->{roles}     || [];
    my $can_select = Comserv::Util::ModelCatalog->can_select_model($c);

    my $req_agent = $args{agent_id} // '';
    unless (Comserv::Util::ModelCatalog->agent_allowed($c, $req_agent)) {
        $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__, 'process',
            "Clamped disallowed agent_id='$req_agent' to general");
        $args{agent_id} = 'general';
    }

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
    push @thinking, "Dispatch: provider=$provider_name model="
        . ($use_model // '(router-default)') . " can_select=$can_select";

    # One dispatch+fallback path (chat widget and FocusTune share Router).
    # SuperGrok / OpenRouter (no auto-fill) fall back to :free then Ollama.
    # xAI grok auto-fills — not the same provider as SuperGrok.
    my $router = $c->model('AI2::Router');
    push @thinking, 'Calling provider (chat_with_fallback)...';
    my $resp = try {
        # use_search must be threaded to the provider: it is set by the widget
        # (local-chat.js) and parsed in AI2.pm, but was never forwarded past
        # this point, so Grok's search_parameters (Grok.pm) never fired.
        $router->chat_with_fallback($c, $provider_name, $use_model, $messages,
            ($args{use_search} ? (use_search => 1) : ()));
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'process',
            "Provider $provider_name threw: $_");
        push @thinking, "Provider threw: $_";
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
        my $public = eval { $c->model('AI2::Router')->_user_facing_error($resp->{error}) }
                  || 'The AI provider did not complete this turn. Try again or pick another model.';
        push @thinking, 'Provider failed: ' . ($resp->{error} // $public);
        return { success => 0, error => $public, thinking => \@thinking };
    }

    push @thinking, 'Provider responded'
        . ($resp->{provider} ? (" via " . $resp->{provider}) : '')
        . ($resp->{model} ? (" / " . $resp->{model}) : '');
    if ($resp->{fallback}) {
        push @thinking, 'Fell back from ' . ($resp->{fallback_from} // '?')
            . ' to ' . ($resp->{provider} // '') . '/' . ($resp->{model} // '');
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


    # ── Auto-enrich when in-app context is insufficient (Shanta 2026-09-14) ──
    # Public web search AND/OR same-origin linked pages (site nav audit).
    # Runs once per turn before persist. Controllers may not reload under -r;
    # this lives in the Model so a :4006 restart picks it up reliably.
    my $citations = [];
    if (!$args{_auto_enrich_done}) {
        my $roles_e = $c->session->{roles} || [];
        $roles_e = [ split(/\s*,\s*/, $roles_e) ] unless ref $roles_e;
        my $can_enrich = (grep { $_ =~ /^(admin|developer|editor)$/i } @$roles_e) ? 1 : 0;
        my $ai_ctrl = eval { $c->controller('AI') };
        my $quality = 'unknown';
        if ($ai_ctrl && $ai_ctrl->can('_assess_response_quality')) {
            $quality = $ai_ctrl->_assess_response_quality($resp->{response} // '', $prompt);
        }
        my $site_audit = ($prompt =~ /\b(navigate|navigation|crawl|audit|failed\s+links?|each\s+page|readable|theme|look and content|site and report|broken\s+links?)\b/i) ? 1 : 0;
        my $need = $can_enrich && $resp && $resp->{success}
            && ($quality eq 'poor' || $site_audit)
            && !$args{use_search};
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process',
            "auto_enrich check: can=$can_enrich quality=$quality site_audit=$site_audit need=$need");
        push @thinking, "auto_enrich: quality=$quality site_audit=$site_audit need=$need";
        if ($need) {
            my $extra = '';
            my $origin_host_early = eval { $c->req->uri->host } || 'workstation.local';
            my $prior_hits = eval { $self->_format_prior_web_search_hits($c, $prompt, $origin_host_early) } || '';
            if ($prior_hits) {
                $extra .= $prior_hits;
                push @thinking, 'prior learned search/audit hits injected';
            }
            # Same-origin linked pages (see beyond current page)
            my @hrefs;
            my $links = $args{page_links} || [];
            if (ref $links eq 'ARRAY') {
                for my $sec (@$links) {
                    next unless defined $sec;
                    while ($sec =~ m{(https?://[^\s]+|/[\w./\-]+)}g) {
                        push @hrefs, $1;
                    }
                }
            }
            my $pc = $args{page_content} || '';
            while ($pc =~ m{href=["']([^"']+)["']}gi) { push @hrefs, $1; }
            my %seen; my @fetch;
            my $origin_host = eval { $c->req->uri->host } || 'workstation.local';
            my $base = eval { $c->req->base->as_string } || "http://$origin_host/";
            $base =~ s{/$}{};
            for my $h (@hrefs) {
                next if $seen{$h}++;
                my $url = $h;
                $url = $base . $h if $h =~ m{^/};
                next unless $url =~ m{^https?://}i;
                # same host only
                next unless $url =~ m{https?://\Q$origin_host\E(?::\d+)?/}i
                         || $url =~ m{https?://(?:127\.0\.0\.1|localhost)(?::\d+)?/}i;
                next if $url =~ m{/ai/widget}i;
                push @fetch, $url;
                last if @fetch >= 6;
            }
            if (@fetch) {
                push @thinking, 'Fetching ' . scalar(@fetch) . ' same-origin pages for site context…';
                require LWP::UserAgent;
                require HTTP::Request;
                my $ua = LWP::UserAgent->new(timeout => 8, max_size => 400_000, max_redirect => 3);
                $ua->agent('Comserv-AI-SiteAudit/1.0');
                my $cookie = $c->req->header('Cookie') || '';
                my $bundle = "--- Same-origin pages (auto-fetched for site audit) ---\n"
                    . "NOTE: Shared header/nav/footer is normal. Judge each page by its MAIN content only.\n"
                    . "Do NOT claim all pages are identical just because chrome matches.\n";
                my %finger;
                for my $url (@fetch) {
                    my $req = HTTP::Request->new(GET => $url);
                    $req->header('Host' => $origin_host . ( ($c->req->uri->port && $c->req->uri->port !~ /^(80|443)$/) ? (':' . $c->req->uri->port) : '' ));
                    $req->header('Cookie' => $cookie) if length $cookie;
                    $req->header('Accept' => 'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8');
                    my $res = eval { $ua->request($req) };
                    if ($res && $res->is_success) {
                        my $html = $res->decoded_content // '';
                        my $ctype = $res->header('Content-Type') || '';
                        my $text = '';
                        if ($ctype =~ m{json}i || $html =~ /^\s*[\[{]/) {
                            $text = substr($html, 0, 4000);
                        } else {
                            $html =~ s{<script\b[^>]*>.*?</script>}{}gsi;
                            $html =~ s{<style\b[^>]*>.*?</style>}{}gsi;
                            # Drop shared chrome so pages are distinguishable
                            $html =~ s{<nav\b[^>]*>.*?</nav>}{}gsi;
                            $html =~ s{<header\b[^>]*>.*?</header>}{}gsi;
                            $html =~ s{<footer\b[^>]*>.*?</footer>}{}gsi;
                            my $main = '';
                            if ($html =~ m{<main\b[^>]*>(.*?)</main>}si) {
                                $main = $1;
                            } elsif ($html =~ m{id=["']content["'][^>]*>(.*)}si) {
                                $main = substr($1, 0, 20000);
                            } elsif ($html =~ m{class=["'][^"']*(?:main-content|page-content|content-area)[^"']*["'][^>]*>(.*)}si) {
                                $main = substr($1, 0, 20000);
                            } else {
                                $main = $html;
                            }
                            $main =~ s{<[^>]+>}{ }g;
                            $main =~ s{\s+}{ }g;
                            $main =~ s{^\s+|\s+$}{}g;
                            $text = substr($main, 0, 3500);
                        }
                        my $fp = substr($text, 0, 120);
                        $finger{$fp}++;
                        my $title = '';
                        if (($res->decoded_content // '') =~ m{<title[^>]*>(.*?)</title>}si) {
                            $title = $1;
                            $title =~ s{\s+}{ }g;
                            $title = substr($title, 0, 80);
                        }
                        $bundle .= "\n## $url\nHTTP " . $res->code
                            . (length $title ? " | title: $title" : '')
                            . " | main_chars=" . length($text) . "\n$text\n";
                        push @$citations, { url => $url, title => ($title || $url) };
                        push @thinking, "fetched OK $url main=" . length($text);
                        {
                            my $path_snip = eval { $c->req->uri->path } || '';
                            my $prompt_snip = $prompt // '';
                            $prompt_snip =~ s/\s+/ /g;
                            $prompt_snip = substr($prompt_snip, 0, 80);
                            my $aq = 'site_audit:' . (length($path_snip) ? $path_snip : $prompt_snip);
                            $self->_persist_web_search_hit($c,
                                query          => $aq,
                                result_title   => ($title || $url),
                                result_url     => $url,
                                result_snippet => substr($text, 0, 500),
                                full_content   => $text,
                                source_type    => 'web',
                            );
                        }
                    } else {
                        my $code = $res ? $res->code : 'err';
                        $bundle .= "\n## $url\nFAILED HTTP $code\n";
                        push @thinking, "fetch FAIL $url ($code)";
                        push @$citations, { url => $url, title => "FAILED $code" };
                        {
                            my $path_snip = eval { $c->req->uri->path } || '';
                            my $prompt_snip = $prompt // '';
                            $prompt_snip =~ s/\s+/ /g;
                            $prompt_snip = substr($prompt_snip, 0, 80);
                            my $aq = 'site_audit:' . (length($path_snip) ? $path_snip : $prompt_snip);
                            $self->_persist_web_search_hit($c,
                                query          => $aq,
                                result_title   => "FAILED $code",
                                result_url     => $url,
                                result_snippet => "FAILED HTTP $code",
                                source_type    => 'web',
                            );
                        }
                    }
                }
                my $unique = scalar keys %finger;
                $bundle .= "\n[fingerprint] unique main-content samples among successes: $unique / "
                    . scalar(@fetch) . "\n";
                push @thinking, "unique main fingerprints=$unique";
                $extra .= $bundle . "\n";
            }
            # Public web search
            if ($ai_ctrl && $ai_ctrl->can('_do_web_search')) {
                push @thinking, 'In-app answer incomplete or site-audit — auto web-search…';
                my ($search_ctx, $sp) = ('', '');
                eval { ($search_ctx, $sp) = $ai_ctrl->_do_web_search($c, $prompt, $args{agent_id} || 'general', \@thinking); };
                if ($@) {
                    push @thinking, "web-search threw: $@";
                } elsif ($search_ctx && length $search_ctx) {
                    push @thinking, "web-search via $sp";
                    $extra .= "\n--- Web search (auto) ---\n$search_ctx\n";
                    my $prompt_q = $prompt // '';
                    $prompt_q =~ s/\s+/ /g;
                    $prompt_q = substr($prompt_q, 0, 200);
                    my $parsed = 0;
                    while ($search_ctx =~ /^##\s*(.+?)\nURL:\s*(\S+)\n(.*?)(?=\n## |\nUse the above|\z)/msg) {
                        my ($wt, $wu, $ws) = ($1, $2, $3);
                        $ws =~ s/^\s+|\s+$//g;
                        $ws = substr($ws, 0, 500);
                        push @$citations, { url => $wu, title => ($wt || $wu) };
                        $self->_persist_web_search_hit($c,
                            query          => $prompt_q,
                            result_title   => ($wt || $wu),
                            result_url     => $wu,
                            result_snippet => (length($ws) ? $ws : ($wt || $wu)),
                            source_type    => 'web',
                        );
                        $parsed++;
                    }
                    if (!$parsed) {
                        while ($search_ctx =~ /^URL:\s*(\S+)/mg) {
                            my $wu = $1;
                            push @$citations, { url => $wu, title => $wu };
                            $self->_persist_web_search_hit($c,
                                query          => $prompt_q,
                                result_title   => $wu,
                                result_url     => $wu,
                                result_snippet => $wu,
                                source_type    => 'web',
                            );
                        }
                    }
                } else {
                    push @thinking, 'web-search returned no results';
                }
            }
            if (length $extra) {
                push @$messages, {
                    role => 'user',
                    content => "Additional context gathered automatically:\n$extra\n"
                        . "Answer the ORIGINAL user question first (what they asked — e.g. whether Chat-with-AI/Grok can audit the site, and how).
"
                        . "If this is a site audit: for EACH fetched URL, describe its MAIN content separately. "
                        . "Shared nav/header is normal — never conclude 'all pages are the homepage' from shared chrome. "
                        . "Use title + main_chars + body text. Report failed fetches (non-2xx) as failed links. "
                        . "Comment on readability and theme only from main content. Cite URLs.",
                };
                my $again = try {
                    $router->chat_with_fallback($c, $provider_name, $use_model, $messages,
                        ($args{use_search} ? (use_search => 1) : ()));
                } catch {
                    push @thinking, "enrich re-ask threw: $_";
                    undef;
                };
                if ($again && $again->{success} && length($again->{response} // '')) {
                    $resp = $again;
                    $provider_name = $again->{provider} if $again->{provider};
                    $use_model = $again->{model} if $again->{model};
                    push @thinking, 'Provider re-answered after auto_enrich';
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process',
                        'auto_enrich re-answer ok len=' . length($resp->{response} // ''));
                } else {
                    push @thinking, 'enrich re-ask failed — keeping first answer';
                }
            }
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
        my $is_guest = is_guest_session($c);
        my $uid = $c->session->{user_id};
        if ($is_guest) {
            $uid = 199 unless defined $uid;
        }
        die "No user_id for conversation persist\n" unless defined $uid;
        my $agent  = $args{agent_id} // 'general';
        my $gid = $is_guest ? ensure_guest_session_id($c) : '';

        # Create a new conversation only when none was supplied (first turn)
        unless ($conversation_id && $conversation_id =~ /^\d+$/) {
            $saved_title = $prompt ? substr($prompt, 0, 80) : 'Chat Conversation';
            $saved_title =~ s/\n/ /g;
            my %meta = (agent_id => $agent);
            $meta{guest_session_id} = $gid if $is_guest && length $gid;
            my $conv = $schema->resultset('AiConversation')->create({
                user_id    => $uid,
                title      => $saved_title,
                project_id => $args{project_id},
                task_id    => $args{task_id},
                model      => $resp->{model} // $use_model // '',
                status     => 'active',
                metadata   => encode_json(\%meta),
            });
            $conversation_id = $conv ? $conv->id : undef;
        } else {
            my $existing = $schema->resultset('AiConversation')->find($conversation_id);
            if ($existing) {
                unless (conversation_owned_by_session($c, $existing)) {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'process',
                        "Blocked persist into foreign conversation_id=$conversation_id");
                    $conversation_id = undef;
                }
            }
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
                metadata        => encode_json({ thinking_trace => \@thinking }),
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
                thinking_steps => scalar(@thinking),
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
        thinking        => \@thinking,
        files_read      => \@files_read,
        citations       => $citations || [],
    };
}


# ── WebSearchResult learn/persist helpers (aisystem 2026-09-14) ─────────────
# Non-fatal: never break chat if DB write/read fails.
sub _session_uid_for_wsr {
    my ($self, $c) = @_;
    my $uid = $c->session->{user_id};
    if (eval { is_guest_session($c) }) {
        $uid = 199 unless defined $uid;
    }
    return defined $uid ? $uid : 199;
}

sub _persist_web_search_hit {
    my ($self, $c, %h) = @_;
    eval {
        my $schema = $c->model('DBEncy')->schema;
        my $query  = substr($h{query} // '', 0, 500);
        my $url    = substr($h{result_url} // '', 0, 1000);
        return 0 unless length $query && length $url;
        my $title  = substr(($h{result_title} // $url), 0, 512);
        $title = $url unless length $title;
        my $snippet = $h{result_snippet} // '';
        $snippet = substr($snippet, 0, 65000);
        $snippet = '(empty)' unless length $snippet;

        # Light dedup: skip if same query+url already stored
        my $existing = $schema->resultset('WebSearchResult')->search(
            { result_url => $url, query => $query },
            { rows => 1, order_by => { -desc => 'id' } }
        )->single;
        return 0 if $existing;

        my %row = (
            query            => $query,
            result_title     => $title,
            result_url       => $url,
            result_snippet   => $snippet,
            source_type      => ($h{source_type} || 'web'),
            found_by_user_id => ($h{found_by_user_id} // $self->_session_uid_for_wsr($c)),
            is_verified      => 0,
        );
        if (defined $h{full_content} && length $h{full_content}) {
            $row{full_content} = substr($h{full_content}, 0, 100_000);
        }
        $schema->resultset('WebSearchResult')->create(\%row);
        1;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'process',
            "WebSearchResult persist failed: $@");
    }
}

sub _format_prior_web_search_hits {
    my ($self, $c, $prompt, $origin_host) = @_;
    my $out = '';
    eval {
        my $schema = $c->model('DBEncy')->schema;
        my @keywords;
        my %stop = map { $_ => 1 } qw(
            that this with from have what when where which about page site link
            http https navigate navigation audit report each content look theme
            failed links broken crawl readable whether
        );
        for my $w (split /\W+/, lc($prompt // '')) {
            next if length($w) < 4;
            next if $stop{$w};
            push @keywords, $w;
            last if @keywords >= 5;
        }
        my @or;
        for my $kw (@keywords) {
            my $like = '%' . $kw . '%';
            push @or,
                { query => { -like => $like } },
                { result_title => { -like => $like } },
                { result_url => { -like => $like } },
                { result_snippet => { -like => $like } };
        }
        if ($origin_host && length $origin_host) {
            push @or, {
                query      => { -like => 'site_audit:%' },
                result_url => { -like => '%' . $origin_host . '%' },
            };
        }
        return unless @or;
        my @rows = $schema->resultset('WebSearchResult')->search(
            { -or => \@or },
            { order_by => { -desc => 'created_at' }, rows => 8 }
        )->all;
        return unless @rows;
        $out = "--- Prior learned search/audit hits ---\n"
             . "NOTE: prior/learned findings from websearchresult. Reuse when relevant; "
             . "prefer live fetch when available.\n";
        for my $r (@rows) {
            my $created = $r->created_at;
            if (ref $created && $created->can('strftime')) {
                $created = $created->strftime('%Y-%m-%d %H:%M');
            }
            my $snip = $r->result_snippet // '';
            $snip = substr($snip, 0, 300);
            $out .= sprintf(
                "[prior] %s | %s\n  url: %s\n  query: %s\n  %s\n",
                $created // '',
                $r->result_title // '',
                $r->result_url // '',
                $r->query // '',
                $snip
            );
        }
        $out .= "\n";
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'process',
            "WebSearchResult prior load failed: $@");
        return '';
    }
    return $out;
}

sub _can_select_model {
    my ($self, $c) = @_;
    return Comserv::Util::ModelCatalog->can_select_model($c);
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
