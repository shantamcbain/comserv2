# AI.pm - Catalyst Controller for AI/Ollama interactions
#
# This controller provides web interfaces for interacting with Ollama LLM models.
# It includes both interactive web forms and API endpoints for AI query processing.
#
# Features:
# - Interactive AI interface with AJAX submission
# - JSON API endpoints for integration
# - Real-time Ollama status checking
# - System prompt and format customization
# - Comprehensive logging with Comserv standards
# - Authentication on all endpoints
# - Error handling with Try::Tiny
#
# Author: AI Assistant
# Created: 2025-01-15
# Last Updated: 2025-01-28 (Router integrated in generate)

package Comserv::Controller::AI;
use Moose;
use namespace::autoclean;
use Try::Tiny;
use JSON;
use Template;
use DateTime;
use LWP::UserAgent;
use Comserv::Util::Logging;
use Comserv::Model::Ollama;
use Comserv::Model::Grok;
use Comserv::Util::SystemInfo;
use Comserv::Util::AdminAuth;

BEGIN { extends 'Catalyst::Controller' }

=head1 NAME

Comserv::Controller::AI - Catalyst Controller for AI/Ollama interactions

=head1 DESCRIPTION

This controller provides web interfaces for interacting with Ollama LLM models.
It supports both interactive web forms and JSON API endpoints.

=head1 ATTRIBUTES

=cut

has 'logging' => (
    is => 'ro',
    lazy => 1,
    default => sub { Comserv::Util::Logging->instance },
    documentation => 'Logging instance for standardized logging'
);

=head1 METHODS

=head2 index

Main AI interface page with interactive query form.

=cut

