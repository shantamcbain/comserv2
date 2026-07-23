package Comserv::Model::AI::Chat;
use Moose;
use namespace::autoclean;
use Try::Tiny;
# Perl 5.40: namespace::autoclean strips imported try/catch; re-import after
# its BEGIN so the Try::Tiny idiom keeps working (perl-try-tiny-autoclean-debug).
INIT { Try::Tiny->import }
use JSON;
use Time::HiRes qw(time);
use DateTime;
use Comserv::Util::Logging;

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

=head1 NAME

Comserv::Model::AI::Chat - Core chat processing, routing, system prompts, and provider orchestration

=head1 DESCRIPTION

This is the heart of the AI chat system. The thin controller should call:

    my $result = $c->model('AI')->chat->process($c, %args);

It handles:
- Guest / authenticated user normalization
- System prompt assembly (roles, agents, live data, KB, page context, navigation)
- Provider selection (Ollama vs Grok vs Groq/OpenAI-compatible)
- Model tier selection / fallbacks
- Calling the provider
- Usage logging
- Conversation persistence
- Response normalization

=cut

=head2 process

Main entry point for the chat widget and /ai/chat endpoint.

    my $result = $chat->process($c,
        prompt            => $prompt,
        model             => $model,
        history           => \@history,
        conversation_id   => $conv_id,
        use_search        => $use_search,
        page_path         => $page_path,
        page_title        => $page_title,
        page_content      => $page_content,
        agent_id          => $agent_id,
        system            => $system,
        project_id        => $project_id,
        task_id           => $task_id,
    );

Returns a hashref suitable for JSON response:
    { success, response, model, conversation_id, thinking_trace, usage, ... }

=cut