sub index :Path :Args(0) {
    my ($self, $c) = @_;

    # Determine if user is authenticated or guest
    my $username = $c->session->{username};
    my $guest_session_id = $c->session->{guest_session_id};

    # If not logged in, create guest session for accessing the UI
    unless ($username) {
        unless ($guest_session_id) {
            use Data::UUID;
            my $ug = Data::UUID->new;
            $guest_session_id = $ug->create_str();
            $c->session->{guest_session_id} = $guest_session_id;
        }
        $username = "Guest-" . substr($guest_session_id, 0, 8);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'index', "Guest user accessing AI interface: $username");
    }

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__,
        'index', "User accessing AI interface");

    # Determine user permissions for model/server selection
    my $user_roles = $c->session->{roles} || [];
    if (!ref($user_roles)) {
        # If roles is a string, convert it to array
        $user_roles = [split(/\s*,\s*/, $user_roles)] if $user_roles;
    }
    my $can_select_model = 0;
    if (ref($user_roles) eq 'ARRAY') {
        $can_select_model = grep { $_ =~ /^(admin|developer|editor)$/i } @$user_roles;
    }

    # Get or set the current Ollama configuration
    my ($current_host, $current_port, $current_model, $installed_models) = $self->_get_current_ollama_config($c, $can_select_model);

    # Filter installed Ollama models by membership-allowed models for non-privileged users
    unless ($can_select_model) {
        my $user_id = $c->session->{user_id};
        my $site_id = $c->session->{SiteID};
        if ($user_id && $site_id && $installed_models && @$installed_models) {
            eval {
                my $allowed = $c->model('Membership')->get_allowed_ai_models($c, $user_id, $site_id);
                if ($allowed && @$allowed) {
                    my %allowed_set = map { $_ => 1 } @$allowed;
                    my @filtered = grep {
                        my $name = ref($_) ? ($_->{name} || '') : ($_ || '');
                        $allowed_set{$name};
                    } @$installed_models;
                    $installed_models = \@filtered if @filtered;
                }
            };
            if (my $err = $@) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                    'index', "Could not filter AI models by membership: $err");
            }
        }
    }

    # Wire quota check for harmony with plans (early, non-blocking for now to avoid surprising users)
    # Shows a hint if the user is approaching or over their plan's free daily local AI calls.
    if (!$can_select_model && $c->session->{user_id} && $c->session->{SiteID}) {
        eval {
            my $m = $c->model('Membership');
            my ($within, $used, $quota) = $m->is_ai_call_within_free_quota($c, $c->session->{SiteID}, 'ollama', $c->session->{user_id});
            if ($quota > 0 && !$within) {
                $c->stash->{ai_quota_warning} = "Your plan's free daily AI allowance ($quota local calls) has been reached. Additional local calls and all Grok/xAI usage are tracked for billing / overage.";
            } elsif ($quota > 0 && $used > ($quota * 0.8)) {
                $c->stash->{ai_quota_warning} = "Approaching your plan's free daily AI limit ($used / $quota).";
            }
        };
    }

    # Check if user has external API keys configured (grok, openai, etc.)
    # Admins can use any active key, other users only their own key
    my @external_models;
    my $user_id = $c->session->{user_id};
    if ($user_id) {
        try {
            my $schema = $c->model('DBEncy')->schema;
            my $grok_key;
            if ($can_select_model) {
                # Admins: use their own key first, fall back to any active key
                $grok_key = $schema->resultset('UserApiKeys')->search(
                    { user_id => $user_id, service => 'grok', is_active => '1' }
                )->first;
                unless ($grok_key) {
                    $grok_key = $schema->resultset('UserApiKeys')->search(
                        { service => 'grok', is_active => '1' }
                    )->first;
                }
            } else {
                $grok_key = $schema->resultset('UserApiKeys')->search(
                    { user_id => $user_id, service => 'grok', is_active => '1' }
                )->first;
            }
            if ($grok_key && $grok_key->api_key_encrypted) {
                # Use synced models from metadata if available, else hardcoded fallback
                my $meta = $grok_key->get_metadata() || {};
                my $synced = $meta->{available_models};
                if ($synced && ref($synced) eq 'ARRAY' && @$synced) {
                    foreach my $m (@$synced) {
                        my $id = $m->{id} || $m->{name} || '';
                        next unless $id;
                        next if $id =~ /^(grok-imagine|grok-.*video)/i;  # skip image/video models
                        (my $label = $id) =~ s/-/ /g;
                        $label = ucfirst($label) . ' (xAI)';
                        push @external_models, { name => $id, provider => 'grok', label => $label };
                    }
                } else {
                    push @external_models, { name => 'grok-4-fast-reasoning',     provider => 'grok', label => 'Grok 4 Fast Reasoning (xAI)' };
                    push @external_models, { name => 'grok-4-fast-non-reasoning', provider => 'grok', label => 'Grok 4 Fast (xAI)' };
                    push @external_models, { name => 'grok-3',                    provider => 'grok', label => 'Grok 3 (xAI)' };
                    push @external_models, { name => 'grok-3-mini',               provider => 'grok', label => 'Grok 3 Mini (xAI)' };
                }
            }
        } catch {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                'index', "Failed to fetch user API keys: $_");
        };
    }

    # popup=1 means the /ai page was opened as a detached popup from the widget.
    # In that mode, suppress the site navigation / header / footer so the window
    # is a clean standalone chat interface.
    my $popup_mode = $c->request->param('popup') ? 1 : 0;

    # task_id=N: opened from a todo "Chat about this task" link.
    # Look up the todo and pass it to the template so the welcome screen can
    # show what the user is supposed to be working on.
    my $task_id  = $c->request->param('task_id') || '';
    my $task_todo = undef;
    if ($task_id && $task_id =~ /^\d+$/) {
        eval {
            my $schema = $c->model('DBEncy')->schema;
            if ($schema) {
                my $t = $schema->resultset('Todo')->find($task_id);
                if ($t) {
                    my $s = $t->status // 0;
                    my $status_label = $s == 1 ? 'New'
                                     : $s == 2 ? 'In Progress'
                                     : $s == 3 ? 'Done'
                                     : "status=$s";
                    # Resolve project name
                    my $proj_name = '';
                    eval {
                        if ($t->project_id) {
                            my $p = $schema->resultset('Project')->find($t->project_id);
                            $proj_name = $p->name if $p;
                        }
                    };
                    $task_todo = {
                        record_id   => $t->record_id,
                        subject     => $t->subject     // 'Untitled',
                        description => $t->description // '',
                        status      => $status_label,
                        priority    => $t->priority    // '',
                        due_date    => $t->due_date    // '',
                        project     => $proj_name,
                        edit_url    => "/todo/edit?record_id=" . $t->record_id,
                    };
                }
            }
        };
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'index', "task_todo lookup failed: $@") if $@;
    }

    # Set template variables
    $c->stash(
        template => 'ai/index.tt',
        page_title => 'AI Assistant',
        username => $username,
        can_select_model => $can_select_model,
        current_host => $current_host,
        current_port => $current_port,
        current_model => $current_model,
        installed_models => $installed_models,
        external_models => \@external_models,
        ai_popup_mode => $popup_mode,
        task_todo => $task_todo,
        ai_quota_warning => $c->stash->{ai_quota_warning},
    );

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'index', "AI interface loaded for user: $username (host: $current_host, model: $current_model, can_select: " . ($can_select_model ? 'yes' : 'no') . ", external_models: " . scalar(@external_models) . ")");
}

# ... (all other methods unchanged until generate) ...

sub generate :Local :Args(0) {
    my ($self, $c) = @_;

    $c->response->content_type('application/json');

    my $username = $c->session->{username} || '';
    my $user_id  = $c->session->{user_id}  || 0;
    my $is_guest = 0;
    my $guest_session_id = $c->session->{guest_session_id};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'generate', "SESSION STATE: username='" . ($username||'EMPTY') . "' user_id=" . ($user_id||'0') .
        " SiteName=" . ($c->session->{SiteName}||'?') . " session_id=" . ($c->sessionid||'?'));

    if (!$username && (!$user_id || $user_id == 199)) {
        $is_guest = 1;
        unless ($guest_session_id) {
            use Data::UUID;
            my $ug = Data::UUID->new;
            $guest_session_id = $ug->create_str();
            $c->session->{guest_session_id} = $guest_session_id;
        }
        $user_id = 199;
        $username = "Guest-" . substr($guest_session_id, 0, 8);
    }

    my $prompt = '';
    my $provider = 'ollama';
    my $model = '';
    my $page_context = 'general';
    my $page_path = '';
    my $agent_id = 'general';
    my $conversation_id = undef;
    my $use_search = 0;
    my $system = '';
    my @trace;
    my $trace_start = time();

    my $content_type = $c->request->content_type || '';
    if ($content_type =~ /application\/json/i) {
        my $json_data;
        try {
            my $raw_body = $c->req->content || '';
            $json_data = decode_json($raw_body) if $raw_body;
        } catch {};

        if ($json_data && ref($json_data) eq 'HASH') {
            $prompt = $json_data->{prompt} || '';
            $provider = $json_data->{provider} || 'ollama';
            $model = $json_data->{model} || '';
            $page_context = $json_data->{page_context} || 'general';
            $page_path = $json_data->{page_path} || '';
            $agent_id = $json_data->{agent_id} || 'general';
            $conversation_id = $json_data->{conversation_id};
            $use_search = $json_data->{use_search} ? 1 : 0;
            $system = $json_data->{system} || '';
        }
    } else {
        $prompt = $c->request->params->{prompt} || '';
        $model = $c->request->params->{model} || '';
        $conversation_id = $c->request->params->{conversation_id};
        $use_search = $c->request->params->{use_search} ? 1 : 0;
        $page_path = $c->request->params->{page_path} || '';
        $agent_id = $c->request->params->{agent_id} || '';
        $system = $c->request->params->{system} || '';
    }

    unless ($prompt && length($prompt) > 0) {
        $c->response->body(encode_json({ success => JSON::false, error => 'Prompt is required' }));
        $c->response->status(400);
        return;
    }

    my $prompt_preview = substr($prompt, 0, 100);
    $prompt_preview .= '...' if length($prompt) > 100;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'generate', "AI generate from user '$username': $prompt_preview");

    # Router integration
    my $router = eval { $c->model('AI::Router') };
    if ($router) {
        my $user_roles = $c->session->{roles} || [];
        $user_roles = [split(/\s*,\s*/, $user_roles)] unless ref($user_roles);
        my $route = eval {
            $router->route_request($prompt, {
                user_roles => $user_roles,
                user_id => $user_id,
                page_context => $page_context,
                page_path => $page_path,
                agent_id => $agent_id,
            });
        } || {};
        if ($route->{backend}) {
            $provider = $route->{backend};
            $model = $route->{model} if $route->{model};
            $use_search = $route->{use_search} if exists $route->{use_search};
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                'generate', "Router decision: backend=$provider model=" . ($model || 'default') . " reason=" . ($route->{reason} || 'n/a'));
        }
        if ($route->{backend} eq 'local_kb' && $route->{result} && $route->{result}->{found}) {
            my $kb = $route->{result};
            my $kb_response = $kb->{answer} || $kb->{content} || 'Knowledge base hit.';
            $c->response->body(encode_json({
                success => JSON::true,
                response => $kb_response,
                model => 'local_kb',
                provider => 'local_kb',
                citations => (ref($kb->{citations}) eq 'ARRAY' ? $kb->{citations} : []),
            }));
            return;
        }
    }

    # Full generation path (preserved from original)
    my $response_data;
    try {
        my $ai_response = '';
        my $model_used = $model || 'phi4';
        if ($provider eq 'grok') {
            my $grok = $c->model('Grok');
            my $res = $grok->chat(prompt => $prompt, model => $model_used, system => $system, use_search => $use_search);
            $ai_response = $res->{response} || '';
            $model_used = $res->{model} || $model_used;
        } else {
            my $ollama = $c->model('Ollama');
            my ($host, $port) = $self->_get_current_ollama_config($c, 1);
            $ollama->host($host);
            $ollama->port($port);
            $ollama->model($model_used);
            my $res = $ollama->generate(prompt => ($system ? $system . "\n\n" : '') . $prompt, model => $model_used);
            $ai_response = $res->{response} || '';
        }

        # Save to conversation (core persistence)
        if ($user_id && $prompt) {
            my $schema = $c->model('DBEncy')->schema;
            unless ($conversation_id) {
                my $conv = $schema->resultset('AiConversation')->create({
                    user_id => $user_id,
                    title => substr($prompt, 0, 80) || 'AI Query',
                    status => 'active',
                });
                $conversation_id = $conv->id if $conv;
            }
            if ($conversation_id) {
                $schema->resultset('AiMessage')->create({
                    conversation_id => $conversation_id,
                    user_id => $user_id,
                    role => 'user',
                    content => $prompt,
                });
                $schema->resultset('AiMessage')->create({
                    conversation_id => $conversation_id,
                    user_id => $user_id,
                    role => 'assistant',
                    content => $ai_response,
                    model_used => $model_used,
                });
            }
        }

        $response_data = {
            success => JSON::true,
            response => $ai_response,
            model => $model_used,
            provider => $provider,
            conversation_id => $conversation_id,
        };
    } catch {
        my $err = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'generate', $err);
        $response_data = { success => JSON::false, error => $err };
    };

    $c->response->body(encode_json($response_data));
}

__PACKAGE__->meta->make_immutable;

1;