sub process {
    my ($self, $c, %args) = @_;

    my $start_time = time();

    # --- Normalize user context ---
    my ($username, $user_id, $guest_session_id, $is_guest) = $self->_normalize_user($c);

    my $prompt            = $args{prompt}            // '';
    my $model             = $args{model}             // '';
    my $history           = $args{history}           // [];
    my $conversation_id   = $args{conversation_id};
    my $use_search        = $args{use_search} ? 1 : 0;
    my $page_path         = $args{page_path}         // '';
    my $page_title        = $args{page_title}        // '';
    my $page_content      = $args{page_content}      // '';
    my $agent_id          = $args{agent_id}          // '';
    my $agent_system      = $args{system}            // '';
    my $project_id        = $args{project_id};
    my $task_id           = $args{task_id};

    unless ($prompt && length($prompt) > 0) {
        return { success => JSON::false, error => 'Prompt is required' };
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process',
        "AI chat from $username: " . substr($prompt, 0, 80));

    # --- Permissions ---
    my $can_select = $self->_can_select_model($c);

    # --- Build messages ---
    my @messages = $self->_build_messages($history, $prompt);

    # --- Inject project/task context ---
    if ($project_id || $task_id) {
        my $ctx = $self->_get_project_context($c, $project_id, $task_id);
        $agent_system = ($agent_system ? "$agent_system\n\n" : '') . $ctx if $ctx;
    }

    # --- Agent-specific system prompts ---
    $agent_system = $self->_get_agent_system_prompt($c, $agent_id, $agent_system);

    # --- Role-based system prompt ---
    my $role_prompt = $self->_build_role_system_prompt($c, $can_select ? ['admin'] : [], $model);

    # --- Live module data (todos, workshops, etc.) ---
    my $module_data = $self->_get_module_data($c, $prompt, $agent_id);

    # --- Shared knowledge base hits ---
    my $site = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    my $shared = $self->_search_shared_history($c, $prompt, $site);

    # --- Current page content ---
    my $page_ctx = '';
    if ($page_content && length($page_content) > 20) {
        $page_ctx = "--- Current Page Content ---\n" . substr($page_content, 0, 4000) . "\n";
    }

    # --- Navigation hints (learned + static) ---
    my $nav_hint = $self->_build_navigation_hint($c, $page_path);

    # --- Assemble final system prompt ---
    my @system_parts;
    push @system_parts, $agent_system if $agent_system;
    push @system_parts, $role_prompt  if $role_prompt;
    push @system_parts, $module_data  if $module_data;
    push @system_parts, $shared       if $shared;
    push @system_parts, $page_ctx     if $page_ctx;
    push @system_parts, $nav_hint     if $nav_hint;

    my $system_prompt = join("\n\n", @system_parts);

    if ($system_prompt) {
        unshift @messages, { role => 'system', content => $system_prompt };
    }

    # --- Select provider + model ---
    my ($provider_name, $use_model) = $self->_select_provider_and_model($c, $model, $can_select);

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'process',
        "Using provider=$provider_name model=$use_model");

    # --- Call provider ---
    my $provider = $c->model('AI')->provider->get_client($c,
        provider => $provider_name,
        model    => $use_model,
    );

    unless ($provider) {
        return { success => JSON::false, error => "No client available for provider $provider_name" };
    }

    my $chat_start = time();
    my $resp = $provider->{chat}->(
        messages   => \@messages,
        use_search => $use_search,
    );
    my $chat_elapsed = sprintf('%.2f', time() - $chat_start);

    unless ($resp && $resp->{success}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'process',
            "Provider $provider_name failed: " . ($resp->{error} // 'unknown'));
        return {
            success => JSON::false,
            error   => $resp->{error} // "AI provider error",
        };
    }

    my $ai_response = $resp->{response} // '';
    my $final_model = $resp->{model} || $use_model;

    # --- Usage logging ---
    my $usage = $resp->{usage} || {};
    eval {
        $c->model('AI')->usage->log($c,
            user_id           => $user_id,
            site_id           => $c->session->{SiteID},
            guest_session_id  => $guest_session_id,
            provider          => $provider_name,
            model             => $final_model,
            prompt_tokens     => $usage->{prompt_tokens} // 0,
            completion_tokens => $usage->{completion_tokens} // 0,
            total_tokens      => $usage->{total_tokens} // 0,
            duration_ms       => int((time() - $start_time) * 1000),
            request_type      => 'chat',
            conversation_id   => $conversation_id,
            status            => 'success',
            ollama_host       => ($provider_name eq 'ollama' ? $c->model('Ollama')->host : undef),
        );
    };

    # --- Persist conversation ---
    my $new_conv_id;
    eval {
        $new_conv_id = $c->model('AI')->conversation->persist($c,
            username        => $username,
            conversation_id => $conversation_id,
            project_id      => $project_id,
            task_id         => $task_id,
            model           => $final_model,
            prompt          => $prompt,
            response        => $ai_response,
        );
    };
    $conversation_id = $new_conv_id if $new_conv_id;

    my $total_elapsed = sprintf('%.2f', time() - $start_time);

    return {
        success         => JSON::true,
        response        => $ai_response,
        model           => $final_model,
        provider        => $provider_name,
        conversation_id => $conversation_id,
        elapsed_sec     => $total_elapsed,
        usage           => $usage,
    };
}

# ----------------------------------------------------------------------
# Internal helpers (kept small and focused)
# ----------------------------------------------------------------------

sub _normalize_user {
    my ($self, $c) = @_;
    my $username = $c->session->{username};
    my $user_id  = $c->session->{user_id};
    my $guest    = $c->session->{guest_session_id};
    my $is_guest = 0;

    if (!$username) {
        $is_guest = 1;
        unless ($guest) {
            require Data::UUID;
            $guest = Data::UUID->new->create_str();
            $c->session->{guest_session_id} = $guest;
        }
        $user_id = 199;
        $username = "Guest-" . substr($guest, 0, 8);
    }
    return ($username, $user_id, $guest, $is_guest);
}

sub _can_select_model {
    my ($self, $c) = @_;
    my $roles = $c->session->{roles} || [];
    $roles = [split(/\s*,\s*/, $roles)] unless ref $roles;
    return grep { $_ =~ /^(admin|developer|editor)$/i } @$roles ? 1 : 0;
}

sub _build_messages {
    my ($self, $history, $prompt) = @_;
    my @msgs;
    if (ref($history) eq 'ARRAY') {
        for my $m (@$history) {
            next unless ref($m) eq 'HASH' && $m->{role} && $m->{content};
            push @msgs, { role => $m->{role}, content => $m->{content} };
        }
    }
    push @msgs, { role => 'user', content => $prompt };
    return @msgs;
}

sub _get_agent_system_prompt {
    my ($self, $c, $agent_id, $existing) = @_;
    return $existing if $existing;

    my $aid = lc($agent_id // '');
    my $meth = "_build_${aid}_system_prompt";
    if ($self->can($meth)) {
        return $self->$meth();
    }
    # Local minimal prompts (fully self-contained — no controller delegations)
    if ($aid eq 'helpdesk') {
        return "You are a helpful support agent for the Comserv system. Be concise and practical.";
    }
    if ($aid eq 'planning') {
        return "You are a planning assistant. Focus on daily logs, tasks, and clear next steps.";
    }
    if ($aid eq 'ency') {
        return "You are an encyclopedia assistant. Provide clear, factual answers.";
    }
    if ($aid eq 'bmaster') {
        return "You are a business master / project assistant. Be professional and concise.";
    }
    return '';
}

sub _build_role_system_prompt {
    my ($self, $c, $roles, $provider) = @_;
    my $r = (ref($roles) eq 'ARRAY' ? join(", ", @$roles) : $roles) || 'user';
    return "You are a helpful AI assistant in the Comserv application.\nUser roles: $r.\nBe accurate, concise, and respect permissions.";
}

sub _get_module_data {
    my ($self, $c, $prompt, $agent_id) = @_;
    $prompt   //= '';
    $agent_id //= '';

    my @sections;

    my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    my $today     = DateTime->today->ymd;

    # --- Workshop data ---
    if ($prompt =~ /workshop|class|course|session|seminar|event|beekeep/i) {
        eval {
            my ($workshops, $err) = $c->model('WorkShop')->get_active_workshops($c);
            if ($workshops && @$workshops) {
                my @visible;
                for my $ws (@$workshops) {
                    next unless !$ws->date || $ws->date ge $today;
                    my $share    = $ws->share    // '';
                    my $sitename = $ws->sitename // '';
                    next unless $share eq 'public' || lc($sitename) eq lc($site_name);

                    my $title    = $ws->title        // 'Untitled';
                    my $date     = $ws->date         // 'TBA';
                    my $location = $ws->location     // '';
                    my $desc     = $ws->description  // '';
                    $desc = substr($desc, 0, 120) . '…' if length($desc) > 120;

                    push @visible, "- $title | Date: $date"
                        . ($location ? " | Location: $location" : '')
                        . ($desc     ? " | $desc" : '');
                }
                if (@visible) {
                    push @sections,
                        "LIVE WORKSHOP DATA (current as of query time):\n"
                        . join("\n", @visible)
                        . "\nUsers can browse all workshops at /workshop";
                }
            }
        };
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            '_get_module_data', "Workshop fetch error: $@") if $@;
    }

    # --- Todo / Task data (with single-ID fast path + blockers) ---
    my $want_todos = ($prompt =~ /todo|task|overdue|due|deadline|priority|critical|reschedul|plan|backlog|block|proceed|prevent|stuck|hold/i)
                  || ($prompt =~ /project/i && $prompt =~ /state|status|progress|what|how|summar|complet|done|remain|left|next/i);

    my $page_path_req = $c->req->param('page_path') || '';
    if (!$page_path_req) {
        my $raw = eval { $c->req->content } // '';
        ($page_path_req) = ($raw =~ /"page_path"\s*:\s*"([^"]+)"/) if $raw;
    }
    my ($single_todo_id) = ($page_path_req =~ m{/todo/(?:details|view)[?&;](?:.*&)?record_id=(\d+)}i);

    if ($single_todo_id && $want_todos) {
        eval {
            my $schema = $c->model('DBEncy')->schema;
            if ($schema) {
                my $rs = $schema->resultset('Todo');
                my $t  = $rs->find($single_todo_id);
                if ($t) {
                    my $stat_label = ($t->status // 0) == 1 ? 'NEW'
                                   : ($t->status // 0) == 2 ? 'IN PROGRESS'
                                   : ($t->status // 0) == 3 ? 'DONE'
                                   : 'status=' . ($t->status // '?');
                    my $block = "CURRENT TODO #$single_todo_id:\n"
                        . "  Subject:  " . ($t->subject   // 'Untitled') . "\n"
                        . "  Status:   $stat_label\n"
                        . "  Priority: P" . ($t->priority // '?') . "\n"
                        . "  Due:      " . ($t->due_date  // 'none') . "\n"
                        . "  Project:  " . (do { my $pid = $t->project_id; $pid ? "id=$pid" : 'none' }) . "\n"
                        . "  Notes:    " . ($t->description // '') . "\n";

                    eval {
                        if ($t->can('blocker_id') && $t->blocker_id) {
                            my $blocker = $rs->find($t->blocker_id);
                            if ($blocker) {
                                $block .= "BLOCKING TODO #" . $t->blocker_id . ":\n"
                                    . "  Subject: " . ($blocker->subject // '') . "\n"
                                    . "  Status:  " . (($blocker->status // 0) == 2 ? 'IN PROGRESS' : ($blocker->status // 0) == 3 ? 'DONE' : 'NEW') . "\n";
                            }
                        }
                        my @blocked_by = $rs->search({ blocker_id => $single_todo_id, status => { '!=' => 3 } })->all;
                        if (@blocked_by) {
                            $block .= "TODOS BLOCKED BY THIS (#$single_todo_id):\n";
                            for my $b (@blocked_by) {
                                $block .= "  [#" . $b->record_id . "] " . ($b->subject // '') . "\n";
                            }
                        }
                    };
                    $block .= "Edit at /todo/edit?record_id=$single_todo_id | All todos: /todo";
                    push @sections, $block;
                }
            }
        };
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            '_get_module_data', "Single-todo fetch error: $@") if $@;
        $want_todos = 0;
    }

    if ($want_todos) {
        eval {
            my $schema = $c->model('DBEncy')->schema;
            if ($schema) {
                my $rs = $schema->resultset('Todo');

                my %proj_name;
                eval {
                    my $projects = $c->model('Project')->get_projects($schema, $site_name);
                    if ($projects) { $proj_name{$_->id} = $_->name for @$projects; }
                };

                my %site_filter = (status => { '!=' => 3 });
                my $roles = $c->session->{roles} || [];
                my $is_admin = grep { /^(admin|developer)$/i } (ref $roles eq 'ARRAY' ? @$roles : ());
                unless ($is_admin && lc($site_name) eq 'csc') {
                    $site_filter{sitename} = $site_name;
                }

                my $todo_row_cap = (lc($agent_id) eq 'planning') ? 20 : 40;
                my @todos = $rs->search(
                    \%site_filter,
                    { order_by => [{ -asc => 'priority' }, { -asc => 'due_date' }], rows => $todo_row_cap }
                );

                if (@todos) {
                    my (@overdue, @due_soon, @other);
                    for my $t (@todos) {
                        my $due  = $t->due_date   // '';
                        my $subj = $t->subject    // 'Untitled';
                        my $pri  = $t->priority   // 99;
                        my $proj_id = $t->project_id // '';
                        my $proj_label = $proj_id ? ($proj_name{$proj_id} ? "$proj_name{$proj_id} (#$proj_id)" : "#$proj_id") : '';
                        my $id   = $t->record_id  // '';
                        my $stat = $t->status     // '';
                        my $stat_label = $stat == 1 ? 'NEW' : $stat == 2 ? 'IN PROGRESS' : $stat == 3 ? 'DONE' : "status=$stat";
                        my $blocking_flag = ($stat == 2) ? " [IN PROGRESS - potential blocker]" : "";
                        my $line = "  [#$id] P$pri | $subj"
                            . ($due        ? " | Due: $due" : " | No due date")
                            . ($proj_label ? " | Project: $proj_label" : '')
                            . " | $stat_label$blocking_flag";

                        if ($due && $due lt $today) { push @overdue,  "OVERDUE $line"; }
                        elsif ($due)                 { push @due_soon, $line; }
                        else                         { push @other, $line; }
                    }

                    my $block = "LIVE TODO DATA (current as of query time) for site '$site_name':\n";
                    $block .= "OVERDUE ITEMS (need rescheduling or urgent action):\n" . join("\n", @overdue) . "\n" if @overdue;
                    $block .= "UPCOMING ITEMS:\n" . join("\n", @due_soon) . "\n" if @due_soon;
                    $block .= "OTHER ACTIVE ITEMS:\n" . join("\n", @other) . "\n" if @other;
                    $block .= "Browse all todos at /todo | View a specific todo at /todo/details?record_id=ID";
                    push @sections, $block;
                }
            }
        };
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            '_get_module_data', "Todo fetch error: $@") if $@;
    }

    # --- Project data ---
    if ($prompt =~ /project/i) {
        eval {
            my $schema = $c->model('DBEncy')->schema;
            if ($schema) {
                my $projects = $c->model('Project')->get_projects($schema, $site_name);
                if ($projects && @$projects) {
                    my @lines;
                    for my $p (@$projects) {
                        my $id = $p->id // ''; my $name = $p->name // 'Unnamed';
                        my $desc = substr($p->description // '', 0, 80) . '…';
                        push @lines, "  [ID=$id] $name" . ($desc ? " — $desc" : '');
                    }
                    push @sections,
                        "LIVE PROJECT DATA for site '$site_name':\n"
                        . join("\n", @lines)
                        . "\nView project details at /project/details?project_id=ID";
                }
            }
        };
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            '_get_module_data', "Project fetch error: $@") if $@;
    }

    return join("\n\n", @sections);
}

sub _search_shared_history {
    my ($self, $c, $prompt, $site_name) = @_;
    $prompt    //= '';
    $site_name //= '';
    return '' unless length($prompt) > 5;

    eval {
        my %seen_kw;
        my @keywords = grep { length($_) > 4 && !$seen_kw{lc $_}++ }
                       ($prompt =~ /(\b\w{5,}\b)/g);
        return '' unless @keywords;
        my @kw = @keywords[0 .. ($#keywords < 7 ? $#keywords : 7)];

        my $schema = $c->model('DBEncy')->schema;
        return '' unless $schema;

        my @conds = map { { 'me.content' => { -like => "%$_%" } } } @kw;
        my $user_msgs = $schema->resultset('AiMessage')->search(
            { 'me.role' => 'user', -or => \@conds },
            { order_by => { -desc => 'me.created_at' }, rows => 30, prefetch => 'conversation' }
        );

        my @pairs; my %seen_answer;
        while (my $q_msg = $user_msgs->next) {
            last if @pairs >= 3;
            my $q_content = $q_msg->content // '';
            next if length($q_content) < 5;
            my $score = grep { $q_content =~ /\Q$_\E/i } @kw;
            next if $score < 2;

            my $a_msg = $schema->resultset('AiMessage')->search(
                { conversation_id => $q_msg->conversation_id, role => 'assistant', id => { '>' => $q_msg->id } },
                { order_by => { -asc => 'id' }, rows => 1 }
            )->first;
            next unless $a_msg;
            my $answer = $a_msg->content // '';
            next if length($answer) < 20 || $seen_answer{substr($answer,0,80)}++;
            push @pairs, "Q: $q_content\nA: " . substr($answer, 0, 400);
        }
        return '' unless @pairs;
        return "RELEVANT PAST ANSWERS (shared KB):\n" . join("\n---\n", @pairs);
    };
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_search_shared_history', "History error: $@") if $@;
    return '';
}

sub _get_project_context {
    my ($self, $c, $pid, $tid) = @_;
    return '' unless $pid || $tid;

    my @parts;
    push @parts, "project_id=$pid" if $pid;
    push @parts, "task_id=$tid" if $tid;

    eval {
        my $schema = $c->model('DBEncy')->schema;
        if ($pid && $schema) {
            my $p = $schema->resultset('Project')->find($pid);
            push @parts, "Project: " . ($p ? $p->name : 'unknown') if $p;
        }
        if ($tid && $schema) {
            my $t = $schema->resultset('Todo')->find($tid);
            push @parts, "Task: " . ($t ? $t->subject : 'unknown') if $t;
        }
    };

    return @parts ? "--- Current Project/Task Context ---\n" . join("\n", @parts) . "\n" : '';
}

sub _build_navigation_hint {
    my ($self, $c, $page_path) = @_;
    $page_path //= '';
    return '' unless $page_path;

    my $base_url = '';
    eval { $base_url = $c->uri_for('/'); $base_url =~ s|/$||; };
    my $page_title = $c->stash->{page_title} || '';
    my $role = 'user';

    my $context_label = $page_title ? "\"" . $page_title . "\" ($page_path)" : $page_path;
    my $hint = "\n\nThe user is currently viewing: $context_label.\n";

    if ($page_path =~ m{/HelpDesk/ticket/new}i) {
        $hint .= "SUPPORT PRE-SCREENING MODE: Try to RESOLVE first (KB at $base_url/HelpDesk/kb). Provide actionable steps. Only suggest ticket if genuinely stuck.\n";
    } elsif ($page_path =~ m{/HelpDesk}i) {
        $hint .= "Navigation context — HelpDesk:\n- Submit: $base_url/HelpDesk/ticket/new\n- KB: $base_url/HelpDesk/kb\n";
    } elsif ($page_path =~ m{/todo}i) {
        $hint .= "Navigation context — Todo:\n- List: $base_url/todo/list\n- Details: /todo/details?record_id=ID\n";
    } elsif ($page_path =~ m{/project}i) {
        $hint .= "Navigation context — Projects:\n- List: $base_url/project/list\n";
    } elsif ($page_path =~ m{/workshop}i) {
        $hint .= "Navigation context — Workshops:\n- Active: $base_url/workshop/list_active\n";
    } elsif ($page_path =~ m{/Inventory/consignment}i) {
        $hint .= "Navigation context — Consignment: partners → new → settle\n";
    } elsif ($page_path =~ m{/Inventory}i) {
        $hint .= "Navigation context — Inventory + consignment\n";
    } elsif ($page_path =~ m{/Accounting}i) {
        $hint .= "Navigation context — Accounting dashboard + GL\n";
    } elsif ($page_path =~ m{/ency}i) {
        $hint .= "Navigation context — Encyclopedia: $base_url/ency/search?q=TERM\n";
    } elsif ($page_path =~ m{/ai}i) {
        $hint .= "Navigation context — AI Assistant (you are here)\n";
    }

    return $hint;
}

sub _select_provider_and_model {
    my ($self, $c, $requested_model, $can_select) = @_;

    my $prov = 'ollama';
    my $model = $requested_model || 'llama3.1:latest';

    # Grok / xAI models
    if ($requested_model && $requested_model =~ /^grok/i) {
        $prov = 'grok';
        $model = $requested_model;
        return ($prov, $model);
    }

    # If user selected something that looks like it needs an external key
    if ($requested_model && $requested_model =~ /^(gpt|claude|llama3|mixtral|groq)/i) {
        # Try to find a suitable provider key
        $prov = 'openai';  # will be resolved by Provider.pm to the right key
    }

    # Let the config + provider layer decide the actual host/model if local
    if ($prov eq 'ollama') {
        my ($host, $port, $cur_model) = $c->model('AI')->config->get_current_ollama_config($c, $can_select);
        $model ||= $cur_model;
    }

    return ($prov, $model);
}

# ----------------------------------------------------------------------
# System prompt builders (stubs / delegation points)
# These will be fully moved here in subsequent steps.
# ----------------------------------------------------------------------

sub _build_helpdesk_system_prompt { return "You are a helpful support agent for the Comserv system. Be concise and practical."; }
sub _build_ency_system_prompt     { return "You are an encyclopedia assistant. Provide clear, factual answers."; }
sub _build_bmaster_system_prompt  { return "You are a business master / project assistant. Be professional and concise."; }
sub _build_planning_system_prompt { return "You are a planning assistant. Focus on daily logs, tasks, and clear next steps."; }

1;

__PACKAGE__->meta->make_immutable;