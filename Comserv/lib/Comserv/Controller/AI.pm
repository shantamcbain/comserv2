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
# Last Updated: 2025-01-28

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
                    push @external_models, { name => 'grok-3-mini',               provider => 'grok', label => 'Grok 3 Mini (xAI)' };
                    push @external_models, { name => 'grok-3',                    provider => 'grok', label => 'Grok 3 (xAI)' };
                    push @external_models, { name => 'grok-4-0709',               provider => 'grok', label => 'Grok 4 (xAI)' };
                    push @external_models, { name => 'grok-4-fast-non-reasoning', provider => 'grok', label => 'Grok 4 Fast (xAI)' };
                    push @external_models, { name => 'grok-code-fast-1',          provider => 'grok', label => 'Grok Code Fast (xAI)' };
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
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
        'index', "AI interface loaded for user: $username (host: $current_host, model: $current_model, can_select: " . ($can_select_model ? 'yes' : 'no') . ", external_models: " . scalar(@external_models) . ")");
}

=head2 widget

Renders a self-contained, layout-free popup window for the chat widget.
Opened by the "expand to separate window" button so users can move the
chat to a second monitor without the page being obscured.  No site
navigation, header, or footer is included — the response is a complete
minimal HTML document.

=cut

sub widget :Local :Args(0) {
    my ($self, $c) = @_;

    my $username   = $c->session->{username} || 'Guest';
    my $theme_name = $c->stash->{theme_name}
                  || $c->session->{theme_name}
                  || 'default';

    # Render widget.tt directly — bypasses layout.tt wrapper entirely so the
    # popup window contains only the chat UI with no site navigation.
    my $template_path = $c->path_to('root')->stringify;
    my $tt = Template->new({
        INCLUDE_PATH => $template_path,
        ENCODING     => 'UTF-8',
    });

    my $from_path   = $c->request->param('from_path')  || '/';
    my $from_title  = $c->request->param('from_title') || '';
    my $resume_conv = $c->request->param('resume')     || '';

    my $vars = {
        username      => $username,
        theme_name    => $theme_name,
        widget_config => encode_json({
            from_path   => $from_path,
            from_title  => $from_title,
            resume_conv => $resume_conv,
        }),
    };

    my $output = '';
    unless ($tt->process('ai/widget.tt', $vars, \$output)) {
        $c->response->status(500);
        $c->response->content_type('text/plain');
        $c->response->body('Template error: ' . $tt->error());
        $c->detach;
        return;
    }

    $c->response->content_type('text/html; charset=UTF-8');
    $c->response->body($output);
    $c->detach;
}

=head2 generate

API endpoint for AI query processing. Returns JSON responses.

Parameters:
- prompt (required): User's question or prompt
- format (optional): Response format ('json' or default text)  
- system (optional): System prompt to set AI behavior

=cut

sub generate :Local :Args(0) {
    my ($self, $c) = @_;
    
    # Set response content type
    $c->response->content_type('application/json');
    
    # Determine if user is authenticated or guest
    my $username = $c->session->{username} || '';
    my $user_id  = $c->session->{user_id}  || 0;
    my $is_guest = 0;
    my $guest_session_id = $c->session->{guest_session_id};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'generate', "SESSION STATE: username='" . ($username||'EMPTY') . "' user_id=" . ($user_id||'0') .
        " SiteName=" . ($c->session->{SiteName}||'?') . " session_id=" . ($c->sessionid||'?'));

    # If not logged in, create guest session
    # Use user_id as primary auth check (consistent with get_user_providers)
    if (!$username && (!$user_id || $user_id == 199)) {
        $is_guest = 1;
        
        # Create a unique guest session ID if not already present
        unless ($guest_session_id) {
            use Data::UUID;
            my $ug = Data::UUID->new;
            $guest_session_id = $ug->create_str();
            $c->session->{guest_session_id} = $guest_session_id;
        }
        
        # Use guest user (ID 199) - created earlier
        $user_id = 199;
        $username = "Guest-" . substr($guest_session_id, 0, 8);
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
            'generate', "Guest user session created: $username (session: $guest_session_id)");
    } elsif (!$username && $user_id && $user_id != 199) {
        # user_id is set but username is missing — recover username from DB
        eval {
            my $user_rec = $c->model('DBEncy::User')->find($user_id);
            if ($user_rec && $user_rec->username) {
                $username = $user_rec->username;
                $c->session->{username} = $username;
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                    'generate', "Recovered missing username='$username' from DB for user_id=$user_id");
            }
        };
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__,
            'generate', "Authenticated user (recovered): username='$username' user_id=$user_id");
    } else {
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
            'generate', "Authenticated user: $username");
    }
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
        'generate', "Processing AI generate request");
    
    # Get parameters - handle JSON body
    my $prompt = '';
    my $format = '';
    my $system = '';
    my $provider = 'ollama';  # Default provider: ollama, grok, or deepseek
    my $model = '';           # Specific model name (used for Grok model selection)
    my $page_context = 'general';
    my $page_path = '';
    my $page_title = '';
    my $agent_id = 'general';
    my $agent_name = 'AI Assistant';
    my $conversation_id = undef;  # For continuing existing conversations
    my $use_search = 0;           # Grok web search toggle
    my $history_items = [];       # Conversation history messages from client
    my @trace;                    # Reasoning/thinking trace returned to client
    my $trace_start = time();
    
    # Check if request body is JSON
    my $content_type = $c->request->content_type || '';
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
        'generate', "Request content-type: '$content_type'");
    
    if ($content_type =~ /application\/json/i) {
        # For JSON requests, read body using most reliable method
        my $json_data;
        try {
            my $raw_body;
            
            # Try multiple methods to read body (most reliable first)
            if ($c->req->can('content')) {
                $raw_body = $c->req->content;
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                    'generate', "Using \$c->req->content method");
            } elsif ($c->req->can('body')) {
                my $body = $c->req->body;
                if (ref($body) && $body->can('seek')) {
                    seek($body, 0, 0);
                    $raw_body = do { local $/; <$body> };
                    seek($body, 0, 0);
                } else {
                    $raw_body = $body;
                }
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                    'generate', "Using \$c->req->body method");
            }
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'generate', "Raw body length: " . (defined $raw_body ? length($raw_body) : 'UNDEF') . ", first 200 chars: " . (defined $raw_body ? substr($raw_body, 0, 200) : 'N/A'));
            
            if ($raw_body && length($raw_body) > 0) {
                $json_data = decode_json($raw_body);
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                    'generate', "JSON parsed successfully: keys=" . join(', ', keys %$json_data) . ", prompt exists=" . (defined $json_data->{prompt} ? 'yes (len=' . length($json_data->{prompt}) . ')' : 'no'));
            } else {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
                    'generate', "No JSON body content received or body is empty");
            }
        } catch {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
                'generate', "Failed to read/parse JSON body: $_");
        };
        
        if ($json_data && ref($json_data) eq 'HASH') {
            $prompt = $json_data->{prompt} || '';
            $format = $json_data->{format} || '';
            $system = $json_data->{system} || '';
            $provider = $json_data->{provider} || 'ollama';
            $page_context = $json_data->{page_context} || 'general';
            $page_path = $json_data->{page_path} || '';
            $page_title = $json_data->{page_title} || '';
            $agent_id = $json_data->{agent_id} || 'general';
            $agent_name = $json_data->{agent_name} || 'AI Assistant';
            $conversation_id = $json_data->{conversation_id};
            $model = $json_data->{model} || '';
            $use_search = $json_data->{use_search} ? 1 : 0;
            $history_items = (ref($json_data->{history}) eq 'ARRAY') ? $json_data->{history} : [];
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'generate', "Extracted from JSON: prompt='" . substr($prompt, 0, 100) . "', provider='$provider', conversation_id=" . ($conversation_id || 'NEW') . ", use_search=$use_search");
        } else {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
                'generate', "JSON parsing resulted in no data or invalid hash");
        }
    } else {
        # Fall back to form/query parameters
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
            'generate', "Using form/query parameters (content-type: '$content_type')");
        
        $prompt = $c->request->params->{prompt} || '';
        $format = $c->request->params->{format} || '';
        $system = $c->request->params->{system} || '';
        $provider = $c->request->params->{provider} || 'ollama';
        $page_context = $c->request->params->{page_context} || 'general';
        $page_path = $c->request->params->{page_path} || '';
        $page_title = $c->request->params->{page_title} || '';
        $agent_id = $c->request->params->{agent_id} || 'general';
        $agent_name = $c->request->params->{agent_name} || 'AI Assistant';
        $conversation_id = $c->request->params->{conversation_id};  # May be undef if new conversation
    }
    
    # Fall back to session-stored conversation_id if not provided in request
    unless ($conversation_id) {
        $conversation_id = $c->session->{current_conversation_id};
        if ($conversation_id) {
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'generate', "Using session-stored conversation_id: $conversation_id");
        }
    }
    
    # DEBUG: Log conversation_id status
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
        'generate', "BEFORE_VALIDATION: conversation_id is " . (defined($conversation_id) ? "'$conversation_id'" : "undef"));
    
    # Validate prompt
    unless ($prompt && length($prompt) > 0) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'generate', "Empty prompt provided by user: $username");
        
        my $error_response = encode_json({
            success => JSON::false,
            error => 'Prompt is required'
        });
        $c->response->body($error_response);
        $c->response->status(400);
        return;
    }
    
    # Log the query with preview
    my $prompt_preview = substr($prompt, 0, 100);
    $prompt_preview .= '...' if length($prompt) > 100;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
        'generate', "AI query from user '$username': $prompt_preview");
    
    # Log request parameters for debugging
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
        'generate', "Request parameters - format: '$format', system: " . 
        (length($system) > 0 ? 'provided' : 'none'));
    
    # Normalize agent_type to database enum values
    # Normalize agent_type for dynamic storage (was database enum)
    my $normalized_agent_type = $agent_id || 'general';
    if ($agent_id && $agent_id =~ /^(documentation|helpdesk|ency|beekeeping|hamradio|chat|cleanup|cleanup-agent|docker|master-plan-updater|daily-audit|daily-plan-automator|master-plan-manager|daily-plans-generator|daily-plans|documentation-sync|main|MainAgent|planning|prompt-logging|general)$/i) {
        $normalized_agent_type = lc($agent_id);
        # Special case for MainAgent which is camelcase in enum
        $normalized_agent_type = 'MainAgent' if lc($agent_id) eq 'mainagent';
        # Preserve 'general' case
        $normalized_agent_type = 'general' if lc($agent_id) eq 'general';
    } elsif ($agent_id && $agent_id eq 'documentation-agent') {
        $normalized_agent_type = 'documentation';
    } else {
        $normalized_agent_type = $agent_id ? 'general' : 'general';
    }
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
        'generate', "Agent type normalization: agent_id=$agent_id -> normalized_agent_type=$normalized_agent_type");
    
    # Require login for external AI models (Grok etc.) before entering try block
    if (lc($provider) eq 'grok' && $is_guest) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'generate', "Guest user attempted to use Grok - login required");
        $c->response->body(encode_json({
            success => JSON::false,
            error => 'Please log in to use external AI models (Grok/xAI).'
        }));
        return;
    }

    # Compute admin permission for provider fallback
    my $user_roles_gen = $c->session->{roles} || [];
    if (!ref($user_roles_gen)) {
        $user_roles_gen = [split(/\s*,\s*/, $user_roles_gen)] if $user_roles_gen;
    }
    my $can_select_model_gen = 0;
    if (ref($user_roles_gen) eq 'ARRAY') {
        $can_select_model_gen = grep { $_ =~ /^(admin|developer|editor)$/i } @$user_roles_gen;
    }

    # Role-based capability injection into system prompt
    my $role_prompt = $self->_build_role_system_prompt($c, $user_roles_gen, $provider, $page_path, $page_title);
    if ($role_prompt && $system) {
        $system .= "\n\n" . $role_prompt;
    } elsif ($role_prompt) {
        $system = $role_prompt;
    }

    # Only admins/editors may use web search (costs money per call)
    unless ($can_select_model_gen) {
        $use_search = 0;
    }

    # --- Live DB data injection (same as /ai/chat) ---
    my $site_name_gen = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    my $module_data_gen = $self->_get_module_data($c, $prompt, $agent_id);
    if ($module_data_gen) {
        $system .= "\n\n" . $module_data_gen;
    }
    my $shared_hist_gen = $self->_search_shared_history($c, $prompt, $site_name_gen);
    if ($shared_hist_gen) {
        $system .= "\n\n" . $shared_hist_gen;
    }

    # --- Trace: initial context ---
    push @trace, sprintf("🧑 User: %s (%s) | Site: %s | Page: %s",
        $username,
        join(', ', ref($user_roles_gen) eq 'ARRAY' ? @$user_roles_gen : ($user_roles_gen || 'guest')),
        $c->stash->{SiteName} || $c->session->{SiteName} || '?',
        $page_path || '/'
    );
    push @trace, sprintf("🤖 Agent: %s | Provider: %s%s",
        $agent_id || 'general',
        $provider,
        $use_search ? ' + web search' : ''
    );
    push @trace, sprintf("💬 Prompt (%d chars)%s",
        length($prompt),
        @$history_items ? " | History: " . scalar(@$history_items) . " prior messages" : ""
    );
    push @trace, $module_data_gen
        ? sprintf("🗄️ DB data injected (%d chars) — todos/projects/ENCY matched keywords", length($module_data_gen))
        : "🗄️ No DB data injected (prompt didn't match todo/project/ENCY keywords)";
    push @trace, $shared_hist_gen
        ? sprintf("📚 Shared KB: found relevant past Q&A (%d chars)", length($shared_hist_gen))
        : "📚 Shared KB: no matching prior Q&A found";

    my $response_data;
    my $ollama_started = 0;
    my $model_used = 'unknown';
    my $active_ollama_host = '';
    my $pre_saved_user_msg = 0;  # set to 1 once user message is saved pre-Ollama

    # Clear progress file so the JS poller sees fresh steps for this request
    my $gen_progress_file = $self->_progress_file_path($c);
    if (open my $pfh, '>', $gen_progress_file) { close $pfh; }

    try {
        my $response;
        
        # Route to the appropriate provider
        if (lc($provider) eq 'grok') {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
                'generate', "Using Grok provider for query, user_id: $user_id");
            
            # Fetch API key from database (user's own key, or any active for admins)
            my $grok_api_key = '';
            try {
                my $schema = $c->model('DBEncy')->schema;
                my $key_obj = $schema->resultset('UserApiKeys')->search(
                    { user_id => $user_id, service => 'grok', is_active => '1' }
                )->first;
                if (!$key_obj && $can_select_model_gen) {
                    $key_obj = $schema->resultset('UserApiKeys')->search(
                        { service => 'grok', is_active => '1' }
                    )->first;
                }
                if ($key_obj && $key_obj->api_key_encrypted) {
                    $grok_api_key = $key_obj->get_api_key() || '';
                }
            } catch {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                    'generate', "Failed to fetch grok API key: $_");
            };

            unless ($grok_api_key) {
                die "No Grok API key found. Please add your xAI API key at /ai/manage_api_keys";
            }

            my $grok = $c->model('Grok');
            unless ($grok) {
                die "Failed to load Grok model";
            }
            $grok->api_key($grok_api_key);
            $grok->model($model) if $model;
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'generate', "Querying Grok API (model: " . $grok->model . ")");
            
            my @grok_messages = ({ role => 'system', content => $system || 'You are a helpful assistant.' });
            for my $h (@$history_items) {
                my $hrole    = ($h->{role} && $h->{role} eq 'assistant') ? 'assistant' : 'user';
                my $hcontent = $h->{content} || '';
                push @grok_messages, { role => $hrole, content => $hcontent } if $hcontent;
            }
            push @grok_messages, { role => 'user', content => $prompt };
            $response = $grok->chat(
                messages   => \@grok_messages,
                use_search => $use_search,
            );
            
            unless ($response) {
                my $error = $grok->last_error || 'Unknown error';
                # Auto-fallback: if model is deprecated (410/404), retry with grok-3-mini
                if ($error =~ /410|404|no longer available|not found/ && $grok->model ne 'grok-3-mini') {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                        'generate', "Model " . $grok->model . " unavailable, retrying with grok-3-mini");
                    $grok->model('grok-3-mini');
                    $response = $grok->chat(
                        messages   => \@grok_messages,
                        use_search => $use_search,
                    );
                }
                unless ($response) {
                    $error = $grok->last_error || $error;
                    die "Grok query failed: $error";
                }
            }
            
            $model_used = $response->{model} || $grok->model;
        } else {
            # Default to Ollama
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
                'generate', "Using Ollama provider for query");
            
            my $ollama = $c->model('Ollama');
            unless ($ollama) {
                die "Failed to load Ollama model";
            }
            
            # Configure with user's current settings
            my $user_roles = $c->session->{roles} || [];
            if (!ref($user_roles)) {
                $user_roles = [split(/\s*,\s*/, $user_roles)] if $user_roles;
            }
            my $can_select_model = 0;
            if (ref($user_roles) eq 'ARRAY') {
                $can_select_model = grep { $_ =~ /^(admin|developer|editor)$/i } @$user_roles;
            }
            my ($current_host, $current_port, $current_model, $installed_models) = $self->_get_current_ollama_config($c, $can_select_model);
            $active_ollama_host = $current_host;
            
            # ── 3-Tier model selection: start small, escalate if needed ─────────
            # Tier 1 = tier_small (fastest / lightest installed model)
            # Tier 2 = tier_large (escalated only if Tier-1 quality is poor)
            my ($tier_small, $tier_large) = $self->_pick_ollama_tier(
                $installed_models, $current_model, $agent_id, $page_context);
            my $manual_model = ($model && $can_select_model_gen) ? $model : '';
            my $use_model    = $manual_model || $tier_small;

            push @trace, sprintf("🔍 Tier selection: small=%s large=%s → using=%s%s",
                $tier_small, $tier_large, $use_model,
                $manual_model ? " (manual override)" : "");

            $ollama->host($current_host);
            $ollama->port($current_port) if $current_port;
            $ollama->model($use_model);
            $ollama->clear_endpoint;

            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                'generate', "Ollama Tier-1 host=$current_host model=$use_model agent=$agent_id");

            # Fast availability check (3-second timeout) before committing
            my $fast_check = Comserv::Model::Ollama->new(host => $current_host, port => $current_port || 11434, timeout => 3);
            unless ($fast_check && $fast_check->check_connection()) {
                die "Ollama is not reachable at $current_host. Please select an external AI model (Grok) or try again later.";
            }

            # ── Prefer in-memory models to avoid cold-start delays ──────────────
            # If the selected tier_small is NOT already loaded but another installed
            # model IS in RAM, use that one instead — zero cold-start cost.
            unless ($manual_model) {
                my $running = $fast_check->get_running_models() || [];
                if (@$running) {
                    my %in_mem;
                    for my $r (@$running) { $in_mem{$r->{name}} = 1 if $r->{name}; }
                    push @trace, "💾 In-memory: " . join(', ', sort keys %in_mem);
                    if (!$in_mem{$use_model}) {
                        my @inst_names = map { ref($_) ? ($_->{name} || '') : ($_ || '') } @$installed_models;
                        my ($preferred) = grep { $in_mem{$_} } ($tier_large, @inst_names);
                        if ($preferred) {
                            push @trace, "💾 Switched tier_small '$use_model' → '$preferred' (already in memory)";
                            $use_model = $preferred;
                            $ollama->model($use_model);
                        }
                    } else {
                        push @trace, "💾 '$use_model' already in memory — no cold-start needed";
                    }
                    # Renew keep_alive to prevent expiry race between /api/ps check and actual request
                    eval {
                        my $ping_ua  = LWP::UserAgent->new(timeout => 10);
                        my $ping_url = "http://$current_host:" . ($current_port || 11434) . "/api/generate";
                        my $ping_payload = encode_json({
                            model      => $use_model,
                            prompt     => '',
                            stream     => JSON::false,
                            keep_alive => '2h',
                        });
                        $ping_ua->post($ping_url, 'Content-Type' => 'application/json', Content => $ping_payload);
                        push @trace, "🔁 keep_alive renewed for '$use_model'";
                    };
                }
            }

            $ollama->timeout(300);

            # ── Pre-call: create conversation + save user prompt BEFORE Ollama ─
            # This guarantees the conversation record exists even if Ollama times out,
            # so /ai/conversations always shows a history of attempted queries.
            {
                my $pre_schema;
                eval { $pre_schema = $c->model('DBEncy')->schema; };
                if ($pre_schema && $user_id) {
                    eval {
                        # Validate conversation_id (must be numeric)
                        if ($conversation_id && $conversation_id !~ /^\d+$/) {
                            $conversation_id = undef;
                        }
                        unless ($conversation_id) {
                            my $title = substr($prompt, 0, 80);
                            $title =~ s/\n/ /g;
                            $title = 'AI Query' unless $title && length($title);
                            my $conv_meta = encode_json({
                                page_context     => $page_context,
                                page_path        => $page_path,
                                page_title       => $page_title,
                                agent_id         => $agent_id,
                                agent_name       => $agent_name,
                                created_from_widget => 1,
                                widget_version      => '2.0',
                                is_guest            => $is_guest ? 1 : 0,
                                guest_session_id    => $guest_session_id,
                            });
                            my $conv = $pre_schema->resultset('AiConversation')->create({
                                user_id  => $user_id,
                                title    => $title,
                                status   => 'active',
                                metadata => $conv_meta,
                            });
                            if ($conv && $conv->id) {
                                $conversation_id = $conv->id;
                                $c->session->{current_conversation_id} = $conversation_id;
                                push @trace, sprintf("💾 Conversation %d created", $conversation_id);
                            }
                        } else {
                            $c->session->{current_conversation_id} = $conversation_id;
                        }
                        if ($conversation_id) {
                            $pre_schema->resultset('AiMessage')->create({
                                conversation_id => $conversation_id,
                                user_id         => $user_id,
                                role            => 'user',
                                content         => $prompt,
                                agent_type      => $normalized_agent_type,
                                model_used      => 'pending',
                                metadata        => encode_json({
                                    format       => $format,
                                    page_context => $page_context,
                                    page_path    => $page_path,
                                    page_title   => $page_title,
                                }),
                                ip_address => $c->request->address,
                                user_role  => $c->session->{roles}
                                    ? join(',', @{$c->session->{roles}}) : 'user',
                            });
                            $pre_saved_user_msg = 1;
                            push @trace, "💾 User message saved pre-call";
                        }
                    };
                    if ($@) {
                        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                            'generate', "Pre-call DB save failed (non-fatal): $@");
                    }
                }
            }

            # Build message array once (reused across tiers)
            my @ollama_msgs;
            push @ollama_msgs, { role => 'system', content => $system } if $system;
            for my $h (@$history_items) {
                my $hrole    = ($h->{role} && $h->{role} eq 'assistant') ? 'assistant' : 'user';
                my $hcontent = $h->{content} || '';
                push @ollama_msgs, { role => $hrole, content => $hcontent } if $hcontent;
            }
            push @ollama_msgs, { role => 'user', content => $prompt };

            # ── Hard context budget: keep total input under ~12 000 chars (~3 000 tokens)
            # CPU Ollama prefill at ~46 tok/s: 3 000 tokens = ~65s — safe under 300s timeout.
            # Pass 1: trim history messages.  Pass 2: strip page_content from system.
            # Pass 3: hard-cap system prompt so it cannot alone exceed the budget.
            my $BUDGET_CHARS  = 12_000;
            my $SYS_MAX_CHARS =  8_000;  # system prompt hard cap (nav guide can be 30K+)
            my $raw_total_gen = 0;
            $raw_total_gen += length($_->{content} || '') for @ollama_msgs;
            if ($raw_total_gen > $BUDGET_CHARS) {
                push @trace, sprintf("⚠️ Context %d chars > %d budget — trimming history", $raw_total_gen, $BUDGET_CHARS);
                # Pass 1: cap each non-system message at 300 chars
                for my $msg (@ollama_msgs) {
                    next if ($msg->{role} || '') eq 'system';
                    my $len = length($msg->{content} || '');
                    if ($len > 300) {
                        $msg->{content} = substr($msg->{content}, 0, 300) . '…';
                    }
                }
                my $after_p1 = 0;
                $after_p1 += length($_->{content} || '') for @ollama_msgs;
                if ($after_p1 > $BUDGET_CHARS && @ollama_msgs && $ollama_msgs[0]{role} eq 'system') {
                    my $sys = $ollama_msgs[0]{content};
                    # Pass 2: strip page_content section
                    $sys =~ s/\n\n---[ ]Current Page Content.*$//s;
                    $ollama_msgs[0]{content} = $sys;
                    push @trace, "⚠️ Stripped page_content from system prompt (still over budget)";

                    # Pass 3: hard-cap system prompt to SYS_MAX_CHARS
                    if (length($sys) > $SYS_MAX_CHARS) {
                        $ollama_msgs[0]{content} = substr($sys, 0, $SYS_MAX_CHARS) . "\n[system prompt truncated to fit context budget]";
                        push @trace, sprintf("⚠️ System prompt truncated from %d to %d chars", length($sys), $SYS_MAX_CHARS);
                    }
                }
            }

            my $total_chars = 0;
            $total_chars += length($_->{content} || '') for @ollama_msgs;
            my $est_tokens  = int($total_chars / 4);
            push @trace, sprintf("📊 Input size: %d chars (~%d tokens) across %d messages | timeout=%ds",
                $total_chars, $est_tokens, scalar(@ollama_msgs), $ollama->timeout);
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                'generate', "Pre-request: model=$use_model msgs=" . scalar(@ollama_msgs) .
                " chars=$total_chars est_tokens=$est_tokens timeout=300s host=$current_host");

            # ── Tier 1 query ─────────────────────────────────────────────────
            my $query_start = time();
            if (@$history_items || $system) {
                push @trace, sprintf("📡 Tier-1 /api/chat to %s — model=%s %d msgs (system + %d history + prompt)",
                    $current_host, $use_model, scalar(@ollama_msgs), scalar(@$history_items));
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__,
                    'generate', "Tier-1 chat API: " . scalar(@ollama_msgs) . " messages");
                # Flush trace to progress file before blocking call so JS poller can read it
                $self->_flush_progress($gen_progress_file, \@trace, 0);
                $response = $ollama->chat(messages => \@ollama_msgs);
            } else {
                push @trace, sprintf("📡 Tier-1 /api/generate to %s — model=%s single-turn",
                    $current_host, $use_model);
                # Flush trace to progress file before blocking call so JS poller can read it
                $self->_flush_progress($gen_progress_file, \@trace, 0);
                $response = $ollama->query(
                    prompt => $prompt,
                    format => $format eq 'json' ? 'json' : undef,
                    system => $system || undef
                );
            }
            my $query_elapsed = time() - $query_start;

            unless ($response) {
                my $error      = $ollama->last_error || 'Unknown error';
                my $error_class = ref($error) || 'string';
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                    'generate', "Tier-1 FAILED host=$current_host model=$use_model elapsed=${query_elapsed}s error_class=$error_class error=$error");
                push @trace, sprintf("❌ Tier-1 FAILED after %ds: %s", $query_elapsed, $error);
                $self->_flush_progress($gen_progress_file, \@trace, 1);
                die "Ollama query failed: $error";
            }

            # Normalise response text (chat vs generate API have different keys)
            my $r_text = (ref($response->{message}) eq 'HASH' && $response->{message}->{content})
                       ? $response->{message}->{content}
                       : ($response->{response} // '');
            $model_used = $response->{model} || $use_model;

            push @trace, sprintf("✅ Tier-1 responded in %ds — %d tokens | %d chars",
                $query_elapsed, $response->{eval_count} || 0, length($r_text));
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                'generate', "Tier-1 SUCCESS elapsed=${query_elapsed}s model=$model_used");

            # ── Tier 2: escalate to large model if quality is poor ────────────
            if (!$manual_model && $tier_large ne $use_model
                && $self->_assess_response_quality($r_text, $prompt) eq 'poor')
            {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                    'generate', "Tier-1 quality poor — escalating to Tier-2 model=$tier_large");
                push @trace, sprintf("⬆️ Tier-2 escalation → model=%s", $tier_large);

                $ollama->model($tier_large);
                my $t2_start = time();
                my $resp2;
                $self->_flush_progress($gen_progress_file, \@trace, 0);
                if (@$history_items || $system) {
                    $resp2 = $ollama->chat(messages => \@ollama_msgs);
                } else {
                    $resp2 = $ollama->query(
                        prompt => $prompt,
                        format => $format eq 'json' ? 'json' : undef,
                        system => $system || undef
                    );
                }
                if ($resp2) {
                    my $text2 = (ref($resp2->{message}) eq 'HASH' && $resp2->{message}->{content})
                              ? $resp2->{message}->{content}
                              : ($resp2->{response} // '');
                    if ($text2) {
                        $r_text     = $text2;
                        $model_used = $resp2->{model} || $tier_large;
                        $response   = $resp2;
                        push @trace, sprintf("✅ Tier-2 SUCCESS in %ds — %d chars",
                            time() - $t2_start, length($text2));
                    }
                }

                # ── Tier 3: offer web search if still poor and Grok available
                if ($self->_assess_response_quality($r_text, $prompt) eq 'poor'
                    && !$is_guest && $c->session->{grok_api_key})
                {
                    push @trace, sprintf("⏱️ Total elapsed: %ds", time() - $trace_start);
                    push @trace, "🌐 Tier-3: quality still poor — offering web search consent";
                    my $partial = length($r_text) > 20 ? $r_text : undef;
                    $response_data = {
                        success          => JSON::true,
                        needs_web_search => JSON::true,
                        partial_response => $partial,
                        conversation_id  => undef,
                        thinking         => \@trace,
                    };
                    my $json_response = encode_json($response_data);
                    $c->response->body($json_response);
                    return;
                }
            }

            # Normalise $response so downstream code finds text in {response}
            $response->{response} = $r_text unless ($response->{response} && length($response->{response}));
            $response->{model}    = $model_used;
        }
        
        # Log success metrics
        my $response_length = length($response->{response} || '');
        $model_used = $response->{model} || $model_used;
        my $ai_response = $response->{response} || '';
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
            'generate', "Query successful for user '$username' - Model: $model_used, Response length: $response_length chars");
        
        # Save conversation and messages to database
        try {
            # user_id was already set above (either from session or as guest)
            unless ($user_id) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
                    'generate', "CRITICAL: user_id not found. Session keys: " . join(', ', keys %{$c->session}));
                die "USER_ID_NULL";
            }
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'generate', "SAVE_CONV_START: user_id=$user_id, is_guest=$is_guest");
            
            my $schema = $c->model('DBEncy')->schema;
            unless ($schema) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
                    'generate', "CRITICAL: Failed to get database schema from model");
                die "SCHEMA_NULL";
            }
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'generate', "PRE_CREATE: user_id=$user_id, schema_loaded=1, conversation_id=" . (defined($conversation_id) ? "'$conversation_id' (defined, len=" . length($conversation_id) . ")" : "UNDEF"));
            
            # Debug: check if conversation_id looks valid
            if ($conversation_id) {
                if ($conversation_id =~ /^\d+$/) {
                    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                        'generate', "conversation_id=$conversation_id is numeric - should reuse");
                } else {
                    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                        'generate', "conversation_id='$conversation_id' is NOT numeric - treating as invalid");
                    $conversation_id = undef;
                }
            }
            
            # Create new conversation only if conversation_id not provided
            unless ($conversation_id) {
                # Use first 80 chars of prompt as title
                my $title = substr($prompt, 0, 80);
                $title =~ s/\n/ /g;
                $title = 'AI Query' if !$title || length($title) == 0;
                
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                    'generate', "Creating new conversation with title: $title (page_context: $page_context, page_path: $page_path)");
                
                my $conversation_metadata = {
                    page_context => $page_context,
                    page_path => $page_path,
                    page_title => $page_title,
                    agent_id => $agent_id,
                    agent_name => $agent_name,
                    created_from_widget => 1,
                    widget_version => '2.0',
                    is_guest => $is_guest ? 1 : 0,
                    guest_session_id => $guest_session_id
                };
                
                my $conversation = $schema->resultset('AiConversation')->create({
                    user_id => $user_id,
                    title => $title,
                    status => 'active',
                    metadata => encode_json($conversation_metadata)
                });
                
                unless ($conversation) {
                    die "CONVERSATION_CREATE_FAILED: create() returned undef/false";
                }
                
                $conversation_id = $conversation->id;
                
                unless ($conversation_id) {
                    die "CONVERSATION_ID_NULL: conversation record created but id is null";
                }
                
                # Store conversation_id in session for persistence across prompts
                $c->session->{current_conversation_id} = $conversation_id;
                
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                    'generate', "POST_CREATE: conversation_id=$conversation_id successfully created and stored in session");
                
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                    'generate', "Conversation created successfully with ID: $conversation_id");
            } else {
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                    'generate', "Using existing conversation_id=$conversation_id (continuing conversation)");
                
                # Store conversation_id in session even when reusing (maintains persistence)
                $c->session->{current_conversation_id} = $conversation_id;
            }
            
            # Save user's message (the prompt) — skipped if pre-call block already saved it
            unless ($pre_saved_user_msg) {
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                    'generate', "Saving user message to conversation: $conversation_id");
                my $user_metadata = {
                    system_prompt => $system || '',
                    format => $format || 'text',
                    page_context => $page_context,
                    page_path => $page_path,
                    page_title => $page_title
                };
                my $user_msg = $schema->resultset('AiMessage')->create({
                    conversation_id => $conversation_id,
                    user_id => $user_id,
                    role => 'user',
                    content => $prompt,
                    agent_type => $normalized_agent_type,
                    model_used => $model_used,
                    metadata => encode_json($user_metadata),
                    ip_address => $c->request->address,
                    user_role => $c->session->{roles} ? join(',', @{$c->session->{roles}}) : 'user'
                });
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__,
                    'generate', $user_msg
                        ? "SUCCESS_USER_MSG: id=" . $user_msg->id
                        : "FAILED_USER_MSG: create() returned undef");
            }
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'generate', "Saved user message to conversation $conversation_id");
            
            # Save AI's response message
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'generate', "Saving AI response to conversation: $conversation_id");
            
            my $ai_metadata = {
                total_duration => $response->{total_duration} || 0,
                eval_count     => $response->{eval_count}     || 0,
                thinking_trace => \@trace,  # Full reasoning trace for admin diagnostics
            };
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'generate', "ASSIST_MSG: conversation_id=$conversation_id, role=assistant, content_length=" . length($ai_response));
            
            my $ai_msg = $schema->resultset('AiMessage')->create({
                conversation_id => $conversation_id,
                user_id => $user_id,
                role => 'assistant',
                content => $ai_response,
                agent_type => $normalized_agent_type,
                model_used => $model_used,
                metadata => encode_json($ai_metadata),
                ip_address => $c->request->address,
                user_role => $c->session->{roles} ? join(',', @{$c->session->{roles}}) : 'user'
            });
            
            unless ($ai_msg) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
                    'generate', "FAILED_ASSIST_MSG: create() returned undef for conversation_id=$conversation_id");
            } else {
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                    'generate', "SUCCESS_ASSIST_MSG: created message ID=" . $ai_msg->id . " for conversation_id=$conversation_id");
            }
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'generate', "Saved AI response to conversation $conversation_id");
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
                'generate', "Messages saved to conversation ID: $conversation_id for user: $username");
            
        } catch {
            my $db_error = $_;
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
                'generate', "Failed to save conversation to database: $db_error (Conversation ID: $conversation_id, User ID: $user_id)");
        };
        
        # Build JSON response
        push @trace, sprintf("⏱️ Total elapsed: %ds", time() - $trace_start);
        # Flush final trace so JS poller sees all steps including elapsed time
        $self->_flush_progress($gen_progress_file, \@trace, 1);
        $response_data = {
            success => JSON::true,
            response => $ai_response,
            model => $model_used,
            provider => $provider,
            ollama_host => ($provider eq 'ollama' ? $active_ollama_host : ''),
            citations => (ref($response->{citations}) eq 'ARRAY' ? $response->{citations} : []),
            conversation_id => $conversation_id || undef,
            created_at => $response->{created_at} || '',
            total_duration => $response->{total_duration} || 0,
            eval_count => $response->{eval_count} || 0,
            thinking => \@trace,
        };
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
            'generate', "AI query failed for user '$username' (provider: $provider): $error");
        
        my $user_error = "$error";
        $user_error =~ s/ at \/.*? line \d+.*$//s;
        
        # Save error to DB so the conversation record is complete.
        # The pre-call block already created the conversation and saved the user message,
        # so we only need to save the error assistant message here.
        push @trace, sprintf("❌ Error after %ds: %s", time() - $trace_start, $user_error || 'Unknown error')
            unless grep { /❌ Error after/ } @trace;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'generate', sprintf("catch: user_id=%s conv_id=%s pre_saved=%d trace_steps=%d",
                $user_id || 'none', $conversation_id || 'none', $pre_saved_user_msg, scalar(@trace)));

        if ($user_id && $prompt) {
            my $save_ok = 0;
            eval {
                # After a 300s Ollama timeout the DBIx::Class connection may be stale.
                # Call ->storage->ensure_connected to force a reconnect before writing.
                my $schema = $c->model('DBEncy')->schema;
                eval { $schema->storage->ensure_connected; };
                if ($@) {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                        'generate', "DB reconnect warning (non-fatal): $@");
                }

                if ($schema) {
                    # Conversation should already exist from pre-call block, but create as fallback
                    unless ($conversation_id && $conversation_id =~ /^\d+$/) {
                        my $title = substr($prompt, 0, 80);
                        $title =~ s/\n/ /g;
                        $title ||= 'AI Query';
                        my $conv = $schema->resultset('AiConversation')->create({
                            user_id  => $user_id,
                            title    => $title,
                            status   => 'active',
                            metadata => encode_json({ page_context => $page_context, page_path => $page_path })
                        });
                        $conversation_id = $conv ? $conv->id : undef;
                        $c->session->{current_conversation_id} = $conversation_id if $conversation_id;
                    }
                    if ($conversation_id) {
                        # Only save user message if pre-call block didn't already do it
                        unless ($pre_saved_user_msg) {
                            $schema->resultset('AiMessage')->create({
                                conversation_id => $conversation_id,
                                user_id  => $user_id,
                                role     => 'user',
                                content  => $prompt,
                                agent_type => $normalized_agent_type || 'general',
                                model_used => $model_used || $provider || 'unknown',
                                ip_address => $c->request->address,
                            });
                        }
                        my $err_msg = $schema->resultset('AiMessage')->create({
                            conversation_id => $conversation_id,
                            user_id  => $user_id,
                            role     => 'assistant',
                            content  => '[ERROR] ' . ($user_error || 'Failed to process AI request'),
                            agent_type => $normalized_agent_type || 'general',
                            model_used => $model_used || $provider || 'unknown',
                            metadata   => encode_json({ thinking_trace => \@trace }),
                            ip_address => $c->request->address,
                        });
                        if ($err_msg && $err_msg->id) {
                            $save_ok = 1;
                            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                                'generate', sprintf("ERROR msg saved: id=%d conv=%d trace_steps=%d",
                                    $err_msg->id, $conversation_id, scalar(@trace)));
                        } else {
                            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                                'generate', "ERROR msg create returned undef for conv=$conversation_id");
                        }
                    } else {
                        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                            'generate', "catch: no conversation_id available — error message NOT saved to DB");
                    }
                } else {
                    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                        'generate', "catch: could not get DB schema — error message NOT saved");
                }
                1;
            };
            if ($@) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                    'generate', "catch DB save FAILED (eval died): $@");
            }
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                'generate', "catch: DB save result = " . ($save_ok ? "OK" : "FAILED"));
        }

        push @trace, sprintf("❌ Error after %ds: %s", time() - $trace_start, $user_error || 'Unknown error')
            unless grep { /❌ Error after/ } @trace;
        # Flush error trace so JS poller sees it
        $self->_flush_progress($gen_progress_file, \@trace, 1);
        $response_data = {
            success => JSON::false,
            error => $user_error || 'Failed to process AI request',
            conversation_id => $conversation_id || undef,
            thinking => \@trace,
        };
    };
    
    my $json_response = encode_json($response_data);
    $c->response->body($json_response);
}

=head2 query_form

Alternative form-based query interface.

=cut

sub query_form :Local :Args(0) {
    my ($self, $c) = @_;
    $c->response->redirect($c->uri_for('/ai'), 301);
}

=head2 result

Form submission handler that displays results in template.

=cut

sub result :Local :Args(0) {
    my ($self, $c) = @_;
    
    # Check authentication
    unless ($c->session->{username}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'result', "Unauthorized access attempt to AI result");
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    my $username = $c->session->{username};
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
        'result', "Processing AI result request");
    
    # Get parameters
    my $prompt = $c->request->params->{prompt} || '';
    my $format = $c->request->params->{format} || '';
    my $system = $c->request->params->{system} || '';
    
    # Validate prompt
    unless ($prompt && length($prompt) > 0) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'result', "Empty prompt in form submission from user: $username");
        
        $c->stash(
            template => 'ai/result.tt',
            page_title => 'AI Result',
            error => 'Prompt is required',
            prompt => $prompt
        );
        return;
    }
    
    # Log the query
    my $prompt_preview = substr($prompt, 0, 100);
    $prompt_preview .= '...' if length($prompt) > 100;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
        'result', "AI form query from user '$username': $prompt_preview");
    
    my $ai_response;
    my $error_message;
    my $response_metadata = {};
    my $conversation_id;
    my $start_time = time();
    
    try {
        # Get Ollama model
        my $ollama = $c->model('Ollama');
        unless ($ollama) {
            die "Failed to load Ollama model";
        }
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
            'result', "Ollama model loaded, processing form query...");
        
        # Query the API
        my $response = $ollama->query(
            prompt => $prompt,
            format => $format eq 'json' ? 'json' : undef,
            system => $system || undef
        );
        
        unless ($response) {
            my $error = $ollama->last_error || 'Unknown error';
            die "Ollama query failed: $error";
        }
        
        $ai_response = $response->{response} || '';
        my $response_time = int((time() - $start_time) * 1000); # milliseconds
        
        $response_metadata = {
            model => $response->{model} || $ollama->model,
            created_at => $response->{created_at} || '',
            total_duration => $response->{total_duration} || 0,
            eval_count => $response->{eval_count} || 0
        };
        
        # Log success
        my $response_length = length($ai_response);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
            'result', "Form query successful for user '$username' - Model: " . 
            $response_metadata->{model} . ", Response length: $response_length chars");
        
        # Save conversation to database
        try {
            my $user_id = $c->session->{user_id};
            
            unless ($user_id) {
                die "USER_ID_NULL: user_id not found in session. Session keys: " . join(', ', keys %{$c->session});
            }
            
            my $schema = $c->model('DBEncy')->schema;
            unless ($schema) {
                die "SCHEMA_NULL: Failed to get database schema from model";
            }
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'result', "PRE_CREATE: user_id=$user_id, schema_loaded=1, about to create conversation");
            
            # Get first prompt words for title
            my $title_text = substr($prompt, 0, 80);
            $title_text =~ s/\n/ /g;
            my $title = $title_text;
            
            # Create new conversation
            my $conversation = $schema->resultset('AiConversation')->create({
                user_id => $user_id,
                title => $title,
                status => 'active'
            });
            
            unless ($conversation) {
                die "CONVERSATION_CREATE_FAILED: create() returned undef/false";
            }
            
            $conversation_id = $conversation->id;
            
            unless ($conversation_id) {
                die "CONVERSATION_ID_NULL: conversation record created but id is null";
            }
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'result', "POST_CREATE: conversation_id=$conversation_id successfully created");
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'result', "Created conversation ID: $conversation_id for user: $username");
            
            # Save user's query message
            my $user_metadata = {
                system_prompt => $system || '',
                format => $format || 'text'
            };
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'result', "USER_MSG_RESULT: conversation_id=$conversation_id, content_length=" . length($prompt));
            
            my $user_msg = $schema->resultset('AiMessage')->create({
                conversation_id => $conversation_id,
                user_id => $user_id,
                role => 'user',
                content => $prompt,
                agent_type => 'documentation',
                model_used => $response_metadata->{model},
                metadata => encode_json($user_metadata),
                ip_address => $c->request->address,
                user_role => $c->session->{roles} ? join(',', @{$c->session->{roles}}) : 'user'
            });
            
            if ($user_msg) {
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                    'result', "SUCCESS_USER_MSG: Saved user message, ID=" . $user_msg->id . " to conversation $conversation_id");
            } else {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
                    'result', "FAILED_USER_MSG: create() returned undef for conversation_id=$conversation_id");
            }
            
            # Save AI's response message
            my $ai_metadata = {
                total_duration => $response_metadata->{total_duration},
                eval_count => $response_metadata->{eval_count}
            };
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'result', "ASSIST_MSG_RESULT: conversation_id=$conversation_id, content_length=" . length($ai_response));
            
            my $ai_msg = $schema->resultset('AiMessage')->create({
                conversation_id => $conversation_id,
                user_id => $user_id,
                role => 'assistant',
                content => $ai_response,
                agent_type => 'documentation',
                model_used => $response_metadata->{model},
                response_time_ms => $response_time,
                metadata => encode_json($ai_metadata),
                ip_address => $c->request->address,
                user_role => $c->session->{roles} ? join(',', @{$c->session->{roles}}) : 'user'
            });
            
            if ($ai_msg) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
                    'result', "SUCCESS_ASSIST_MSG: Conversation saved - ID: $conversation_id, AI Message ID=" . $ai_msg->id . ", Response time: ${response_time}ms");
            } else {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
                    'result', "FAILED_ASSIST_MSG: create() returned undef for conversation_id=$conversation_id");
            }
            
        } catch {
            my $db_error = $_;
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
                'result', "Failed to save conversation to database: $db_error");
            # Don't fail the request if database save fails - still show response to user
        };
        
    } catch {
        my $error = $_;
        $error_message = 'Failed to process AI request';
        
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
            'result', "Form query failed for user '$username': $error");
    };
    
    # Set template variables
    $c->stash(
        template => 'ai/result.tt',
        page_title => 'AI Result',
        prompt => $prompt,
        ai_response => $ai_response,
        error => $error_message,
        response_metadata => $response_metadata,
        username => $username,
        conversation_id => $conversation_id
    );
}

=head2 chat

Chat endpoint for conversational AI with history support. Delegates to Ollama model's chat method.

Parameters:
- prompt (required): User's message
- model (optional): Specific model to use
- history (optional): Conversation history array

=cut

sub chat :Local :Args(0) {
    my ($self, $c) = @_;
    
    # Set response content type
    $c->response->content_type('application/json');
    
    # Determine if user is authenticated or guest
    my $username = $c->session->{username};
    my $user_id = $c->session->{user_id};
    my $guest_session_id = $c->session->{guest_session_id};
    my $is_guest = 0;
    
    # If not logged in, create guest session
    if (!$username) {
        $is_guest = 1;
        
        # Create a unique guest session ID if not already present
        unless ($guest_session_id) {
            use Data::UUID;
            my $ug = Data::UUID->new;
            $guest_session_id = $ug->create_str();
            $c->session->{guest_session_id} = $guest_session_id;
        }
        
        # Use guest user (ID 199)
        $user_id = 199;
        $username = "Guest-" . substr($guest_session_id, 0, 8);
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
            'chat', "Guest user session created: $username (session: $guest_session_id)");
    } else {
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
            'chat', "Authenticated user: $username");
    }
    
    # Parse JSON body - try multiple methods to get the body content
    my $json_data = {};
    my $content_type = $c->request->content_type || '';
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
        'chat', "Request content-type: '$content_type', method: " . $c->request->method);
    
    if ($content_type =~ /application\/json/i) {
        try {
            # Try to get raw body content using multiple methods
            my $raw_body;
            
            # Method 1: Try $c->req->content (most reliable)
            if ($c->req->can('content')) {
                $raw_body = $c->req->content;
            } else {
                # Method 2: Fallback to body
                $raw_body = $c->request->body;
                if (ref($raw_body)) {
                    # If it's a filehandle, read it
                    seek($raw_body, 0, 0);
                    $raw_body = do { local $/; <$raw_body> };
                }
            }
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'chat', "Raw body retrieved, length: " . (defined $raw_body ? length($raw_body) : 'UNDEF'));
            
            if ($raw_body && length($raw_body) > 0) {
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                    'chat', "Body content (first 200 chars): " . substr($raw_body, 0, 200));
                
                $json_data = decode_json($raw_body);
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                    'chat', "JSON parsed successfully, keys: " . join(', ', keys %$json_data));
            } else {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
                    'chat', "JSON content-type but body is empty or undef");
            }
        } catch {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
                'chat', "Failed to parse JSON body: $_");
            
            my $error_response = encode_json({
                success => JSON::false,
                error => 'Invalid JSON in request body'
            });
            $c->response->body($error_response);
            $c->response->status(400);
            return;
        };
    } else {
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
            'chat', "Not JSON content-type, using form parameters");
    }
    
    # Get parameters from JSON or fallback to form params
    my $prompt = $json_data->{prompt} || $c->request->params->{prompt} || '';
    my $model = $json_data->{model} || $c->request->params->{model} || '';
    my $history = $json_data->{history} || [];
    my $conversation_id = $json_data->{conversation_id} || $c->request->params->{conversation_id};
    my $use_search_chat = $json_data->{use_search} ? 1 : 0;
    my $chat_page_path  = $json_data->{page_path}  || $c->request->params->{page_path}  || '';
    my $chat_page_title = $json_data->{page_title} || $c->request->params->{page_title} || '';
    my $chat_agent_id     = $json_data->{agent_id}      || $c->request->params->{agent_id}      || '';
    my $chat_agent_system = $json_data->{system}        || $c->request->params->{system}        || '';
    my $chat_page_content = $json_data->{page_content}  || $c->request->params->{page_content}  || '';
    
    # Validate prompt
    unless ($prompt && length($prompt) > 0) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'chat', "Empty prompt provided by user: $username");
        
        my $error_response = encode_json({
            success => JSON::false,
            error => 'Prompt is required'
        });
        $c->response->body($error_response);
        $c->response->status(400);
        return;
    }
    
    # Build messages array for chat API
    my @messages = ();
    
    # Add history if provided
    if ($history && ref($history) eq 'ARRAY') {
        foreach my $msg (@$history) {
            if (ref($msg) eq 'HASH' && $msg->{role} && $msg->{content}) {
                push @messages, {
                    role => $msg->{role},
                    content => $msg->{content}
                };
            }
        }
    }
    
    # Add current user message
    push @messages, {
        role => 'user',
        content => $prompt
    };
    
    my $prompt_preview = substr($prompt, 0, 100);
    $prompt_preview .= '...' if length($prompt) > 100;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
        'chat', "AI chat from user '$username': $prompt_preview");
    
    my $response_data;
    my @chat_trace;       # Reasoning trace returned to client as 'thinking'
    my $chat_trace_start = time();
    my $progress_file = $self->_progress_file_path($c);
    unlink $progress_file if -f $progress_file;

    # Determine user permissions for model selection
    my $user_roles_chat = $c->session->{roles} || [];
    if (!ref($user_roles_chat)) {
        $user_roles_chat = [split(/\s*,\s*/, $user_roles_chat)] if $user_roles_chat;
    }
    my $can_select_model_perm = 0;
    if (ref($user_roles_chat) eq 'ARRAY') {
        $can_select_model_perm = grep { $_ =~ /^(admin|developer|editor)$/i } @$user_roles_chat;
    }

    # Detect if selected model is a Grok (xAI) model
    my $is_grok_model = ($model && $model =~ /^grok/i) ? 1 : 0;

    # Role-based capability injection into messages (insert as system message)
    my $role_prompt_chat = $self->_build_role_system_prompt($c, $user_roles_chat, $is_grok_model ? 'grok' : 'ollama', $chat_page_path, $chat_page_title);

    # Build combined system prompt: agent-specific prompt + role prompt + live module data + shared KB
    my @system_parts;
    push @system_parts, $chat_agent_system if $chat_agent_system;
    push @system_parts, $role_prompt_chat  if $role_prompt_chat;

    # Fetch live module data (workshops, ENCY, etc.) when the prompt contains relevant keywords
    my $module_data = $self->_get_module_data($c, $prompt, $chat_agent_id);
    push @system_parts, $module_data if $module_data;

    # Inject relevant past Q&A from the shared knowledge base (all users)
    my $site_name_chat = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    my $shared_history = $self->_search_shared_history($c, $prompt, $site_name_chat);
    push @system_parts, $shared_history if $shared_history;

    # Inject current page content sent by the browser.
    # This is the single most important context source — the AI can see exactly what
    # the user sees (buttons, tables, links, labels) without any keyword matching.
    if ($chat_page_content && length($chat_page_content) > 20) {
        my $page_snippet = "--- Current Page Content (what the user sees on screen) ---\n"
                         . "URL: $chat_page_path\n\n"
                         . $chat_page_content
                         . "\n--- End of Page Content ---";
        push @system_parts, $page_snippet;
    }

    my $combined_system_prompt = join("\n\n", @system_parts);

    # Build initial trace entries (always shown)
    push @chat_trace, sprintf("🧑 User: %s (%s) | Site: %s | Page: %s",
        $username, $is_guest ? 'guest' : 'authenticated',
        $c->stash->{SiteName} || $c->session->{SiteName} || 'unknown',
        $chat_page_path || '(unknown)');
    push @chat_trace, sprintf("🤖 Agent: %s | Provider: %s",
        $chat_agent_id || 'general', $is_grok_model ? 'grok' : 'ollama');
    push @chat_trace, sprintf("💬 Prompt (%d chars) | History: %d prior messages",
        length($prompt), scalar(@$history));
    push @chat_trace, $module_data   ? "🗂️ DB data injected" : "🗂️ No DB data injected (prompt didn't match todo/project/ENCY keywords)";
    push @chat_trace, $shared_history ? "📚 Shared KB: matching prior Q&A found" : "📚 Shared KB: no matching prior Q&A found";
    push @chat_trace, $chat_page_content
        ? sprintf("📄 Page content injected (%d chars)", length($chat_page_content))
        : "📄 No page content received from browser";

    # Only admins/editors may use web search
    $use_search_chat = 0 unless $can_select_model_perm;

    # Require login for external AI models - check before entering try block
    if ($is_grok_model && $is_guest) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'chat', "Guest user attempted to use Grok model - login required");
        $c->response->status(401);
        $c->response->body(encode_json({
            success => JSON::false,
            error => 'Please log in to use external AI models (Grok/xAI). Click the login link above.'
        }));
        return;
    }

    my $model_used = 'unknown';  # declared before try so catch block can read it

    try {
        my $ai_response = '';
        my $response_created_at = '';
        my $response_total_duration = 0;
        my $response_eval_count = 0;

        if ($is_grok_model) {
            # Route to Grok API using user's stored API key
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                'chat', "Routing to Grok API for model: $model, user_id: $user_id");

            my $grok_api_key = '';
            my $key_found = 0;
            try {
                my $schema = $c->model('DBEncy')->schema;
                my $key_obj = $schema->resultset('UserApiKeys')->search(
                    { user_id => $user_id, service => 'grok', is_active => '1' },
                )->first;
                # Admins fall back to any active Grok key if they don't have their own
                if (!$key_obj && $can_select_model_perm) {
                    $key_obj = $schema->resultset('UserApiKeys')->search(
                        { service => 'grok', is_active => '1' }
                    )->first;
                }
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__,
                    'chat', "Grok key lookup result: " . ($key_obj ? "found (id=" . $key_obj->id . ", owner=" . $key_obj->user_id . ")" : "not found"));
                if ($key_obj && $key_obj->api_key_encrypted) {
                    $key_found = 1;
                    $grok_api_key = $key_obj->get_api_key() || '';
                    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__,
                        'chat', "Grok key decrypted, length: " . length($grok_api_key));
                }
            } catch {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                    'chat', "Failed to fetch grok API key for user $user_id: $_");
            };

            unless ($grok_api_key) {
                my $msg = $key_found
                    ? 'Failed to decrypt your Grok API key. Please re-save it at /ai/manage_api_keys'
                    : 'No Grok API key found. Please add your xAI API key at /ai/manage_api_keys';
                die $msg;
            }

            my $grok = $c->model('Grok');
            unless ($grok) {
                die "Failed to load Grok model";
            }

            $grok->api_key($grok_api_key);
            $grok->model($model) if $model;

            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__,
                'chat', "Calling Grok API with model: " . $grok->model . " web_search=$use_search_chat");
            push @chat_trace, sprintf("📡 Calling Grok API — model=%s web_search=%s",
                $grok->model, $use_search_chat ? 'yes' : 'no');

            # Prepend combined system prompt if available
            my @final_messages = @messages;
            if ($combined_system_prompt) {
                unshift @final_messages, { role => 'system', content => $combined_system_prompt };
            }

            my $response = $grok->chat(messages => \@final_messages, use_search => $use_search_chat);

            unless ($response) {
                my $error = $grok->last_error || 'Unknown error';
                die "Grok chat failed: $error";
            }

            if ($response->{choices} && ref($response->{choices}) eq 'ARRAY' && @{$response->{choices}}) {
                $ai_response = $response->{choices}[0]{message}{content} || '';
            } elsif ($response->{response}) {
                $ai_response = $response->{response};
            }

            $model_used = $response->{model} || $grok->model;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                'chat', "Grok chat successful for user '$username' - Model: $model_used, Response length: " . length($ai_response) . " chars");
            push @chat_trace, sprintf("✅ Grok responded — model=%s %d chars", $model_used, length($ai_response));

        } else {
            # ── Ollama 3-Tier Escalation ──────────────────────────────────────
            # Tier 1: small/fast model → if quality poor, Tier 2: large model
            # → if still poor AND user has Grok, return web-search consent flag.

            my $ollama = $c->model('Ollama');
            unless ($ollama) {
                die "Ollama service is not available";
            }

            my ($current_host, $current_port, $current_model, $installed_models) = $self->_get_current_ollama_config($c, $can_select_model_perm);

            # Quick availability check before committing to a long request
            my $avail_check = Comserv::Model::Ollama->new(host => $current_host, port => $current_port || 11434, timeout => 3);
            unless ($avail_check && $avail_check->check_connection()) {
                die "Ollama is not reachable at $current_host. Please select an external AI model (Grok) or try again later.";
            }

            $ollama->set_host($current_host);
            $ollama->timeout(300);
            $ollama->port($current_port) if $current_port;

            # Determine small and large model tiers from installed list
            my ($tier_small, $tier_large) = $self->_pick_ollama_tier(
                $installed_models, $current_model, $chat_agent_id, $chat_agent_id);

            # If user manually picked a model (admin override), skip escalation logic
            my $manual_model = ($model && $can_select_model_perm) ? $model : '';

            push @chat_trace, sprintf("🔍 Tier selection: small=%s large=%s → using=%s%s",
                $tier_small, $tier_large,
                $manual_model || $tier_small,
                $manual_model ? ' (manual override)' : '');

            # ── Prefer in-memory models to avoid cold-start delays ──────────────
            my $chat_use_model = $manual_model || $tier_small;
            unless ($manual_model) {
                my $running = $avail_check->get_running_models() || [];
                if (@$running) {
                    my %in_mem;
                    for my $r (@$running) { $in_mem{$r->{name}} = 1 if $r->{name}; }
                    push @chat_trace, "💾 In-memory: " . join(', ', sort keys %in_mem);
                    if (!$in_mem{$chat_use_model}) {
                        my @inst_names = map { ref($_) ? ($_->{name} || '') : ($_ || '') } @$installed_models;
                        my ($preferred) = grep { $in_mem{$_} } ($tier_large, @inst_names);
                        if ($preferred) {
                            push @chat_trace, "💾 Switched '$chat_use_model' → '$preferred' (already in memory)";
                            $chat_use_model = $preferred;
                        }
                    } else {
                        push @chat_trace, "💾 '$chat_use_model' already in memory — no cold-start needed";
                    }
                    # Renew keep_alive so model doesn't expire between the /api/ps
                    # check and the actual /api/chat call (race condition fix).
                    # Sending an empty-prompt generate with stream:false returns instantly.
                    eval {
                        my $ping_ua  = LWP::UserAgent->new(timeout => 10);
                        my $ping_url = "http://$current_host:" . ($current_port || 11434) . "/api/generate";
                        my $ping_payload = encode_json({
                            model      => $chat_use_model,
                            prompt     => '',
                            stream     => JSON::false,
                            keep_alive => '2h',
                        });
                        $ping_ua->post($ping_url, 'Content-Type' => 'application/json', Content => $ping_payload);
                        push @chat_trace, "🔁 keep_alive renewed for '$chat_use_model'";
                    };
                }
            }

            # Prepend combined system prompt for Ollama
            my @ollama_messages = @messages;
            if ($combined_system_prompt) {
                unshift @ollama_messages, { role => 'system', content => $combined_system_prompt };
            }

            # ── Hard context budget: keep total input under ~12 000 chars (~3 000 tokens)
            # CPU Ollama prefill runs at ~46 tok/s; 3 000 tokens takes ~65s — safe under
            # 300s timeout even with generation.  Over-budget → trim history content first.
            my $BUDGET_CHARS  = 12_000;
            my $SYS_MAX_CHARS_CHAT = 8_000;
            my $raw_total = 0;
            $raw_total += length($_->{content} || '') for @ollama_messages;
            if ($raw_total > $BUDGET_CHARS) {
                push @chat_trace, sprintf("⚠️ Context %d chars > %d budget — trimming history", $raw_total, $BUDGET_CHARS);
                # Pass 1: cap each non-system message at 300 chars
                for my $msg (@ollama_messages) {
                    next if ($msg->{role} || '') eq 'system';
                    my $len = length($msg->{content} || '');
                    if ($len > 300) {
                        $msg->{content} = substr($msg->{content}, 0, 300) . '…';
                    }
                }
                my $after_p1 = 0;
                $after_p1 += length($_->{content} || '') for @ollama_messages;
                if ($after_p1 > $BUDGET_CHARS && @ollama_messages && $ollama_messages[0]{role} eq 'system') {
                    my $sys = $ollama_messages[0]{content};
                    # Pass 2: strip page_content section
                    $sys =~ s/\n\n---[ ]Current Page Content.*$//s;
                    $ollama_messages[0]{content} = $sys;
                    push @chat_trace, "⚠️ Stripped page_content from system prompt (still over budget)";
                    # Pass 3: hard-cap system prompt
                    if (length($sys) > $SYS_MAX_CHARS_CHAT) {
                        $ollama_messages[0]{content} = substr($sys, 0, $SYS_MAX_CHARS_CHAT) . "\n[system prompt truncated to fit context budget]";
                        push @chat_trace, sprintf("⚠️ System prompt truncated from %d to %d chars", length($sys), $SYS_MAX_CHARS_CHAT);
                    }
                }
            }

            # ── Tier 1: Small / fast model ────────────────────────────────────
            my $use_model = $chat_use_model;
            $ollama->model($use_model);

            my $total_chat_chars = 0;
            $total_chat_chars += length($_->{content} || '') for @ollama_messages;
            my $est_chat_tokens  = int($total_chat_chars / 4);
            push @chat_trace, sprintf("📊 Input size: %d chars (~%d tokens) across %d messages | timeout=%ds",
                $total_chat_chars, $est_chat_tokens, scalar(@ollama_messages), $ollama->timeout);
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                'chat', "Pre-request: model=$use_model msgs=" . scalar(@ollama_messages) .
                " chars=$total_chat_chars est_tokens=$est_chat_tokens timeout=300s host=$current_host");

            push @chat_trace, sprintf("📡 Tier-1 /api/chat to %s — model=%s %d msgs (system + %d history + prompt)",
                $current_host, $use_model, scalar(@ollama_messages), scalar(@$history));

            # ── Verbose message dump (admin diagnostics — like zenflow thinking) ──
            for my $i (0 .. $#ollama_messages) {
                my $msg  = $ollama_messages[$i];
                my $role = $msg->{role} || '?';
                my $body = $msg->{content} || '';
                my $preview = length($body) > 600
                    ? substr($body, 0, 600) . "\n…[+" . (length($body) - 600) . " chars]"
                    : $body;
                push @chat_trace, sprintf("📨 msg[%d] %s:\n%s", $i, uc($role), $preview);
            }

            # Flush trace to progress file so the polling endpoint can serve it
            $self->_flush_progress($progress_file, \@chat_trace, 0);

            my $chat_start = time();
            my $response   = $ollama->chat(messages => \@ollama_messages);
            my $chat_elapsed = time() - $chat_start;

            unless ($response) {
                my $error = $ollama->last_error || 'Unknown error';
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                    'chat', "Tier-1 Ollama FAILED model=$use_model elapsed=${chat_elapsed}s error=$error");
                push @chat_trace, sprintf("❌ Tier-1 FAILED after %ds: %s", $chat_elapsed, $error);
                die "Ollama chat failed: $error";
            }

            if ($response->{message} && $response->{message}->{content}) {
                $ai_response = $response->{message}->{content};
            } elsif ($response->{response}) {
                $ai_response = $response->{response};
            }
            $model_used = $response->{model} || $use_model;
            push @chat_trace, sprintf("✅ Tier-1 responded in %ds — %d tokens | %d chars",
                $chat_elapsed, $response->{eval_count} || 0, length($ai_response));
            # Show first 800 chars of AI response in trace for full visibility
            push @chat_trace, "🤖 AI response:\n"
                . (length($ai_response) > 800
                    ? substr($ai_response, 0, 800) . "\n…[+" . (length($ai_response) - 800) . " chars]"
                    : $ai_response);

            # ── Tier 2: Escalate to large model if quality is poor ────────────
            if (!$manual_model && $tier_large ne $tier_small
                && $self->_assess_response_quality($ai_response, $prompt) eq 'poor')
            {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                    'chat', "Tier-1 quality poor — escalating to Tier-2 model=$tier_large");
                push @chat_trace, sprintf("⬆️ Tier-2 escalation → model=%s", $tier_large);

                $ollama->model($tier_large);
                my $resp2 = $ollama->chat(messages => \@ollama_messages);
                if ($resp2) {
                    my $text2 = ($resp2->{message} && $resp2->{message}->{content})
                              ? $resp2->{message}->{content}
                              : ($resp2->{response} // '');
                    if ($text2) {
                        $ai_response = $text2;
                        $model_used  = $resp2->{model} || $tier_large;
                        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                            'chat', "Tier-2 SUCCESS model=$model_used");
                        push @chat_trace, sprintf("✅ Tier-2 SUCCESS model=%s", $model_used);
                    }
                }

                # ── Tier 3: Offer web search if still poor and Grok available ──
                if ($self->_assess_response_quality($ai_response, $prompt) eq 'poor'
                    && !$is_guest && $c->session->{grok_api_key})
                {
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                        'chat', "Tier-2 quality poor — offering web search consent");

                    # Return a special response asking the user for web search consent.
                    # The client will show Yes/No buttons; if Yes it re-sends with use_search=1 and provider=grok.
                    my $partial = length($ai_response) > 20 ? $ai_response : undef;
                    $c->response->content_type('application/json; charset=utf-8');
                    $c->response->body(encode_json({
                        success          => JSON::true,
                        needs_web_search => JSON::true,
                        partial_answer   => $partial,
                        message          => "I couldn't find a confident answer from local knowledge. Would you like me to search the web?",
                        model            => $model_used,
                    }));
                    return;
                }
            }
            $response_created_at = $response->{created_at} || '';
            $response_total_duration = $response->{total_duration} || 0;
            $response_eval_count = $response->{eval_count} || 0;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                'chat', "Chat successful for user '$username' - Model: $model_used, Response length: " . length($ai_response) . " chars");
        }

        # Save conversation to database
        my $final_conversation_id = $conversation_id;
        try {
            # user_id was already set above (either from session or as guest)
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'chat', "SAVE_CONV_START: user_id=$user_id, provided_conv_id=$conversation_id, is_guest=$is_guest");
            
            unless ($user_id) {
                die "User ID not found";
            }
            
            my $schema = $c->model('DBEncy')->schema;
            
            # If no conversation_id provided, create a new conversation
            unless ($final_conversation_id) {
                # Get title from request if provided
                my $title = $json_data->{title} || $c->request->params->{title};
                
                # If no title provided, generate from prompt
                unless ($title) {
                    my $title_text = '';
                    if ($prompt && length($prompt) > 0) {
                        $title_text = substr($prompt, 0, 80);
                    } elsif (@$history > 0 && $history->[0]->{content}) {
                        $title_text = substr($history->[0]->{content}, 0, 80);
                    }
                    $title_text =~ s/\n/ /g;
                    $title = $title_text || 'Chat Conversation';
                }
                
                # Create new conversation
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                    'chat', "Creating new conversation with title: $title");
                
                my $conversation_metadata = {
                    is_guest => $is_guest ? 1 : 0,
                    guest_session_id => $guest_session_id
                };
                
                my $conversation = $schema->resultset('AiConversation')->create({
                    user_id => $user_id,
                    title => $title,
                    status => 'active',
                    metadata => encode_json($conversation_metadata)
                });
                
                unless ($conversation) {
                    die "Failed to create conversation object";
                }
                
                $final_conversation_id = $conversation->id;
                
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                    'chat', "Conversation created successfully with ID: $final_conversation_id");
                
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                    'chat', "Created new conversation ID: $final_conversation_id for user: $username");
            } else {
                # Conversation exists - just log it
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                    'chat', "Continuing existing conversation ID: $final_conversation_id for user: $username");
            }
            
            # Store in session so widget and /ai page share the same conversation
            $c->session->{current_conversation_id} = $final_conversation_id if $final_conversation_id;
            
            # Save user's message
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'chat', "Saving user message to conversation: $final_conversation_id");
            
            $schema->resultset('AiMessage')->create({
                conversation_id => $final_conversation_id,
                user_id => $user_id,
                role => 'user',
                content => $prompt,
                agent_type => 'documentation',
                model_used => $model_used,
                metadata => encode_json({
                    system_prompt => '',
                    format => 'text',
                    is_guest => $is_guest ? 1 : 0,
                    guest_session_id => $guest_session_id
                }),
                ip_address => $c->request->address,
                user_role => $c->session->{roles} ? join(',', @{$c->session->{roles}}) : 'normal'
            });
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'chat', "Saved user message to conversation $final_conversation_id");
            
            # Finalise the trace before saving so the permanent DB record is complete
            push @chat_trace, sprintf("⏱️ Total elapsed: %ds", time() - $chat_trace_start);

            # Save AI's response message — includes full thinking trace in metadata
            # so the diagnostic trail is permanently recorded and can be reviewed in
            # the conversation history viewer.
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'chat', "Saving AI response to conversation: $final_conversation_id");
            
            $schema->resultset('AiMessage')->create({
                conversation_id => $final_conversation_id,
                user_id => $user_id,
                role => 'assistant',
                content => $ai_response,
                agent_type => 'documentation',
                model_used => $model_used,
                metadata => encode_json({
                    total_duration   => $response_total_duration,
                    eval_count       => $response_eval_count,
                    is_guest         => $is_guest ? 1 : 0,
                    guest_session_id => $guest_session_id,
                    thinking_trace   => \@chat_trace,
                }),
                ip_address => $c->request->address,
                user_role => $c->session->{roles} ? join(',', @{$c->session->{roles}}) : 'normal'
            });
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'chat', "Saved AI response (with thinking trace) to conversation $final_conversation_id");
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
                'chat', "Messages saved to conversation ID: $final_conversation_id for user: $username");
            
        } catch {
            my $db_error = $_;
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
                'chat', "Failed to save conversation to database: $db_error (Final Conv ID: $final_conversation_id, User ID: $user_id)");
        };

        # Mark progress as done so poller stops
        $self->_flush_progress($progress_file, \@chat_trace, 1);

        # Build JSON response
        $response_data = {
            success => JSON::true,
            response => $ai_response,
            model => $model_used,
            conversation_id => $final_conversation_id || undef,
            created_at => $response_created_at,
            total_duration => $response_total_duration,
            eval_count => $response_eval_count,
            thinking => \@chat_trace,
        };
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
            'chat', "AI chat failed for user '$username' (model: $model): $error");
        
        my $user_error = "$error";
        $user_error =~ s/ at \/.*? line \d+.*$//s;
        
        # Finalise the error trace (once, before DB save so the record is complete)
        push @chat_trace, sprintf("❌ Error after %ds: %s",
            time() - $chat_trace_start, $user_error || 'Unknown error');

        # Save failed request to DB so conversation record is complete
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'chat', sprintf("catch: user_id=%s conv_id=%s trace_steps=%d",
                $user_id || 'none', $conversation_id || 'none', scalar(@chat_trace)));

        if ($user_id && $prompt) {
            my $chat_save_ok = 0;
            eval {
                my $schema = $c->model('DBEncy')->schema;
                eval { $schema->storage->ensure_connected; };
                if ($@) {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                        'chat', "DB reconnect warning (non-fatal): $@");
                }
                if ($schema) {
                    my $save_conv_id = $conversation_id;
                    unless ($save_conv_id && $save_conv_id =~ /^\d+$/) {
                        my $title = substr($prompt, 0, 80);
                        $title =~ s/\n/ /g;
                        $title ||= 'Chat Error';
                        my $conv = $schema->resultset('AiConversation')->create({
                            user_id => $user_id,
                            title   => $title,
                            status  => 'active',
                            metadata => encode_json({ is_guest => $is_guest ? 1 : 0 })
                        });
                        $save_conv_id = $conv ? $conv->id : undef;
                        $c->session->{current_conversation_id} = $save_conv_id if $save_conv_id;
                    }
                    if ($save_conv_id) {
                        $schema->resultset('AiMessage')->create({
                            conversation_id => $save_conv_id,
                            user_id  => $user_id,
                            role     => 'user',
                            content  => $prompt,
                            agent_type => $chat_agent_id || 'documentation',
                            model_used => $model_used || $model || 'unknown',
                            ip_address => $c->request->address,
                        });
                        my $chat_err_msg = $schema->resultset('AiMessage')->create({
                            conversation_id => $save_conv_id,
                            user_id  => $user_id,
                            role     => 'assistant',
                            content  => '[ERROR] ' . $user_error,
                            agent_type => $chat_agent_id || 'documentation',
                            model_used => $model_used || $model || 'unknown',
                            metadata   => encode_json({ thinking_trace => \@chat_trace }),
                            ip_address => $c->request->address,
                        });
                        if ($chat_err_msg && $chat_err_msg->id) {
                            $chat_save_ok = 1;
                            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                                'chat', sprintf("ERROR msg saved: id=%d conv=%d trace_steps=%d",
                                    $chat_err_msg->id, $save_conv_id, scalar(@chat_trace)));
                        } else {
                            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                                'chat', "ERROR msg create returned undef for conv=$save_conv_id");
                        }
                    } else {
                        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                            'chat', "catch: no conversation_id — error message NOT saved");
                    }
                }
                1;
            };
            if ($@) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                    'chat', "catch DB save FAILED (eval died): $@");
            }
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                'chat', "catch: DB save result = " . ($chat_save_ok ? "OK" : "FAILED"));
        }

        # Mark progress as done (with error trace) so poller stops
        $self->_flush_progress($progress_file, \@chat_trace, 1);

        $response_data = {
            success => JSON::false,
            error => $user_error || 'Failed to process AI chat request',
            thinking => \@chat_trace,
        };
        $c->response->status(200);
    };
    
    my $json_response = encode_json($response_data);
    $c->response->body($json_response);
}

=head2 models

Ollama model management interface showing available and installed models across configured servers.

=cut

sub models :Local :Args(0) {
    my ($self, $c) = @_;
    
    # Check authentication
    unless ($c->session->{username}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'models', "Unauthorized access attempt to AI models");
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    my $username = $c->session->{username};
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
        'models', "User accessing AI models interface");
    
    # Determine user permissions for viewing all servers
    my $user_roles = $c->session->{roles} || [];
    if (!ref($user_roles)) {
        $user_roles = [split(/\s*,\s*/, $user_roles)] if $user_roles;
    }
    my $can_select_model = 0;
    if (ref($user_roles) eq 'ARRAY') {
        $can_select_model = grep { $_ =~ /^(admin|developer|editor)$/i } @$user_roles;
    }
    
    # Initialize servers data structure for multiple Ollama servers
    my $servers = [];
    
    # Configure servers from comserv.conf <Ollama> block
    my $ollama_cfg2   = $c->config->{Ollama} || {};
    my $cfg_host      = $ollama_cfg2->{host}          || 'localhost';
    my $cfg_fallback  = $ollama_cfg2->{fallback_host} || $cfg_host;
    my $cfg_port      = $ollama_cfg2->{port}          || 11434;

    my @server_configs;
    if ($can_select_model) {
        @server_configs = (
            { name => "Local ($cfg_host)",    host => $cfg_host,     port => $cfg_port, location => 'Primary' },
        );
        if ($cfg_fallback ne $cfg_host) {
            push @server_configs,
                { name => "Fallback ($cfg_fallback)", host => $cfg_fallback, port => $cfg_port, location => 'Fallback' };
        }
    } else {
        @server_configs = (
            { name => 'AI Server', host => $cfg_host, port => $cfg_port, location => 'Primary' }
        );
    }
    
    foreach my $config (@server_configs) {
        my $server_info = {
            name => $config->{name},
            host => $config->{host},
            port => $config->{port},
            location => $config->{location},
            connected => 0,
            error => undef,
            available_models => [],
            installed_models => [],
            show_details => $can_select_model  # Whether to show technical details
        };
        
        # Try to connect to each server and get model information
        try {
            # Create Ollama instance for this specific server
            my $ollama = $c->model('Ollama');
            if ($ollama) {
                # Configure for this specific server
                $ollama->host($config->{host});
                $ollama->port($config->{port});
                $ollama->clear_endpoint;  # Force rebuild of endpoint URL
                
                # Test connection first
                if ($ollama->check_connection()) {
                    $server_info->{connected} = 1;
                    
                    # Get installed models
                    my $installed = $ollama->list_models();
                    if ($installed && ref($installed) eq 'ARRAY') {
                        $server_info->{installed_models} = $installed;
                        
                        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                            'models', "Retrieved " . scalar(@$installed) . " installed models from $config->{host}:$config->{port}");
                    } else {
                        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
                            'models', "Failed to get installed models from $config->{host}:$config->{port}: " . ($ollama->last_error || 'unknown error'));
                    }
                    
                    # Get available models (static catalog), then exclude already-installed ones
                    my $available = $ollama->list_available_models();
                    if ($available && ref($available) eq 'ARRAY') {
                        # Build a set of installed base names (strip tag) for fast lookup
                        my %installed_names;
                        for my $m (@{ $server_info->{installed_models} || [] }) {
                            my $n = ref($m) ? ($m->{name} || '') : ($m || '');
                            $n =~ s/:.*$//;   # strip tag (e.g. "llama3.1:latest" → "llama3.1")
                            $installed_names{$n} = 1;
                            $installed_names{$m->{name} || $m} = 1 if ref($m);  # also full name
                        }
                        my @not_installed = grep {
                            my $aname = ref($_) ? ($_->{name} || '') : ($_ || '');
                            (my $abase = $aname) =~ s/:.*$//;
                            !$installed_names{$aname} && !$installed_names{$abase};
                        } @$available;
                        $server_info->{available_models} = \@not_installed;

                        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__,
                            'models', "Catalog: " . scalar(@$available) . " total, "
                                . scalar(@not_installed) . " not yet installed");
                    }
                } else {
                    $server_info->{error} = "Connection test failed: " . ($ollama->last_error || 'unknown error');
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
                        'models', "Connection test failed for $config->{host}:$config->{port}: " . ($ollama->last_error || 'unknown error'));
                }
            } else {
                $server_info->{error} = "Failed to load Ollama model";
            }
        } catch {
            $server_info->{error} = "Connection failed: $_";
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
                'models', "Failed to connect to server $config->{host}:$config->{port}: $_");
        };
        
        push @$servers, $server_info;
    }
    
    # Fetch user's API keys
    my @user_api_keys;
    try {
        my $schema = $c->model('DBEncy')->schema;
        my $user_id = $c->session->{user_id};
        
        if ($user_id) {
            my $keys_rs = $schema->resultset('UserApiKeys')->search(
                { user_id => $user_id, is_active => '1' },
                { order_by => { -asc => 'service' } }
            );
            
            foreach my $key ($keys_rs->all) {
                push @user_api_keys, {
                    id => $key->id,
                    service => $key->service,
                    created_at => $key->created_at->strftime('%Y-%m-%d'),
                    has_key => $key->api_key_encrypted ? 1 : 0
                };
            }
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'models', "Found " . scalar(@user_api_keys) . " API keys for user $username");
        }
    } catch {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'models', "Failed to fetch user API keys: $_");
    };
    
    # Set template variables
    $c->stash(
        template => 'ai/models.tt',
        page_title => 'AI Models',
        username => $username,
        servers => $servers,
        can_select_model => $can_select_model,
        servers_json => encode_json($servers || []),
        user_api_keys => \@user_api_keys
    );

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
        'models', "AI models interface loaded for user: $username (can_select: " . ($can_select_model ? 'yes' : 'no') . ") with " . scalar(@$servers) . " servers configured");
}

=head2 pull_model

Pull (download) a model from Ollama library on a specific server.

=cut

sub pull_model :Local :Args(0) {
    my ($self, $c) = @_;
    
    # Set response content type
    $c->response->content_type('application/json');
    
    # Check authentication
    unless ($c->session->{username}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'pull_model', "Unauthorized access attempt to AI pull model");
        
        my $error_response = encode_json({
            success => JSON::false,
            error => 'Authentication required'
        });
        $c->response->body($error_response);
        $c->response->status(401);
        return;
    }
    
    my $username = $c->session->{username};
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
        'pull_model', "Processing AI pull model request");
    
    # Get JSON payload
    my $json_data;
    try {
        my $body = $c->request->body_data;
        if ($body && ref($body) eq 'HASH') {
            $json_data = $body;
        } else {
            # Try to parse raw body as JSON
            my $raw_body = $c->request->body;
            $json_data = decode_json($raw_body) if $raw_body;
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
            'pull_model', "Failed to parse JSON request body: $_");
    };
    
    unless ($json_data) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'pull_model', "No JSON data received in pull model request");
        
        my $error_response = encode_json({
            success => JSON::false,
            error => 'Invalid JSON request'
        });
        $c->response->body($error_response);
        $c->response->status(400);
        return;
    }
    
    # Get parameters
    my $model_name = $json_data->{model} || '';
    my $server_host = $json_data->{host} || 'localhost';
    my $server_port = $json_data->{port} || 11434;
    
    # Validate model name
    unless ($model_name && length($model_name) > 0) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'pull_model', "Empty model name provided by user: $username");
        
        my $error_response = encode_json({
            success => JSON::false,
            error => 'Model name is required'
        });
        $c->response->body($error_response);
        $c->response->status(400);
        return;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
        'pull_model', "Pull model request from user '$username': $model_name on $server_host:$server_port");
    
    my $response_data;
    
    try {
        # Get Ollama model
        my $ollama = $c->model('Ollama');
        unless ($ollama) {
            die "Failed to load Ollama model";
        }
        
        # Configure for specific server
        $ollama->host($server_host);
        $ollama->port($server_port);
        $ollama->clear_endpoint;  # Force rebuild of endpoint URL
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
            'pull_model', "Ollama model configured for $server_host:$server_port, pulling model...");
        
        # Pull the model
        my $result = $ollama->pull_model(model => $model_name);
        
        unless ($result && $result->{success}) {
            my $error = $result->{error} || $ollama->last_error || 'Unknown error';
            die "Model pull failed: $error";
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
            'pull_model', "Model pull successful for user '$username': $model_name on $server_host:$server_port");
        
        # Build JSON response
        $response_data = {
            success => JSON::true,
            message => $result->{message} || "Model $model_name pulled successfully",
            model => $model_name,
            server => "$server_host:$server_port"
        };
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
            'pull_model', "Model pull failed for user '$username': $error");
        
        $response_data = {
            success => JSON::false,
            error => 'Failed to pull model: ' . $error
        };
        $c->response->status(500);
    };
    
    my $json_response = encode_json($response_data);
    $c->response->body($json_response);
}

=head2 test_model

Test a specific model on a server to verify it works correctly.

=cut

sub test_model :Local :Args(0) {
    my ($self, $c) = @_;
    
    # Set response content type
    $c->response->content_type('application/json');
    
    # Check authentication
    unless ($c->session->{username}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'test_model', "Unauthorized access attempt to AI test model");
        
        my $error_response = encode_json({
            success => JSON::false,
            error => 'Authentication required'
        });
        $c->response->body($error_response);
        $c->response->status(401);
        return;
    }
    
    my $username = $c->session->{username};
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
        'test_model', "Processing AI test model request");
    
    # Get parameters from query string
    my $model_name = $c->request->params->{model} || '';
    my $server_host = $c->request->params->{host} || 'localhost';
    my $server_port = $c->request->params->{port} || 11434;
    
    # Validate model name
    unless ($model_name && length($model_name) > 0) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'test_model', "Empty model name provided by user: $username");
        
        my $error_response = encode_json({
            success => JSON::false,
            error => 'Model name is required'
        });
        $c->response->body($error_response);
        $c->response->status(400);
        return;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
        'test_model', "Test model request from user '$username': $model_name on $server_host:$server_port");
    
    my $response_data;
    
    try {
        # Get Ollama model
        my $ollama = $c->model('Ollama');
        unless ($ollama) {
            die "Failed to load Ollama model";
        }
        
        # Configure for specific server
        $ollama->host($server_host);
        $ollama->port($server_port);
        $ollama->model($model_name);  # Set the specific model to test
        $ollama->clear_endpoint;  # Force rebuild of endpoint URL
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
            'test_model', "Ollama model configured for $server_host:$server_port, testing model...");
        
        # Test the model with a simple query
        my $test_response = $ollama->query(
            prompt => "Hello, please respond with 'Test successful' to confirm you're working.",
            system => undef
        );
        
        unless ($test_response && $test_response->{response}) {
            my $error = $ollama->last_error || 'No response received';
            die "Model test failed: $error";
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
            'test_model', "Model test successful for user '$username': $model_name on $server_host:$server_port");
        
        # Build JSON response
        $response_data = {
            success => JSON::true,
            message => "Model test successful",
            model => $model_name,
            server => "$server_host:$server_port",
            response => $test_response->{response},
            model_used => $test_response->{model} || $model_name
        };
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
            'test_model', "Model test failed for user '$username': $error");
        
        $response_data = {
            success => JSON::false,
            error => 'Failed to test model: ' . $error
        };
        $c->response->status(500);
    };
    
    my $json_response = encode_json($response_data);
    $c->response->body($json_response);
}

=head2 remove_model

Remove (delete) an installed Ollama model from a specific server.

=cut

sub remove_model :Local :Args(0) {
    my ($self, $c) = @_;
    
    # Set response content type
    $c->response->content_type('application/json');
    
    # Check authentication
    unless ($c->session->{username}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'remove_model', "Unauthorized access attempt to AI remove model");
        
        my $error_response = encode_json({
            success => JSON::false,
            error => 'Authentication required'
        });
        $c->response->body($error_response);
        $c->response->status(401);
        return;
    }
    
    my $username = $c->session->{username};
    
    # Check user permissions for model management
    my $user_roles = $c->session->{roles} || [];
    if (!ref($user_roles)) {
        $user_roles = [split(/\s*,\s*/, $user_roles)] if $user_roles;
    }
    my $can_manage_models = 0;
    if (ref($user_roles) eq 'ARRAY') {
        $can_manage_models = grep { $_ =~ /^(admin|developer)$/i } @$user_roles;
    }
    
    unless ($can_manage_models) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'remove_model', "Unauthorized model removal attempt by user: $username");
        
        my $error_response = encode_json({
            success => JSON::false,
            error => 'Insufficient permissions to remove models'
        });
        $c->response->body($error_response);
        $c->response->status(403);
        return;
    }
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
        'remove_model', "Processing AI remove model request");
    
    # Get JSON payload
    my $json_data;
    try {
        my $body = $c->request->body_data;
        if ($body && ref($body) eq 'HASH') {
            $json_data = $body;
        } else {
            # Try to parse raw body as JSON
            my $raw_body = $c->request->body;
            $json_data = decode_json($raw_body) if $raw_body;
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
            'remove_model', "Failed to parse JSON request body: $_");
    };
    
    unless ($json_data) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'remove_model', "No JSON data received in remove model request");
        
        my $error_response = encode_json({
            success => JSON::false,
            error => 'JSON data is required'
        });
        $c->response->body($error_response);
        $c->response->status(400);
        return;
    }
    
    # Extract parameters
    my $model_name = $json_data->{model} || '';
    my $server_host = $json_data->{host} || 'localhost';
    my $server_port = $json_data->{port} || 11434;
    
    # Validate model name
    unless ($model_name && length($model_name) > 0) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'remove_model', "Empty model name provided by user: $username");
        
        my $error_response = encode_json({
            success => JSON::false,
            error => 'Model name is required'
        });
        $c->response->body($error_response);
        $c->response->status(400);
        return;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
        'remove_model', "Remove model request from user '$username': $model_name on $server_host:$server_port");
    
    my $response_data;
    
    try {
        # Get Ollama model
        my $ollama = $c->model('Ollama');
        unless ($ollama) {
            die "Failed to load Ollama model";
        }
        
        # Configure for specific server
        $ollama->host($server_host);
        $ollama->port($server_port);
        $ollama->clear_endpoint;  # Force rebuild of endpoint URL
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
            'remove_model', "Ollama model configured for $server_host:$server_port, removing model...");
        
        # Remove the model
        my $result = $ollama->remove_model(model => $model_name);
        
        unless ($result && $result->{success}) {
            my $error = $result->{error} || $ollama->last_error || 'Unknown error';
            die "Model removal failed: $error";
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
            'remove_model', "Model removal successful for user '$username': $model_name on $server_host:$server_port");
        
        # Build JSON response
        $response_data = {
            success => JSON::true,
            message => $result->{message} || "Model '$model_name' removed successfully",
            model => $model_name,
            server => "$server_host:$server_port"
        };
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
            'remove_model', "Model removal failed for user '$username': $error");
        
        $response_data = {
            success => JSON::false,
            error => 'Failed to remove model: ' . $error
        };
        $c->response->status(500);
    };
    
    my $json_response = encode_json($response_data);
    $c->response->body($json_response);
}

=head2 unload_model

Force-unload a model from Ollama memory (keep_alive=0).
Requires admin/developer role.  Accepts JSON body: { model, host, port }

=cut

sub unload_model :Local :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');

    my $username  = $c->session->{username} || '';
    my $roles_ref = $c->session->{roles}    || [];
    $roles_ref = [split(/\s*,\s*/, $roles_ref)] unless ref($roles_ref);
    my $is_admin  = grep { /^(admin|developer)$/i } @$roles_ref;

    unless ($username && $is_admin) {
        $c->response->status(403);
        $c->response->body(encode_json({ success => JSON::false, error => 'Admin access required' }));
        return;
    }

    my $json_data  = {};
    my $body_text  = $c->request->content || '';
    eval { $json_data = decode_json($body_text) if $body_text; };

    my $model_name  = $json_data->{model}  || '';
    my $server_host = $json_data->{host}   || '127.0.0.1';
    my $server_port = $json_data->{port}   || 11434;

    unless ($model_name) {
        $c->response->status(400);
        $c->response->body(encode_json({ success => JSON::false, error => 'Model name required' }));
        return;
    }

    my $ollama = Comserv::Model::Ollama->new;
    $ollama->host($server_host);
    $ollama->port($server_port);
    $ollama->clear_endpoint;

    my $result = $ollama->unload_model(model => $model_name);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'unload_model', "Unload '$model_name' on $server_host:$server_port by $username — " .
        ($result->{success} ? 'OK' : ('FAILED: ' . ($result->{error} || '?'))));

    $c->response->status($result->{success} ? 200 : 500);
    $c->response->body(encode_json($result));
}

=head2 running_models

Return the list of models currently loaded in Ollama memory (/api/ps).
Requires admin/developer role.

=cut

sub running_models :Local :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');

    my $username  = $c->session->{username} || '';
    my $roles_ref = $c->session->{roles}    || [];
    $roles_ref = [split(/\s*,\s*/, $roles_ref)] unless ref($roles_ref);
    my $is_admin  = grep { /^(admin|developer)$/i } @$roles_ref;

    unless ($username && $is_admin) {
        $c->response->status(403);
        $c->response->body(encode_json({ success => JSON::false, error => 'Admin access required' }));
        return;
    }

    my $host = $c->request->params->{host} || '127.0.0.1';
    my $port = $c->request->params->{port} || 11434;

    my $ollama = Comserv::Model::Ollama->new;
    $ollama->host($host);
    $ollama->port($port);
    $ollama->clear_endpoint;

    my $running = $ollama->get_running_models();

    $c->response->body(encode_json({ success => JSON::true, models => $running }));
}

=head2 check_status

Check Ollama service connectivity. Returns JSON status.

=cut

sub check_status :Local :Args(0) {
    my ($self, $c) = @_;
    
    # Set response content type
    $c->response->content_type('application/json');
    
    # Check authentication
    unless ($c->session->{username}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'check_status', "Unauthorized access attempt to AI status check");
        
        my $error_response = encode_json({
            success => JSON::false,
            error => 'Authentication required'
        });
        $c->response->body($error_response);
        $c->response->status(401);
        return;
    }
    
    my $username = $c->session->{username};
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
        'check_status', "Checking Ollama status for user: $username");
    
    my $status_data;
    
    try {
        # Get Ollama model
        my $ollama = $c->model('Ollama');
        unless ($ollama) {
            die "Failed to load Ollama model";
        }
        
        # Check connection
        my $is_connected = $ollama->check_connection();
        
        $status_data = {
            success => JSON::true,
            connected => $is_connected ? JSON::true : JSON::false,
            endpoint => $ollama->endpoint || 'Unknown',
            model => $ollama->model || 'Unknown'
        };
        
        my $status_text = $is_connected ? 'connected' : 'disconnected';
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
            'check_status', "Ollama status check for user '$username': $status_text");
        
        # Add error details if disconnected
        if (!$is_connected) {
            my $error = $ollama->last_error || 'Connection failed';
            $status_data->{error} = $error;
        }
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
            'check_status', "Status check failed for user '$username': $error");
        
        $status_data = {
            success => JSON::false,
            connected => JSON::false,
            error => 'Failed to check Ollama status'
        };
    };
    
    my $json_response = encode_json($status_data);
    $c->response->body($json_response);
}

=head2 set_host

Switch the Ollama server host (admin/developer/editor only).

=cut

sub set_host :Local :Args(0) {
    my ($self, $c) = @_;
    
    # Set response content type
    $c->response->content_type('application/json');
    
    # Check authentication
    unless ($c->session->{username}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'set_host', "Unauthorized access attempt to AI set host");
        
        my $error_response = encode_json({
            success => JSON::false,
            error => 'Authentication required'
        });
        $c->response->body($error_response);
        $c->response->status(401);
        return;
    }
    
    my $username = $c->session->{username};
    
    # Check permissions - only admin/developer/editor can change hosts
    my $user_roles = $c->session->{roles} || [];
    if (!ref($user_roles)) {
        $user_roles = [split(/\s*,\s*/, $user_roles)] if $user_roles;
    }
    my $can_select_model = 0;
    if (ref($user_roles) eq 'ARRAY') {
        $can_select_model = grep { $_ =~ /^(admin|developer|editor)$/i } @$user_roles;
    }
    
    unless ($can_select_model) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'set_host', "Unauthorized host change attempt by user: $username");
        
        my $error_response = encode_json({
            success => JSON::false,
            error => 'Insufficient permissions to change server'
        });
        $c->response->body($error_response);
        $c->response->status(403);
        return;
    }
    
    # Parse JSON body
    my $json_data;
    try {
        my $body = $c->request->body;
        if ($body) {
            seek($body, 0, 0);  # Reset file handle position
            my $json_text = do { local $/; <$body> };
            $json_data = decode_json($json_text) if $json_text;
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
            'set_host', "Failed to parse JSON body: $_");
    };
    
    unless ($json_data && $json_data->{host}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'set_host', "No host provided in set host request");
        
        my $error_response = encode_json({
            success => JSON::false,
            error => 'Host parameter is required'
        });
        $c->response->body($error_response);
        $c->response->status(400);
        return;
    }
    
    my $new_host = $json_data->{host};
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
        'set_host', "Host change request from user '$username': $new_host");
    
    my $response_data;
    
    try {
        # Get Ollama model
        my $ollama = $c->model('Ollama');
        unless ($ollama) {
            die "Failed to load Ollama model";
        }
        
        # Set the new host
        unless ($ollama->set_host($new_host)) {
            my $error = $ollama->last_error || 'Unknown error';
            die "Failed to set host: $error";
        }
        
        # Test connection to the new host
        unless ($ollama->check_connection()) {
            my $error = $ollama->last_error || 'Connection test failed';
            die "Connection to new host failed: $error";
        }
        
        # Store the new host in session for persistence
        $c->session->{ollama_host} = $new_host;
        
        # Get connection info for response
        my $conn_info = $ollama->get_connection_info();
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
            'set_host', "Host successfully changed to $new_host for user '$username'");
        
        # Build JSON response
        $response_data = {
            success => JSON::true,
            message => "Successfully switched to $new_host",
            connection_info => $conn_info
        };
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
            'set_host', "Host change failed for user '$username': $error");
        
        $response_data = {
            success => JSON::false,
            error => "Failed to switch host: $error"
        };
        $c->response->status(500);
    };
    
    my $json_response = encode_json($response_data);
    $c->response->body($json_response);
}

=head2 start_server

Start the Ollama server. Supports both systemctl and direct command methods.
Only allows starting localhost server.

=cut

sub start_server :Local :Args(0) {
    my ($self, $c) = @_;
    
    # Set response content type
    $c->response->content_type('application/json');
    
    # Check authentication
    unless ($c->session->{username}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'start_server', "Unauthorized access attempt to AI start server");
        
        my $error_response = encode_json({
            success => JSON::false,
            error => 'Authentication required'
        });
        $c->response->body($error_response);
        $c->response->status(401);
        return;
    }
    
    my $username = $c->session->{username};
    
    # Check permissions - only admin/developer/editor can start servers
    my $user_roles = $c->session->{roles} || [];
    if (!ref($user_roles)) {
        $user_roles = [split(/\s*,\s*/, $user_roles)] if $user_roles;
    }
    my $can_manage_servers = 0;
    if (ref($user_roles) eq 'ARRAY') {
        $can_manage_servers = grep { $_ =~ /^(admin|developer|editor)$/i } @$user_roles;
    }
    
    unless ($can_manage_servers) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'start_server', "Unauthorized server start attempt by user: $username");
        
        my $error_response = encode_json({
            success => JSON::false,
            error => 'Insufficient permissions to start servers'
        });
        $c->response->body($error_response);
        $c->response->status(403);
        return;
    }
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
        'start_server', "Processing AI start server request");
    
    # Get JSON payload
    my $json_data;
    try {
        my $body = $c->request->body_data;
        if ($body && ref($body) eq 'HASH') {
            $json_data = $body;
        } else {
            # Try to parse raw body as JSON
            my $raw_body = $c->request->body;
            $json_data = decode_json($raw_body) if $raw_body;
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
            'start_server', "Failed to parse JSON request body: $_");
    };
    
    unless ($json_data) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'start_server', "No JSON data received in start server request");
        
        my $error_response = encode_json({
            success => JSON::false,
            error => 'JSON data is required'
        });
        $c->response->body($error_response);
        $c->response->status(400);
        return;
    }
    
    # Extract parameters
    my $server_host = $json_data->{host} || 'localhost';
    my $server_port = $json_data->{port} || 11434;
    my $method = $json_data->{method} || 'systemctl';  # Default to systemctl
    my $async = $json_data->{async} || 0;              # Default to synchronous
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
        'start_server', "Start server request from user '$username': host=$server_host, port=$server_port, method=$method, async=$async");
    
    my $response_data;
    
    try {
        # Get Ollama model
        my $ollama = $c->model('Ollama');
        unless ($ollama) {
            die "Failed to load Ollama model";
        }
        
        # Configure for specific server
        $ollama->host($server_host);
        $ollama->port($server_port);
        $ollama->clear_endpoint;  # Force rebuild of endpoint URL
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
            'start_server', "Ollama model configured for $server_host:$server_port, attempting to start server...");
        
        # Start the server
        my $result = $ollama->start_server(
            method => $method,
            async => $async
        );
        
        unless ($result && $result->{success}) {
            my $error = $result->{error} || $ollama->last_error || 'Unknown error';
            die "Server start failed: $error";
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
            'start_server', "Server start successful for user '$username': $server_host:$server_port via $method");
        
        # Build JSON response
        $response_data = {
            success => JSON::true,
            message => $result->{message} || "Ollama server started successfully",
            server => "$server_host:$server_port",
            method => $method,
            already_running => $result->{already_running} ? JSON::true : JSON::false,
            connection_pending => $result->{connection_pending} ? JSON::true : JSON::false
        };
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
            'start_server', "Server start failed for user '$username': $error");
        
        $response_data = {
            success => JSON::false,
            error => 'Failed to start server: ' . $error
        };
        $c->response->status(500);
    };
    
    my $json_response = encode_json($response_data);
    $c->response->body($json_response);
}

=head2 _get_module_data

Fetch live application data relevant to the user's prompt and return it as a
context string to append to the system prompt.  The fetch uses the Catalyst
context so it automatically respects the current user's session / role.

  $c        - Catalyst context
  $prompt   - the user's raw query text
  $agent_id - agent id string (e.g. 'bmaster', 'csc')

Returns a string of data context, or empty string when nothing relevant found.

=cut

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

    # --- Todo / Task data ---
    # Triggers on todo keywords OR when asking about project state/status/progress
    my $want_todos = ($prompt =~ /todo|task|overdue|due|deadline|priority|critical|reschedul|plan|backlog/i)
                  || ($prompt =~ /project/i && $prompt =~ /state|status|progress|what|how|summar|complet|done|remain|left|next/i);

    if ($want_todos) {
        eval {
            my $schema = $c->model('DBEncy')->schema;
            if ($schema) {
                my $rs = $schema->resultset('Todo');

                # Build project name map for display
                my %proj_name;
                eval {
                    my $projects = $c->model('Project')->get_projects($schema, $site_name);
                    if ($projects) {
                        $proj_name{$_->id} = $_->name for @$projects;
                    }
                };

                # Fetch all active todos for this site (status != 3 = not done)
                # For CSC admins, show all sites
                my %site_filter = (status => { '!=' => 3 });
                my $roles = $c->session->{roles} || [];
                my $is_admin = grep { /^(admin|developer)$/i } (ref $roles eq 'ARRAY' ? @$roles : ());
                unless ($is_admin && lc($site_name) eq 'csc') {
                    $site_filter{sitename} = $site_name;
                }

                my @todos = $rs->search(
                    \%site_filter,
                    { order_by => [{ -asc => 'priority' }, { -asc => 'due_date' }], rows => 40 }
                );

                if (@todos) {
                    my (@overdue, @due_soon, @other);
                    for my $t (@todos) {
                        my $due  = $t->due_date   // '';
                        my $subj = $t->subject    // 'Untitled';
                        my $pri  = $t->priority   // 99;
                        my $proj_id = $t->project_id // '';
                        my $proj_label = $proj_id
                            ? ($proj_name{$proj_id} ? "$proj_name{$proj_id} (#$proj_id)" : "#$proj_id")
                            : '';
                        my $id   = $t->record_id  // '';
                        my $stat = $t->status     // '';
                        my $stat_label = $stat == 1 ? 'NEW'
                                       : $stat == 2 ? 'IN PROGRESS'
                                       : $stat == 3 ? 'DONE'
                                       : "status=$stat";
                        my $line = "  [#$id] P$pri | $subj"
                            . ($due        ? " | Due: $due" : " | No due date")
                            . ($proj_label ? " | Project: $proj_label" : '')
                            . " | $stat_label";

                        if ($due && $due lt $today) {
                            push @overdue,  "OVERDUE $line";
                        } elsif ($due) {
                            push @due_soon, $line;
                        } else {
                            push @other, $line;
                        }
                    }

                    my $block = "LIVE TODO DATA (current as of query time) for site '$site_name':\n";
                    if (@overdue) {
                        $block .= "OVERDUE ITEMS (need rescheduling or urgent action):\n"
                               . join("\n", @overdue) . "\n";
                    }
                    if (@due_soon) {
                        $block .= "UPCOMING ITEMS:\n" . join("\n", @due_soon) . "\n";
                    }
                    if (@other) {
                        $block .= "OTHER ACTIVE ITEMS:\n" . join("\n", @other) . "\n";
                    }
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
                        my $id   = $p->id          // '';
                        my $name = $p->name        // 'Unnamed';
                        my $desc = $p->description // '';
                        $desc = substr($desc, 0, 80) . '…' if length($desc) > 80;
                        push @lines, "  [ID=$id] $name" . ($desc ? " — $desc" : '');
                    }
                    push @sections,
                        "LIVE PROJECT DATA for site '$site_name':\n"
                        . join("\n", @lines)
                        . "\nView project details at /project/details?project_id=ID (replace ID with the number above)";
                }
            }
        };
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            '_get_module_data', "Project fetch error: $@") if $@;
    }

    # --- ENCY / Herb / Plant / Bee forage data ---
    if ($prompt =~ /plant|herb|flower|forage|pasture|nectar|pollen|bee\s*food|pollinator|garden|grow/i) {
        eval {
            my $forager = $c->model('DBForager');
            if ($forager) {
                # Extract key search terms from the prompt
                my @keywords = ($prompt =~ /(\w{4,})/g);
                my $search   = join(' ', grep { /plant|herb|flower|forage|nectar|pollen|bee|grow|garden/i } @keywords);
                $search ||= 'bee';

                my $results = $forager->searchHerbs($c, $search);
                if ($results && @$results) {
                    my @lines;
                    my $last = $#$results < 14 ? $#$results : 14;
                    for my $h (@{$results}[0..$last]) {
                        my $name   = $h->botanical_name // '';
                        my $common = $h->common_names   // '';
                        my $nectar = $h->nectar         // '';
                        my $pollen = $h->pollen         // '';
                        my $apis   = $h->apis           // '';
                        my $id     = $h->record_id      // '';
                        push @lines, "  [#$id] $name"
                            . ($common ? " ($common)" : '')
                            . ($nectar ? " | Nectar: $nectar" : '')
                            . ($pollen ? " | Pollen: $pollen" : '')
                            . ($apis   ? " | Bee use: $apis"  : '');
                    }
                    if (@lines) {
                        push @sections,
                            "LIVE ENCY HERB/PLANT DATA (search: '$search'):\n"
                            . join("\n", @lines)
                            . "\nView full encyclopedia at /ENCY | Bee forage plants at /ENCY/BeePastureView";
                    }
                }
            }
        };
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            '_get_module_data', "ENCY herb fetch error: $@") if $@;
    }

    return join("\n\n", @sections);
}

=head2 _search_shared_history

Search the shared ai_messages table (all users, all conversations) for past
Q&A pairs that share keywords with the current prompt.  Returns up to 3 pairs
formatted as a context block, or empty string when nothing useful is found.

=cut

sub _search_shared_history {
    my ($self, $c, $prompt, $site_name) = @_;
    $prompt    //= '';
    $site_name //= '';

    return '' unless length($prompt) > 5;

    eval {
        # Extract keywords: words > 4 chars, deduplicated
        my %seen_kw;
        my @keywords = grep { length($_) > 4 && !$seen_kw{lc $_}++ }
                       ($prompt =~ /(\b\w{5,}\b)/g);
        return '' unless @keywords;
        my @kw = @keywords[0 .. ($#keywords < 7 ? $#keywords : 7)]; # max 8 keywords

        my $schema = $c->model('DBEncy')->schema;
        return '' unless $schema;

        # Build LIKE conditions for each keyword
        my @conds = map { { 'me.content' => { -like => "%$_%" } } } @kw;
        # Need at least 2 keyword matches — use OR and post-filter
        my $user_msgs = $schema->resultset('AiMessage')->search(
            {
                'me.role' => 'user',
                -or       => \@conds,
            },
            {
                order_by => { -desc => 'me.created_at' },
                rows     => 30,
                prefetch => 'conversation',
            }
        );

        my @pairs;
        my %seen_answer;
        while (my $q_msg = $user_msgs->next) {
            last if @pairs >= 3;
            my $q_content = $q_msg->content // '';
            next if length($q_content) < 5;

            # Score: count how many keywords appear
            my $score = grep { $q_content =~ /\Q$_\E/i } @kw;
            next if $score < 2;

            # Find the next assistant message in the same conversation
            my $a_msg = $schema->resultset('AiMessage')->search(
                {
                    conversation_id => $q_msg->conversation_id,
                    role            => 'assistant',
                    id              => { '>' => $q_msg->id },
                },
                { order_by => { -asc => 'id' }, rows => 1 }
            )->first;
            next unless $a_msg;

            my $answer = $a_msg->content // '';
            next if length($answer) < 20;
            next if $seen_answer{substr($answer, 0, 80)}++;  # deduplicate

            push @pairs, "Q: $q_content\nA: " . substr($answer, 0, 400);
        }

        return '' unless @pairs;
        return "RELEVANT PAST ANSWERS (from shared knowledge base — use as context, do not just repeat):\n"
             . join("\n---\n", @pairs);
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            '_search_shared_history', "History search error: $@");
    }
    return '';
}

=head2 _assess_response_quality

Simple heuristic quality check on an AI response.
Returns 'good' or 'poor'.

Poor indicators:
  - Very short (< 60 words)
  - Contains "I don't know", "I cannot", "no information", "I'm not sure", "don't have access"
  - Mostly repeats the question back

=cut

sub _assess_response_quality {
    my ($self, $response, $prompt) = @_;
    $response //= '';
    $prompt   //= '';

    my $word_count = scalar(split /\s+/, $response);
    return 'poor' if $word_count < 30;

    my @uncertain_phrases = (
        "i don't know", "i do not know", "i cannot", "i can't",
        "no information", "i'm not sure", "i am not sure",
        "don't have access", "do not have access",
        "unable to answer", "cannot answer", "no relevant",
        "i don't have that", "not in my knowledge",
    );
    my $lc_resp = lc($response);
    for my $phrase (@uncertain_phrases) {
        return 'poor' if index($lc_resp, $phrase) >= 0;
    }

    return 'good';
}

=head2 _pick_ollama_tier

Given the installed models list, return (small_model, large_model).
Small = tinyllama or smallest by name; Large = llama3.1 or largest by name.

=cut

sub _pick_ollama_tier {
    my ($self, $installed_models, $default_model, $agent_id, $page_context) = @_;

    # Filter to local chat-capable models only.
    # Exclude: embedding/reranker models, code-only models, and :cloud models
    # (cloud-routed Ollama models need external API keys and will timeout).
    my @chat_models = grep {
        my $n = ref($_) ? ($_->{name} || '') : ($_ || '');
        $n && $n !~ /embed|rerank|bge|nomic|clip|whisper|tts/i
           && $n !~ /:cloud$/i
           && $n !~ /starcoder|coder|codellama/i;
    } @$installed_models;

    my @names = map { ref($_) ? ($_->{name} || '') : ($_ || '') } @chat_models;

    # Score models by parameter count (billions).
    # Known families mapped first; then extract Nb from name; then defaults.
    my %size_score;
    my %known_family = (
        'tinyllama'  => 1,
        'llama3.2'   => 3,
        'llama3.1'   => 8, 'llama3'   => 8, 'llama2' => 7,
        'mistral'    => 7, 'mixtral'  => 47,
        'qwen2.5'    => 7, 'qwen2'    => 7,
        'phi3'       => 4, 'phi'      => 2,
        'gemma2'     => 9, 'gemma'    => 7,
    );
    for my $n (@names) {
        my $score;
        # 1. Explicit Nb in name (deepseek-r1:7b, llama2:13b, etc.)
        if ($n =~ /[:\-](\d+)b/i) { $score = $1; }
        # 2. Known family prefix
        unless ($score) {
            for my $family (sort { length($b) <=> length($a) } keys %known_family) {
                if (index(lc($n), lc($family)) == 0) { $score = $known_family{$family}; last; }
            }
        }
        # 3. Generic hints
        $score //= $n =~ /tiny/i   ? 1
                 : $n =~ /small/i  ? 3
                 : $n =~ /mini/i   ? 3
                 : $n =~ /medium/i ? 7
                 : $n =~ /large/i  ? 13
                 :                   7;
        $size_score{$n} = $score;
    }

    my @sorted = sort { ($size_score{$a} || 7) <=> ($size_score{$b} || 7) } @names;

    # Exclude sub-2B toy models (tinyllama, 1.1b, etc.) from auto-selection —
    # they produce unreliable answers.  Only fall back to them if nothing better exists.
    my @usable = grep { ($size_score{$_} // 7) >= 3 } @sorted;
    @usable = @sorted unless @usable;  # fallback if ALL models are tiny

    my $small = $usable[0]  || $default_model || 'llama3.1:latest';
    my $large = $usable[-1] || $default_model || 'llama3.1:latest';

    # Only escalate if large model is meaningfully bigger (2x+).
    # If both tiers are similar size, keep them the same to avoid loading two models.
    $large = $small if @sorted <= 1;
    $large = $small if ($size_score{$large} // 7) < ($size_score{$small} // 7) * 2;

    return ($small, $large);
}

=head2 _build_role_system_prompt

Build a role-aware addition to the system prompt granting or restricting
capabilities based on the user's session roles and current page context.

  admin/developer/editor  → full internal API access (workshop, ency, todo, project)
                            + page-specific navigation guidance with edit permissions
  normal user             → general help + page-specific read/interact guidance
  guest                   → HelpDesk, navigation, documentation only (read-only)

Optional page_path and page_title parameters provide context-aware navigation hints.

=cut

sub _build_role_system_prompt {
    my ($self, $c, $roles, $provider, $page_path, $page_title) = @_;

    $roles     //= [];
    $provider  //= 'ollama';
    $page_path //= '';
    $page_title //= '';

    my $base_url = '';
    eval { $base_url = $c->uri_for('/') . ''; $base_url =~ s{/$}{}; };

    my @role_list = ref($roles) eq 'ARRAY' ? @$roles : split(/\s*,\s*/, $roles || '');
    my $is_admin = grep { /^(admin|developer|editor)$/i } @role_list;
    my $is_guest = !@role_list || (grep { /guest/i } @role_list);

    my $role_tier  = $is_admin ? 'admin' : ($is_guest ? 'guest' : 'user');
    my $page_nav   = $self->_build_page_navigation_hint($base_url, $page_path, $page_title, $role_tier);
    my $nav_guide  = $self->_build_navigation_command_guide($base_url, $role_tier);

    my $action_instructions = <<'ACTION';

IN-APP ACTIONS: You can perform write operations in the application on behalf of the logged-in user.
When the user explicitly asks you to update, reschedule, mark done, add a comment, or create a log entry for a todo — embed an action block in your response using this exact format (on its own line):
[ACTION: {"action": "ACTION_NAME", "params": {...}}]

Supported actions:
- Mark a todo done:      [ACTION: {"action": "update_todo_status", "params": {"todo_id": N, "status": 3}}]
- Mark todo in-progress: [ACTION: {"action": "update_todo_status", "params": {"todo_id": N, "status": 2}}]
- Reschedule a todo:     [ACTION: {"action": "reschedule_todo",    "params": {"todo_id": N, "due_date": "YYYY-MM-DD"}}]
- Add a comment:         [ACTION: {"action": "add_todo_comment",   "params": {"todo_id": N, "comment": "text"}}]
- Create a log entry:    [ACTION: {"action": "create_log_entry",   "params": {"todo_id": N, "abstract": "title", "details": "description"}}]

Rules:
- ONLY emit an [ACTION: ...] block when the user explicitly asks you to perform a write operation.
- ALWAYS use the real numeric todo_id from the LIVE TODO DATA above — never make up an ID.
- Include the action block in addition to your normal response text, not instead of it.
- The application will automatically execute the action and show the user a confirmation.
ACTION

    if ($is_admin) {
        my $web_search_note = ($provider eq 'grok')
            ? "Web search is available if the user has enabled it — use it to answer questions about external tools, technologies, or anything not covered by the application data."
            : "You have NO internet access for live lookups, but you DO have broad general knowledge — answer technical, how-to, and external-tool questions (e.g. PyCharm, Git, Linux, etc.) using your training knowledge.";

        return "You are a knowledgeable assistant for an ADMIN user of this application. "
             . "Admin users have full access to all application features. "
             . "Answer ALL questions to the best of your ability: "
             . "(a) General technical questions (Git, PyCharm, programming, sysadmin, etc.) — answer fully using your knowledge. "
             . "(b) Application navigation — use the navigation guide below to give direct links. "
             . "(c) Live application data (workshops, projects, tasks) — direct the user to these URLs:\n"
             . "  - Active workshops: $base_url/workshop/list_active\n"
             . "  - Encyclopedia search: $base_url/ency/search?q=TERM\n"
             . "  - Projects: $base_url/project/list (IDs shown in LIVE PROJECT DATA above)\n"
             . "  - Project todos: $base_url/todo/list?project_id=N (use real ID from live data, never literal 'ID')\n"
             . "Do NOT refuse to answer general knowledge questions. "
             . "Do NOT invent live application data — direct the user to the relevant URL instead. "
             . $web_search_note . "\n"
             . "NAVIGATION: When the user says 'take me to', 'open', 'go to', or 'show me' a page, "
             . "reply with the exact URL from the navigation guide below.\n"
             . $action_instructions
             . $page_nav
             . $nav_guide;
    }

    if ($is_guest) {
        my $guest_knowledge = ($provider eq 'grok')
            ? " You may use web search if the user has enabled it."
            : " For questions outside the application scope, provide helpful general guidance using your training knowledge while noting you cannot access live internet data.";
        return "You are a helpful assistant for guest (not logged in) users. "
             . "Provide: navigation help, general application guidance, public documentation, "
             . "and general knowledge answers for questions about software, tools, or processes. "
             . "Do NOT access private data or APIs. "
             . "Never invent live application data (workshop schedules, user accounts, etc.) — say 'I don't have that live data; please log in or visit the relevant page'. "
             . "If the user needs account-specific help, ask them to log in. "
             . "SECURITY — STRICT RULE: You MUST ONLY provide URLs that appear in the navigation guide below. "
             . "NEVER mention /admin, /admin/*, or any administrative URL. "
             . "NEVER use your training knowledge to guess application URLs — only use the navigation guide. "
             . "If a user asks about the admin panel or any admin feature, say: "
             . "'That section requires administrator privileges. Please log in with an admin account or contact your system administrator.'"
             . $guest_knowledge
             . $page_nav
             . $nav_guide;
    }

    my $no_internet = ($provider ne 'grok')
        ? " You have NO access to live internet data. "
        . "For questions about current events or live website content you were not given, "
        . "say 'I don't have access to that live information' — but DO answer general technical questions using your training knowledge."
        : " Web search may be available if the user has enabled it.";

    return "You are a helpful assistant for logged-in users of this application. "
         . "Answer ALL questions to the best of your ability — application help, general technical questions, software how-tos, etc. "
         . "Do not invent live application data; if you don't know something specific to this app, say so and link to the relevant section. "
         . "NAVIGATION: When the user says 'take me to', 'open', 'go to', 'navigate to', or 'show me' a page, "
         . "respond with the URL from the navigation guide so the application can automatically navigate there. "
         . "Use the exact URL from the list — the application will redirect the browser for you. "
         . "SECURITY — STRICT RULE: You MUST ONLY provide URLs from the navigation guide. "
         . "NEVER guess or invent application URLs using your training knowledge. "
         . "NEVER provide /admin URLs to users who do not have admin role. "
         . "If the user asks about admin features and admin URLs are not in the navigation guide for their role, "
         . "say: 'That section requires administrator privileges.'"
         . $no_internet
         . $action_instructions
         . $page_nav
         . $nav_guide;
}

=head2 _build_navigation_command_guide

Build a role-filtered navigation command guide appended to every system prompt.
When a user says "take me to X" or asks how to navigate to a section, the AI
uses this map to reply with the correct URL instead of inventing one.

  $base_url - application base URL (no trailing slash)
  $role     - 'admin', 'user', or 'guest'

=cut

sub _build_navigation_command_guide {
    my ($self, $base_url, $role) = @_;

    # Each section: [ section_name, min_role, [ [label, path], ... ] ]
    # min_role: 'guest' | 'user' | 'admin'
    my @sections = (
        [ 'Home', 'guest', [
            [ 'Main menu / home',           '/'                         ],
        ]],
        [ 'Workshops', 'guest', [
            [ 'Workshops home',             '/workshop'                 ],
            [ 'Add a workshop',             '/workshop/add'             ],
        ]],
        [ 'Workshops (logged in)', 'user', [
            [ 'My workshop dashboard',      '/workshop/dashboard'       ],
        ]],
        [ 'Workshops (admin/leader)', 'admin', [
            [ 'Workshop resources',         '/workshop/resources'       ],
        ]],
        [ 'Documentation', 'guest', [
            [ 'Documentation home',         '/Documentation'            ],
            [ 'Daily plan',                 '/Documentation/DailyPlan'  ],
        ]],
        [ 'Encyclopedia (ENCY)', 'guest', [
            [ 'Encyclopedia home',          '/ENCY'                     ],
            [ 'Encyclopedia search',        '/ENCY/search'              ],
            [ 'Bee pasture / plant forage', '/ENCY/BeePastureView'      ],
        ]],
        [ 'HelpDesk', 'guest', [
            [ 'HelpDesk home',              '/HelpDesk'                 ],
            [ 'Submit a ticket',            '/HelpDesk/ticket/new'      ],
            [ 'Check ticket status',        '/HelpDesk/ticket/status'   ],
            [ 'Knowledge base',             '/HelpDesk/kb'              ],
            [ 'Contact',                    '/HelpDesk/contact'         ],
        ]],
        [ 'AI Assistant', 'guest', [
            [ 'AI chat',                    '/ai'                       ],
            [ 'AI query form',              '/ai/query_form'            ],
        ]],
        [ 'AI Assistant (logged in)', 'user', [
            [ 'AI conversations / chat history', '/ai/conversations'    ],
            [ 'Manage API keys',            '/ai/manage_api_keys'       ],
            [ 'AI in-app action endpoint',  '/ai/action'                ],
        ]],
        [ 'AI Assistant (admin)', 'admin', [
            [ 'Manage AI models',           '/ai/models'                ],
            [ 'AI server status',           '/ai/check_status'          ],
        ]],
        [ 'Tasks / Todos', 'user', [
            [ 'Todo list',                  '/todo'                     ],
            [ 'Todos by day',               '/todo?filter=day'          ],
            [ 'Todos by week',              '/todo?filter=week'         ],
            [ 'Todos by month',             '/todo?filter=month'        ],
            [ 'Add a todo',                 '/todo/addtodo'             ],
        ]],
        [ 'Projects', 'user', [
            [ 'Projects home',              '/project'                  ],
            [ 'Add a project',              '/project/addproject'       ],
        ]],
        [ 'User account', 'guest', [
            [ 'Login',                      '/user/login'               ],
            [ 'Create account',             '/user/create_account'      ],
            [ 'Forgot password',            '/user/forgot_password'     ],
        ]],
        [ 'User account (logged in)', 'user', [
            [ 'My profile',                 '/user/profile'             ],
            [ 'Account settings',           '/user/settings'            ],
            [ 'Logout',                     '/user/logout'              ],
        ]],
        [ 'Admin', 'admin', [
            [ 'Admin panel',                '/admin'                    ],
            [ 'User management',            '/admin/users'              ],
            [ 'Application logs',           '/admin/logs'               ],
            [ 'Git pull',                   '/admin/git_pull'           ],
            [ 'Docker containers',          '/admin/docker-containers'  ],
            [ 'Theme management',           '/themeadmin'               ],
            [ 'Planning',                   '/admin/planning'           ],
            [ 'System info',                '/admin/system_info'        ],
            [ 'Admin settings',             '/admin/settings'           ],
            [ 'Log viewer',                 '/log'                      ],
            [ 'File management',            '/file/list'                ],
            [ 'Duplicate files',            '/file/duplicates'          ],
        ]],
        [ 'Site management (admin)', 'admin', [
            [ 'Site list / setup',          '/site'                     ],
            [ 'Add a new site',             '/site/add_site'            ],
            [ 'Add a domain to a site',     '/site/add_domain'          ],
            [ 'Site details',               '/site/details'             ],
            [ 'Modify site',                '/site/modify'              ],
        ]],
    );

    my %role_rank = ( guest => 0, user => 1, admin => 2 );
    my $user_rank = $role_rank{$role} // 0;

    my $guide = '';
    for my $section (@sections) {
        my ($name, $min_role, $links) = @$section;
        next if ($role_rank{$min_role} // 0) > $user_rank;
        $guide .= "[$name]\n";
        for my $link (@$links) {
            $guide .= "  - $link->[0]: $base_url$link->[1]\n";
        }
    }

    return "\n\nApplication sections and navigation guide:\n"
         . "Use this map for THREE purposes:\n"
         . "1. Navigation: when the user asks to go to a page or says 'take me to [page]', "
         . "reply with the matching URL(s). List ALL links in the section when multiple apply.\n"
         . "2. Content suggestions: when answering a question, proactively mention relevant "
         . "application sections the user can visit for more information. "
         . "For example, if asked about plants or pollinators, point to the Encyclopedia (ENCY) section. "
         . "If asked about workshops, point to the Workshops section.\n"
         . "3. Link validation: when asked to check, audit, or review links on the current page, "
         . "compare EVERY link shown in the page content against this navigation guide. "
         . "Report ALL links that have no matching entry — not just the first one. "
         . "Present the full list as a numbered or bulleted list so nothing is missed.\n"
         . "Only use URLs from this list; do not invent others. "
         . "If no match exists for a navigation request, say: 'I don't know that page — visit $base_url to browse available options.'\n"
         . $guide;
}

=head2 _build_page_navigation_hint

Build a page-specific navigation hint to append to the system prompt.
Returns an empty string when no relevant context can be determined.

  $base_url  - application base URL (no trailing slash)
  $page_path - URL path of the page the user is currently on
  $page_title - display title of the current page
  $role      - 'admin', 'user', or 'guest'

=cut

sub _build_page_navigation_hint {
    my ($self, $base_url, $page_path, $page_title, $role) = @_;

    return '' unless $page_path;

    my $context_label = $page_title ? "\"$page_title\" ($page_path)" : $page_path;
    my $hint = "\n\nThe user is currently viewing: $context_label.\n";

    if ($page_path =~ m{/HelpDesk/ticket/new}i) {
        if ($role eq 'admin') {
            $hint .= "NOTE: This page has a HelpDesk pre-screening form, but you are an admin user.\n"
                   . "Answer questions about projects, todos, system state, and application features normally.\n"
                   . "Only switch to support pre-screening mode if the user explicitly describes a support problem.\n";
        } else {
            $hint .= "SUPPORT PRE-SCREENING MODE:\n"
                   . "The user has navigated to the 'Create New Ticket' page but has been invited to\n"
                   . "try the AI assistant FIRST before submitting a ticket.\n"
                   . "Your goal is to RESOLVE the user's issue so they do NOT need to submit a ticket.\n"
                   . "- Listen carefully to their problem description.\n"
                   . "- Provide clear, actionable step-by-step solutions.\n"
                   . "- Check the Knowledge Base: $base_url/HelpDesk/kb\n"
                   . "- If you solve the issue, say so clearly and tell them no ticket is needed.\n"
                   . "- If you CANNOT resolve it after trying, acknowledge this and tell them:\n"
                   . "  'It looks like this needs human support. Click \"Skip AI — Submit Ticket Directly\" on the page to open the ticket form.'\n"
                   . "Do NOT refuse to help or just redirect them to submit a ticket without genuinely trying to solve the problem first.\n";
        }
    } elsif ($page_path =~ m{/HelpDesk}i) {
        $hint .= "Navigation context — HelpDesk:\n"
               . "- Submit a new ticket: $base_url/HelpDesk/ticket/new\n"
               . "- Check ticket status: $base_url/HelpDesk/ticket/status\n"
               . "- Knowledge Base: $base_url/HelpDesk/kb\n"
               . "- Contact support: $base_url/HelpDesk/contact\n";
        $hint .= "- Admin panel: $base_url/HelpDesk/admin\n" if $role eq 'admin';
    } elsif ($page_path =~ m{/Documentation}i) {
        if ($role eq 'admin') {
            $hint .= "Navigation context — Documentation section (admin):\n"
                   . "- You may edit or create documentation pages.\n"
                   . "- Related sections: Daily Plans, Master Plan, Architecture docs.\n"
                   . "- To manage plans: $base_url/Documentation/DailyPlan\n"
                   . "- To view all docs: $base_url/Documentation\n";
        } elsif ($role eq 'user') {
            $hint .= "Navigation context — Documentation section:\n"
                   . "- You can read documentation pages and follow internal links.\n"
                   . "- To search the encyclopedia: $base_url/ency/search?q=TERM\n"
                   . "- To view all docs: $base_url/Documentation\n";
        } else {
            $hint .= "Navigation context — Documentation section (guest):\n"
                   . "- Public documentation is available for reading.\n"
                   . "- Log in for full access and editing capabilities.\n";
        }
    } elsif ($page_path =~ m{/workshop}i) {
        if ($role eq 'admin') {
            $hint .= "Navigation context — Workshops (admin):\n"
                   . "- You can create, edit, and manage workshop entries.\n"
                   . "- Active workshops: $base_url/workshop/list_active\n"
                   . "- All workshops: $base_url/workshop/list\n";
        } elsif ($role eq 'user') {
            $hint .= "Navigation context — Workshops:\n"
                   . "- You can view and participate in workshops.\n"
                   . "- Active workshops: $base_url/workshop/list_active\n";
        } else {
            $hint .= "Navigation context — Workshops (guest):\n"
                   . "- Public workshop information is available for viewing.\n"
                   . "- Log in to participate or manage workshops.\n";
        }
    } elsif ($page_path =~ m{/todo}i) {
        if ($role eq 'admin') {
            $hint .= "Navigation context — Todo / Task Management (admin):\n"
                   . "- You can view, create, assign, and close tasks across all projects.\n"
                   . "- All tasks: $base_url/todo/list\n"
                   . "- Project-specific: $base_url/todo/list?project_id=N (use real numeric ID from live project data — never literal 'ID')\n";
        } elsif ($role eq 'user') {
            $hint .= "Navigation context — Todo / Task Management:\n"
                   . "- You can view tasks assigned to you and update their status.\n"
                   . "- Your tasks: $base_url/todo/list\n";
        } else {
            $hint .= "Navigation context — Tasks (guest):\n"
                   . "- Log in to view and manage tasks.\n";
        }
    } elsif ($page_path =~ m{/project}i) {
        if ($role eq 'admin') {
            $hint .= "Navigation context — Projects (admin):\n"
                   . "- You can create, edit, and archive projects.\n"
                   . "- All projects: $base_url/project/list\n";
        } elsif ($role eq 'user') {
            $hint .= "Navigation context — Projects:\n"
                   . "- You can view projects you are a member of.\n"
                   . "- Projects: $base_url/project/list\n";
        } else {
            $hint .= "Navigation context — Projects (guest):\n"
                   . "- Log in to view project information.\n";
        }
    } elsif ($page_path =~ m{/ency}i) {
        $hint .= "Navigation context — Encyclopedia:\n"
                . "- Search for information: $base_url/ency/search?q=TERM\n";
        $hint .= "- As an admin you can add and edit encyclopedia entries.\n" if $role eq 'admin';
    } elsif ($page_path =~ m{/ai}i) {
        $hint .= "Navigation context — AI Assistant:\n"
               . "- You are currently in the AI chat interface.\n";
        if ($role eq 'admin') {
            $hint .= "- Admin: manage AI models at $base_url/ai/models\n"
                   . "- Manage API keys at $base_url/ai/manage_api_keys\n";
        }
    }

    return $hint;
}

=head2 _select_model_for_context

Choose the best installed Ollama model for a given agent/page context.

  chat / helpdesk / ency / bmaster  → prefer llama3.1 (instruction-tuned chat)
  code / developer / docker         → prefer starcoder2 or qwen-coder
  fallback                          → first installed model, then hardcoded default

=cut

sub _select_model_for_context {
    my ($self, $agent_id, $page_context, $installed_models, $default_model) = @_;

    $agent_id    //= 'general';
    $page_context //= 'general';
    $installed_models //= [];

    # Filter out non-chat models (embeddings, rerankers, etc.) to avoid 400 errors
    my $is_chat_model = sub {
        my ($n) = @_;
        return $n !~ /embed|rerank|bge|nomic|clip|whisper|tts/i;
    };

    # Build a quick lookup: short name → full model name (chat models only)
    my %installed;
    for my $m (@$installed_models) {
        my $name = ref($m) ? ($m->{name} || '') : ($m || '');
        next unless $name;
        next unless $is_chat_model->($name);
        $installed{$name} = $name;
        (my $short = $name) =~ s/:.*$//;
        $installed{$short} = $name;
    }

    # Preferred models per context (ordered: first match wins).
    # tinyllama intentionally excluded — too small for reliable answers.
    my %context_prefs = (
        chat        => ['llama3.1', 'llama3', 'deepseek-r1', 'mistral'],
        helpdesk    => ['llama3.1', 'llama3', 'mistral'],
        ency        => ['llama3.1', 'llama3', 'deepseek-r1', 'mistral'],
        bmaster     => ['llama3.1', 'llama3', 'deepseek-r1', 'mistral'],
        csc         => ['llama3.1', 'llama3', 'mistral'],
        general     => ['llama3.1', 'llama3', 'mistral'],
        navigation  => ['llama3.1', 'llama3'],
        simple      => ['llama3.1', 'llama3'],
        code        => ['starcoder2', 'qwen2.5-coder', 'qwen-coder', 'codellama', 'llama3.1'],
        developer   => ['starcoder2', 'qwen2.5-coder', 'codellama', 'llama3.1'],
        docker      => ['starcoder2', 'qwen2.5-coder', 'llama3.1'],
    );

    my $ctx = lc($agent_id);
    $ctx = 'helpdesk'   if $ctx =~ /helpdesk/;
    $ctx = 'code'       if $ctx =~ /code|developer|starcoder/;
    $ctx = 'bmaster'    if $ctx =~ /bmast|beekeep|apiar/;
    $ctx = 'csc'        if $ctx =~ /^csc$/;
    $ctx = 'ency'       if $ctx =~ /^ency$/;
    $ctx = 'docker'     if $ctx =~ /docker/;
    $ctx = 'general'    unless exists $context_prefs{$ctx};

    my $prefs = $context_prefs{$ctx} || $context_prefs{general};

    for my $pref (@$prefs) {
        for my $key (keys %installed) {
            if ($key =~ /\Q$pref\E/i) {
                return $installed{$key};
            }
        }
    }

    # Fall back: default_model if installed and is chat-capable, else first available chat model, else hardcoded
    if ($default_model && $is_chat_model->($default_model)) {
        return $default_model if $installed{$default_model} || grep { $_ eq $default_model } values %installed;
    }
    my @chat_values = values %installed;
    return $chat_values[0] if @chat_values;
    return 'llama3.1:latest';
}

=head2 _get_current_ollama_config

Private method to determine current Ollama configuration with automatic fallback.

=cut

sub _get_current_ollama_config {
    my ($self, $c, $can_select_model) = @_;

    # ── Single source of truth: comserv.conf <Ollama> block ──────────────────
    my $ollama_cfg      = $c->config->{Ollama} || {};
    my $primary_host    = $ollama_cfg->{host}          || '192.168.1.199';
    my $fallback_host   = $ollama_cfg->{fallback_host} || $primary_host;
    my $config_port     = $ollama_cfg->{port}          || 11434;
    # Never silently fall back to localhost — production Docker has no local Ollama.
    # If fallback is localhost/127.0.0.1 and primary is a real host, keep primary.
    if ($fallback_host =~ /^(localhost|127\.0\.0\.1)$/i && $primary_host !~ /^(localhost|127\.0\.0\.1)$/i) {
        $fallback_host = $primary_host;
    }

    my $ollama = $c->model('Ollama');
    my $current_host  = $primary_host;
    my $current_port  = $config_port;
    my $current_model = 'llama3.1:latest';
    my $installed_models = [];

    # Session override (admin/privileged users can switch host via /ai/models UI)
    if ($can_select_model && $c->session->{ollama_host}) {
        $current_host = $c->session->{ollama_host};
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__,
            '_get_current_ollama_config', "Using session preferred host: $current_host");
    } else {
        # Try primary host; fall back to fallback_host if unreachable
        my $test = Comserv::Model::Ollama->new(host => $primary_host, port => $config_port, timeout => 3);
        if ($test && $test->check_connection()) {
            $current_host = $primary_host;
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__,
                '_get_current_ollama_config', "Primary host $primary_host available");
        } elsif ($fallback_host ne $primary_host) {
            $current_host = $fallback_host;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                '_get_current_ollama_config', "Primary host $primary_host unavailable, using fallback $fallback_host");
        } else {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                '_get_current_ollama_config', "Ollama host $primary_host is not reachable");
        }
    }
    
    # Configure the ollama model with the determined host
    try {
        $ollama->set_host($current_host);
        $current_port = $ollama->port;
        $current_model = $ollama->model;
        
        # Quick connection check (uses 3s timeout via temporary UA)
        my $check_ollama = Comserv::Model::Ollama->new(host => $current_host, port => 11434, timeout => 3);
        if ($check_ollama && $check_ollama->check_connection()) {
            my $models = $ollama->list_models();
            $installed_models = $models if $models && ref($models) eq 'ARRAY';
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                '_get_current_ollama_config', "Ollama configured: $current_host:$current_port, model: $current_model, installed models: " . scalar(@$installed_models));
        } else {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
                '_get_current_ollama_config', "Ollama unavailable at $current_host - no local models available");
        }
            
    } catch {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            '_get_current_ollama_config', "Failed to configure Ollama: $_");
    };
    
    return ($current_host, $current_port, $current_model, $installed_models);
}

sub server_status : Local {
    my ($self, $c) = @_;
    
    $c->response->content_type('application/json');
    
    my $json_data;
    try {
        my $body = $c->request->body_data;
        if ($body && ref($body) eq 'HASH') {
            $json_data = $body;
        } else {
            my $raw_body = $c->request->body;
            $json_data = decode_json($raw_body) if $raw_body;
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
            'server_status', "Failed to parse JSON: $_");
    };
    
    my $host = $json_data->{host} || $c->session->{ollama_host} || 'localhost';
    my $port = $json_data->{port} || $c->session->{ollama_port} || 11434;
    
    my $response;
    try {
        my $ua = LWP::UserAgent->new(timeout => 3);
        my $url = "http://$host:$port/api/tags";
        my $http_response = $ua->get($url);
        
        if ($http_response->is_success) {
            $response = encode_json({
                success => JSON::true,
                running => JSON::true,
                host => $host,
                port => $port
            });
        } else {
            $response = encode_json({
                success => JSON::true,
                running => JSON::false,
                host => $host,
                port => $port,
                error => 'Server not responding'
            });
        }
    } catch {
        $response = encode_json({
            success => JSON::true,
            running => JSON::false,
            host => $host,
            port => $port,
            error => $_
        });
    };
    
    $c->response->body($response);
}

=head2 conversations

Display all saved conversations for the current user with optional filters.

=cut

sub conversations :Local :Args(0) {
    my ($self, $c) = @_;
    
    # Determine if user is authenticated or guest
    my $username = $c->session->{username};
    my $user_id = $c->session->{user_id};
    my $guest_session_id = $c->session->{guest_session_id};
    my $is_guest = 0;
    
    # If not logged in, create guest session
    if (!$username) {
        $is_guest = 1;
        
        # Create a unique guest session ID if not already present
        unless ($guest_session_id) {
            use Data::UUID;
            my $ug = Data::UUID->new;
            $guest_session_id = $ug->create_str();
            $c->session->{guest_session_id} = $guest_session_id;
        }
        
        # Use guest user (ID 199)
        $user_id = 199;
        $username = "Guest-" . substr($guest_session_id, 0, 8);
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
            'conversations', "Guest user accessing conversations: $username");
    }
    
    my $user_roles = $c->session->{roles} || [];
    if (!ref($user_roles)) {
        $user_roles = [split(/\s*,\s*/, $user_roles)] if $user_roles;
    }
    my $is_admin = ref($user_roles) eq 'ARRAY' ? grep { $_ =~ /^admin$/i } @$user_roles : 0;
    
    # Guests cannot view all conversations
    my $view_all = (!$is_guest && $is_admin && ($c->req->params->{view_all} || $c->req->params->{view} eq 'all')) ? 1 : 0;
    
    my $page_title = $view_all ? 'All Conversations (Admin)' : 'My Conversations';
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
        'conversations', "Fetching conversations for user: $username (view_all=$view_all, is_admin=$is_admin)");
    
    my @conversations;
    my $total_conversations = 0;
    
    try {
        my $schema = $c->model('DBEncy')->schema;
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
            'conversations', "DEBUG: user_id=$user_id, view_all=$view_all, is_admin=$is_admin");
        
        my $search_criteria = $view_all ? {} : { user_id => $user_id };
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
            'conversations', "DEBUG: Search criteria: " . ($view_all ? "no filter (all conversations)" : "user_id=$user_id"));
        
        my $count_rs = $schema->resultset('AiConversation')->search($search_criteria);
        $total_conversations = $count_rs->count;
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
            'conversations', "DEBUG: Query returned count=$total_conversations, about to iterate");
        
        my $conv_rs = $schema->resultset('AiConversation')->search(
            $search_criteria,
            { 
                order_by => { -desc => 'created_at' }
            }
        );
        
        my @conv_rows = $conv_rs->all;
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
            'conversations', "DEBUG: Got all rows, count = " . scalar(@conv_rows));
        
        foreach my $conv (@conv_rows) {
            try {
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                    'conversations', "Processing conversation ID=" . $conv->id);
                
                # For guests, only show conversations that belong to this guest session
                if ($is_guest) {
                    my $conv_metadata = {};
                    if ($conv->metadata) {
                        try {
                            $conv_metadata = decode_json($conv->metadata);
                        } catch {
                            # Metadata parsing failed, skip this conversation
                            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
                                'conversations', "Failed to parse conversation metadata for ID=" . $conv->id);
                        };
                    }
                    
                    # Check if this conversation belongs to this guest session
                    unless ($conv_metadata->{guest_session_id} && $conv_metadata->{guest_session_id} eq $guest_session_id) {
                        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                            'conversations', "Skipping conversation ID=" . $conv->id . " - not owned by this guest session");
                        next;
                    }
                }
                
                my @messages = $conv->ai_messages->all;
                my $message_count = scalar(@messages);
                
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                    'conversations', "  - Found $message_count messages");
                
                my $preview = '';
                if (@messages > 0) {
                    my $user_msg = '';
                    my $ai_msg = '';
                    
                    foreach my $msg (@messages) {
                        if ($msg->role eq 'user' && !$user_msg) {
                            $user_msg = $msg->content;
                        }
                        if ($msg->role eq 'assistant' && !$ai_msg) {
                            $ai_msg = $msg->content;
                        }
                        last if $user_msg && $ai_msg;
                    }
                    
                    if ($user_msg) {
                        $preview = "Q: " . substr($user_msg, 0, 60);
                        if (length($user_msg) > 60) {
                            $preview .= '...';
                        }
                        if ($ai_msg) {
                            $preview .= " | A: " . substr($ai_msg, 0, 40);
                            if (length($ai_msg) > 40) {
                                $preview .= '...';
                            }
                        }
                    } else {
                        my $latest_message = $conv->get_latest_message;
                        $preview = $latest_message ? substr($latest_message->content, 0, 100) : '';
                    }
                }
                
                my $username = 'Unknown';
                if ($conv->user) {
                    $username = $conv->user->username;
                }
                
                my @message_data;
                foreach my $msg (@messages) {
                    push @message_data, {
                        id => $msg->id,
                        conversation_id => $msg->conversation_id,
                        user_id => $msg->user_id,
                        role => $msg->role,
                        content => $msg->content,
                        created_at => $msg->created_at,
                        agent_type => $msg->agent_type || 'chat',
                        model_used => $msg->model_used || '',
                        ip_address => $msg->ip_address || '',
                        user_role => $msg->user_role || '',
                        metadata => $msg->metadata || '{}'
                    };
                }
                
                my $conv_data = {
                    id => $conv->id,
                    user_id => $conv->user_id,
                    username => $username,
                    title => $conv->get_display_title,
                    created_at => $conv->created_at,
                    updated_at => $conv->updated_at,
                    message_count => $message_count,
                    status => $conv->status,
                    preview => $preview,
                    messages => \@message_data
                };
                
                push @conversations, $conv_data;
                
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                    'conversations', "  - Pushed to array. Total now: " . scalar(@conversations));
            } catch {
                my $error = $_;
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
                    'conversations', "Error processing conversation: $error");
            };
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
            'conversations', "Retrieved $total_conversations conversations. Array size: " . scalar(@conversations));
        
        if (scalar(@conversations) == 0 && $total_conversations > 0) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
                'conversations', "WARNING: Count says $total_conversations conversations but array is empty!");
        }
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
            'conversations', "Failed to fetch conversations: $error");
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
            'conversations', "Stack trace: " . $error);
    };
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
        'conversations', "FINAL: Stashing conversations. Count=$total_conversations, Array size=" . scalar(@conversations));
    
    foreach my $idx (0 .. $#conversations) {
        my $conv = $conversations[$idx];
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
            'conversations', "  [$idx] ID=" . $conv->{id} . ", Title=" . $conv->{title} . ", Messages=" . $conv->{message_count});
    }
    
    $c->stash(
        template => 'ai/conversations.tt',
        page_title => $page_title,
        conversations => \@conversations,
        total_conversations => $total_conversations,
        username => $username,
        is_admin => $is_admin,
        view_all => $view_all,
        is_guest => $is_guest
    );
}

=head2 conversation

Display a single conversation by ID.

=cut

sub conversation :Local :Args(1) {
    my ($self, $c, $conv_id) = @_;

    my $username     = $c->session->{username};
    my $user_id      = $c->session->{user_id};
    my $user_roles   = $c->session->{roles} || [];
    $user_roles      = [split(/\s*,\s*/, $user_roles)] unless ref($user_roles);
    my $is_admin     = grep { /^admin$/i } @$user_roles;

    unless ($username && $user_id) {
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    unless ($conv_id && $conv_id =~ /^\d+$/) {
        $c->stash(error_msg => "Invalid conversation ID.");
        $c->response->status(400);
        $c->stash(template => 'error.tt');
        return;
    }

    my ($conversation, @messages);
    try {
        my $schema = $c->model('DBEncy')->schema;
        my $conv = $schema->resultset('AiConversation')->find($conv_id);

        unless ($conv) {
            $c->stash(error_msg => "Conversation not found.");
            $c->response->status(404);
            $c->stash(template => 'error.tt');
            return;
        }

        # Non-admins can only see their own conversations
        unless ($is_admin || $conv->user_id == $user_id) {
            $c->stash(error_msg => "Access denied.");
            $c->response->status(403);
            $c->stash(template => 'error.tt');
            return;
        }

        my $meta = {};
        eval { $meta = decode_json($conv->metadata || '{}'); };

        $conversation = {
            id         => $conv->id,
            title      => $conv->title || 'Untitled',
            status     => $conv->status || 'active',
            created_at => $conv->created_at,
            updated_at => $conv->updated_at,
            metadata   => $meta,
        };

        my $msg_rs = $schema->resultset('AiMessage')->search(
            { conversation_id => $conv_id },
            { order_by => { -asc => 'created_at' } }
        );
        while (my $msg = $msg_rs->next) {
            my $raw_meta = $msg->metadata || '{}';
            push @messages, {
                id          => $msg->id,
                role        => $msg->role,
                content     => $msg->content,
                model_used  => $msg->model_used,
                agent_type  => $msg->agent_type,
                created_at  => $msg->created_at,
                metadata    => $raw_meta,
            };
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'conversation', "Failed to fetch conversation $conv_id: $_");
        $c->stash(error_msg => "Failed to load conversation.");
        $c->stash(template => 'error.tt');
        return;
    };

    $c->stash(
        template     => 'ai/conversations.tt',
        page_title   => 'Conversation: ' . ($conversation->{title} || 'Untitled'),
        single_conv  => $conversation,
        messages     => \@messages,
        conversations => [],
        total_conversations => 0,
        username     => $username,
        is_admin     => $is_admin,
        view_all     => 0,
        is_guest     => 0,
    );
}

=head2 conversation_delete

Delete a conversation by ID.

=cut

sub conversation_delete :Path('conversation') :Args(2) {
    my ($self, $c, $conv_id, $action) = @_;

    return unless $action eq 'delete';

    my $username   = $c->session->{username};
    my $user_id    = $c->session->{user_id};
    my $user_roles = $c->session->{roles} || [];
    $user_roles    = [split(/\s*,\s*/, $user_roles)] unless ref($user_roles);
    my $is_admin   = grep { /^admin$/i } @$user_roles;

    unless ($username && $user_id && $conv_id =~ /^\d+$/) {
        $c->response->redirect($c->uri_for('/ai/conversations'));
        return;
    }

    eval {
        my $schema = $c->model('DBEncy')->schema;
        my $conv   = $schema->resultset('AiConversation')->find($conv_id);
        if ($conv && ($is_admin || $conv->user_id == $user_id)) {
            $schema->resultset('AiMessage')->search({ conversation_id => $conv_id })->delete;
            $conv->delete;
        }
    };

    $c->response->body(encode_json({ success => \1 }));
    $c->response->content_type('application/json');
}

=head2 session_details

API endpoint to retrieve session information (username, hostname, conversation_id)
based on the provided session cookie.

=cut

sub session_details :Local :Args(0) {
    my ($self, $c) = @_;
    
    # Set response content type
    $c->response->content_type('application/json');
    
    my $session_id = $c->sessionid;
    my $username = $c->session->{username} || 'Guest';
    my $user_id = $c->session->{user_id} || 199;
    my $conversation_id = $c->session->{current_conversation_id} || $c->session->{conversation_id};
    
    # Get hostname from system utility
    my $hostname = Comserv::Util::SystemInfo->get_server_hostname();
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
        'session_details', "Session details requested for user: $username (Session: $session_id)");
    
    $c->response->body(encode_json({
        success => JSON::true,
        session_id => $session_id,
        username => $username,
        user_id => $user_id,
        conversation_id => $conversation_id,
        hostname => $hostname,
        roles => $c->session->{roles} || [],
    }));
}

sub get_conversation_list :Local :Args(0) {
    my ($self, $c) = @_;
    
    $c->response->content_type('application/json');
    
    my $username = $c->session->{username};
    my $user_id = $c->session->{user_id};
    my $guest_session_id = $c->session->{guest_session_id};
    my $is_guest = 0;
    
    if (!$username) {
        $is_guest = 1;
        $user_id = 199;
        unless ($guest_session_id) {
            use Data::UUID;
            my $ug = Data::UUID->new;
            $guest_session_id = $ug->create_str();
            $c->session->{guest_session_id} = $guest_session_id;
        }
    }
    
    try {
        my $schema = $c->model('DBEncy')->schema;
        my $conv_rs = $schema->resultset('AiConversation')->search(
            { user_id => $user_id },
            { 
                order_by => { -desc => 'updated_at' },
                rows => 50
            }
        );
        
        my @conv_list;
        foreach my $conv ($conv_rs->all) {
            if ($is_guest) {
                my $conv_metadata = {};
                if ($conv->metadata) {
                    try {
                        $conv_metadata = decode_json($conv->metadata);
                    } catch {};
                }
                next unless ($conv_metadata->{guest_session_id} && $conv_metadata->{guest_session_id} eq $guest_session_id);
            }
            
            my $message_count = $conv->ai_messages->count;
            my $first_msg = $conv->ai_messages->search({ role => 'user' }, { rows => 1, order_by => { -asc => 'created_at' } })->first;
            my $preview = $first_msg ? substr($first_msg->content, 0, 60) : 'No messages';
            
            push @conv_list, {
                id => $conv->id,
                title => $conv->get_display_title,
                message_count => $message_count,
                preview => $preview,
                created_at => $conv->created_at->strftime('%Y-%m-%d %H:%M:%S'),
                updated_at => $conv->updated_at->strftime('%Y-%m-%d %H:%M:%S')
            };
        }
        
        $c->response->body(encode_json({
            success => JSON::true,
            conversations => \@conv_list
        }));
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
            'get_conversation_list', "Error: $_");
        $c->response->body(encode_json({
            success => JSON::false,
            error => "Failed to load conversations: $_"
        }));
    };
}

sub get_conversation_messages :Local :Args(1) {
    my ($self, $c, $conversation_id) = @_;
    
    $c->response->content_type('application/json');
    
    unless ($conversation_id) {
        $c->response->body(encode_json({
            success => JSON::false,
            error => 'Conversation ID required'
        }));
        return;
    }
    
    my $username = $c->session->{username};
    my $user_id = $c->session->{user_id};
    my $guest_session_id = $c->session->{guest_session_id};
    my $is_guest = 0;
    
    if (!$username) {
        $is_guest = 1;
        $user_id = 199;
    }
    
    try {
        my $schema = $c->model('DBEncy')->schema;
        my $conv = $schema->resultset('AiConversation')->find($conversation_id);
        
        unless ($conv) {
            $c->response->body(encode_json({
                success => JSON::false,
                error => 'Conversation not found'
            }));
            return;
        }
        
        if ($conv->user_id != $user_id) {
            $c->response->body(encode_json({
                success => JSON::false,
                error => 'Access denied'
            }));
            return;
        }
        
        if ($is_guest) {
            my $conv_metadata = {};
            if ($conv->metadata) {
                try {
                    $conv_metadata = decode_json($conv->metadata);
                } catch {};
            }
            unless ($conv_metadata->{guest_session_id} && $conv_metadata->{guest_session_id} eq $guest_session_id) {
                $c->response->body(encode_json({
                    success => JSON::false,
                    error => 'Access denied'
                }));
                return;
            }
        }
        
        my @messages;
        foreach my $msg ($conv->ai_messages->search({}, { order_by => { -asc => 'created_at' } })->all) {
            my $msg_meta = {};
            eval { $msg_meta = decode_json($msg->metadata || '{}'); };
            push @messages, {
                id         => $msg->id,
                role       => $msg->role,
                content    => $msg->content,
                agent_type => $msg->agent_type || '',
                model_used => $msg->model_used || '',
                created_at => $msg->created_at->strftime('%Y-%m-%d %H:%M:%S'),
                thinking_trace => $msg_meta->{thinking_trace} || [],
            };
        }
        
        $c->response->body(encode_json({
            success => JSON::true,
            conversation => {
                id => $conv->id,
                title => $conv->get_display_title,
                created_at => $conv->created_at->strftime('%Y-%m-%d %H:%M:%S')
            },
            messages => \@messages
        }));
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
            'get_conversation_messages', "Error: $_");
        $c->response->body(encode_json({
            success => JSON::false,
            error => "Failed to load messages: $_"
        }));
    };
}

=head2 manage_api_keys

Display and manage user API keys for AI providers

=cut

sub manage_api_keys :Local :Args(0) {
    my ($self, $c) = @_;
    
    unless ($c->session->{username}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'manage_api_keys', "Unauthorized access attempt - no session");
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    my $user_id = $c->session->{user_id};
    my $username = $c->session->{username};
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
        'manage_api_keys', "User $username (ID: $user_id) accessing API keys management");
    
    my @api_keys;
    try {
        my $schema = $c->model('DBEncy')->schema;
        my $keys_rs = $schema->resultset('UserApiKeys')->search(
            { user_id => $user_id },
            { order_by => { -asc => 'service' } }
        );
        
        my $key_count = $keys_rs->count;
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
            'manage_api_keys', "Found $key_count API keys for user $user_id");
        
        foreach my $key ($keys_rs->all) {
            push @api_keys, {
                id => $key->id,
                service => $key->service,
                is_active => $key->is_active,
                created_at => $key->created_at->strftime('%Y-%m-%d %H:%M'),
                updated_at => $key->updated_at->strftime('%Y-%m-%d %H:%M')
            };
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
            'manage_api_keys', "Failed to fetch API keys for user $user_id: $_");
        $c->flash->{error_msg} = "Failed to load API keys: $_";
    };
    
    $c->stash(
        template => 'ai/manage_api_keys.tt',
        page_title => 'Manage API Keys',
        username => $username,
        api_keys => \@api_keys
    );
}

=head2 add_api_key

Display form to add a new API key

=cut

sub add_api_key :Local :Args(0) {
    my ($self, $c) = @_;
    
    unless ($c->session->{username}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'add_api_key', "Unauthorized access attempt - no session");
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    my $username = $c->session->{username};
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
        'add_api_key', "User $username accessing add API key form");
    
    $c->stash(
        template => 'ai/add_api_key.tt',
        page_title => 'Add API Key',
        username => $username
    );
}

=head2 edit_api_key

Display form to edit an existing API key

=cut

sub edit_api_key :Local :Args(1) {
    my ($self, $c, $key_id) = @_;
    
    unless ($c->session->{username}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'edit_api_key', "Unauthorized access attempt - no session");
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    my $user_id = $c->session->{user_id};
    my $username = $c->session->{username};
    
    unless ($key_id) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'edit_api_key', "No key ID provided by user $username");
        $c->flash->{error_msg} = 'No API key ID specified';
        $c->response->redirect($c->uri_for('/ai/manage_api_keys'));
        return;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
        'edit_api_key', "User $username editing API key ID: $key_id");
    
    try {
        my $schema = $c->model('DBEncy')->schema;
        my $key_obj = $schema->resultset('UserApiKeys')->find($key_id);
        
        unless ($key_obj) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
                'edit_api_key', "API key $key_id not found");
            $c->flash->{error_msg} = 'API key not found';
            $c->response->redirect($c->uri_for('/ai/manage_api_keys'));
            return;
        }
        
        unless ($key_obj->user_id == $user_id) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
                'edit_api_key', "Access denied: User $user_id attempted to edit key $key_id owned by user " . $key_obj->user_id);
            $c->flash->{error_msg} = 'Access denied';
            $c->response->redirect($c->uri_for('/ai/manage_api_keys'));
            return;
        }
        
        $c->stash(
            template => 'ai/add_api_key.tt',
            page_title => 'Edit API Key',
            username => $username,
            key_id => $key_obj->id,
            service => $key_obj->service
        );
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
            'edit_api_key', "Error loading API key $key_id: $_");
        $c->flash->{error_msg} = "Failed to load API key: $_";
        $c->response->redirect($c->uri_for('/ai/manage_api_keys'));
    };
}

=head2 save_api_key

Save or update user API key

=cut

sub save_api_key :Local :Args(0) {
    my ($self, $c) = @_;
    
    unless ($c->session->{username}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'save_api_key', "Unauthorized access attempt - no session");
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    my $user_id = $c->session->{user_id};
    my $username = $c->session->{username};
    my $service = $c->request->params->{service};
    my $api_key = $c->request->params->{api_key};
    my $key_id = $c->request->params->{id};
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
        'save_api_key', "User $username attempting to " . ($key_id ? "update key ID $key_id" : "add new key") . " for service: $service");
    
    # Validation
    unless ($service) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'save_api_key', "Validation failed: service missing for user $username");
        $c->flash->{error_msg} = 'Service is required';
        $c->response->redirect($c->uri_for($key_id ? '/ai/edit_api_key/' . $key_id : '/ai/add_api_key'));
        return;
    }
    
    # For new keys, api_key is required. For edits, it's optional (keep existing if blank)
    if (!$key_id && !$api_key) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'save_api_key', "Validation failed: API key missing for new key, user $username");
        $c->flash->{error_msg} = 'API key is required';
        $c->response->redirect($c->uri_for('/ai/add_api_key'));
        return;
    }
    
    try {
        my $schema = $c->model('DBEncy')->schema;
        
        my $key_obj;
        if ($key_id) {
            # Update existing key
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'save_api_key', "Looking up existing key ID $key_id for user $user_id");
            
            $key_obj = $schema->resultset('UserApiKeys')->find($key_id);
            
            unless ($key_obj) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
                    'save_api_key', "Key ID $key_id not found in database");
                $c->flash->{error_msg} = 'API key not found';
                $c->response->redirect($c->uri_for('/ai/manage_api_keys'));
                return;
            }
            
            unless ($key_obj->user_id == $user_id) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
                    'save_api_key', "Access denied: User $user_id attempted to update key $key_id owned by user " . $key_obj->user_id);
                $c->flash->{error_msg} = 'API key not found or access denied';
                $c->response->redirect($c->uri_for('/ai/manage_api_keys'));
                return;
            }
            
            # Only update api_key if provided
            if ($api_key && length($api_key) > 0) {
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                    'save_api_key', "Updating API key for service $service");
                $key_obj->set_api_key($api_key);
            } else {
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                    'save_api_key', "No new API key provided, keeping existing key for service $service");
            }
            
            $key_obj->update;
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
                'save_api_key', "API key ID $key_id updated successfully for service $service, user $username");
            
            $c->flash->{status_msg} = "API key for $service updated successfully";
            
        } else {
            # Create new key
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'save_api_key', "Creating new API key for service $service, user $user_id");
            
            # Check for duplicate
            my $existing = $schema->resultset('UserApiKeys')->search({
                user_id => $user_id,
                service => $service
            })->first;
            
            if ($existing) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
                    'save_api_key', "Duplicate key attempt: User $user_id already has key for service $service");
                $c->flash->{error_msg} = "You already have an API key for $service. Please edit the existing key instead.";
                $c->response->redirect($c->uri_for('/ai/manage_api_keys'));
                return;
            }
            
            my $tmp = $schema->resultset('UserApiKeys')->new({});
            my $encrypted = $tmp->encrypt_api_key($api_key);

            $key_obj = $schema->resultset('UserApiKeys')->create({
                user_id => $user_id,
                service => $service,
                is_active => '1',
                api_key_encrypted => $encrypted
            });
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
                'save_api_key', "API key created successfully for service $service, user $username, key ID: " . $key_obj->id);
            
            $c->flash->{status_msg} = "API key for $service added successfully";
        }
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
            'save_api_key', "Failed to save API key for service $service, user $username: $error");
        $c->flash->{error_msg} = "Failed to save API key: $error";
    };
    
    $c->response->redirect($c->uri_for('/ai/manage_api_keys'));
}

=head2 delete_api_key

Delete user API key

=cut

sub delete_api_key :Local :Args(1) {
    my ($self, $c, $key_id) = @_;
    
    unless ($c->session->{username}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'delete_api_key', "Unauthorized access attempt - no session");
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    my $user_id = $c->session->{user_id};
    my $username = $c->session->{username};
    
    unless ($key_id) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'delete_api_key', "No key ID provided by user $username");
        $c->flash->{error_msg} = 'No API key ID specified';
        $c->response->redirect($c->uri_for('/ai/manage_api_keys'));
        return;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
        'delete_api_key', "User $username attempting to delete API key ID: $key_id");
    
    try {
        my $schema = $c->model('DBEncy')->schema;
        my $key_obj = $schema->resultset('UserApiKeys')->find($key_id);
        
        unless ($key_obj) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
                'delete_api_key', "API key $key_id not found");
            $c->flash->{error_msg} = 'API key not found';
            $c->response->redirect($c->uri_for('/ai/manage_api_keys'));
            return;
        }
        
        unless ($key_obj->user_id == $user_id) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
                'delete_api_key', "Access denied: User $user_id attempted to delete key $key_id owned by user " . $key_obj->user_id);
            $c->flash->{error_msg} = 'API key not found or access denied';
            $c->response->redirect($c->uri_for('/ai/manage_api_keys'));
            return;
        }
        
        my $service = $key_obj->service;
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
            'delete_api_key', "Deleting API key ID $key_id for service $service, user $username");
        
        $key_obj->delete;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
            'delete_api_key', "API key ID $key_id for service $service deleted successfully by user $username");
        
        $c->flash->{status_msg} = "API key for $service deleted successfully";
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
            'delete_api_key', "Failed to delete API key $key_id for user $username: $error");
        $c->flash->{error_msg} = "Failed to delete API key: $error";
    };
    
    $c->response->redirect($c->uri_for('/ai/manage_api_keys'));
}

=head2 get_user_providers

Get list of user's configured AI providers for chat widget

=cut

sub get_user_providers :Local :Args(0) {
    my ($self, $c) = @_;

    $c->response->content_type('application/json');

    my $username    = $c->session->{username} || '';
    my $user_id     = $c->session->{user_id};
    my $user_roles  = $c->session->{roles} || [];
    if (!ref($user_roles)) {
        $user_roles = [split(/\s*,\s*/, $user_roles)] if $user_roles;
    }

    my $can_select_model = ref($user_roles) eq 'ARRAY'
        ? (grep { /^(admin|developer|editor)$/i } @$user_roles) ? 1 : 0
        : 0;
    my $is_csc_admin = Comserv::Util::AdminAuth->new()->is_csc_admin($c);
    my $is_admin     = $can_select_model || $is_csc_admin;
    my $is_guest     = (!$user_id || $user_id == 199) ? 1 : 0;

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__,
        'get_user_providers',
        "User $username (id=" . ($user_id||'none') . ") can_select=$can_select_model is_admin=$is_admin is_guest=$is_guest");

    my @providers;

    # 1. Ollama — always present; admins get server-switching info
    try {
        my $ollama_cfg     = $c->config->{Ollama} || {};
        my $primary_host   = $ollama_cfg->{host}          || '192.168.1.199';
        my $fallback_host  = $ollama_cfg->{fallback_host} || $primary_host;
        my $cfg_port       = $ollama_cfg->{port}          || 11434;
        my $session_host   = ($can_select_model && $c->session->{ollama_host}) ? $c->session->{ollama_host} : '';
        my $active_host    = $session_host || $primary_host;

        my $ollama = $c->model('Ollama');
        if ($ollama) {
            $ollama->host($active_host);
            $ollama->port($cfg_port);
            my $installed = $ollama->list_models() || [];
            my @chat_models = grep {
                my $n = $_->{name} || '';
                $n && $n !~ /embed|rerank|bge|nomic|clip|whisper|tts/i
                   && $n !~ /:cloud$/i;
            } @$installed;

            # Build servers list for admins (used by widget server-switcher)
            my @servers;
            if ($can_select_model) {
                push @servers, {
                    host     => $primary_host,
                    label    => "Primary ($primary_host)",
                    active   => ($active_host eq $primary_host) ? JSON::true : JSON::false,
                };
                if ($fallback_host ne $primary_host) {
                    push @servers, {
                        host   => $fallback_host,
                        label  => "Fallback ($fallback_host)",
                        active => ($active_host eq $fallback_host) ? JSON::true : JSON::false,
                    };
                }
                # If session overrides to a host not in config, add it too
                if ($session_host && $session_host ne $primary_host && $session_host ne $fallback_host) {
                    push @servers, {
                        host   => $session_host,
                        label  => "Custom ($session_host)",
                        active => JSON::true,
                    };
                }
            }

            push @providers, {
                service     => 'ollama',
                name        => 'Ollama (Local AI)',
                is_local    => JSON::true,
                active_host => $active_host,
                servers     => \@servers,
                models      => [ map { { id => $_->{name} } } @chat_models ],
            };
        }
    } catch {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'get_user_providers', "Ollama list failed: $_");
        push @providers, { service => 'ollama', name => 'Ollama (Local AI)', is_local => JSON::true,
                           active_host => '', servers => [], models => [] };
    };

    # 2. External API keys — authenticated users only
    if ($user_id && !$is_guest) {
        try {
            my $schema = $c->model('DBEncy')->schema;
            my %seen;

            # User's own keys first
            my $own_keys = $schema->resultset('UserApiKeys')->search(
                { user_id => $user_id, is_active => '1' },
                { order_by => { -asc => 'service' } }
            );
            foreach my $key ($own_keys->all) {
                next if $seen{$key->service}++;
                my $meta   = $key->get_metadata() || {};
                my $models = $meta->{available_models} || [];

                # Fallback to hardcoded Grok models if none stored in metadata
                if (!@$models && $key->service eq 'grok') {
                    $models = [
                        { id => 'grok-3-mini' },
                        { id => 'grok-3' },
                        { id => 'grok-4-0709' },
                        { id => 'grok-4-fast-non-reasoning' },
                        { id => 'grok-code-fast-1' },
                    ];
                }

                # Filter image/video models for non-admins
                my @filtered = grep {
                    $is_admin || !$_->{id} || $_->{id} !~ /imagine|video/i
                } @$models;

                push @providers, {
                    service  => $key->service,
                    name     => $key->service eq 'grok' ? 'xAI (Grok)' : ucfirst($key->service),
                    models   => \@filtered,
                };
            }

            # Admins: fall back to any active key not owned by this user
            if ($is_admin) {
                my $any_keys = $schema->resultset('UserApiKeys')->search(
                    { is_active => '1' },
                    { order_by => { -asc => 'service' } }
                );
                foreach my $key ($any_keys->all) {
                    next if $seen{$key->service}++;
                    my $meta   = $key->get_metadata() || {};
                    my $models = $meta->{available_models} || [];
                    push @providers, {
                        service => $key->service,
                        name    => $key->service eq 'grok' ? 'xAI (Grok)' : ucfirst($key->service),
                        models  => $models,
                    };
                }
            }

            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__,
                'get_user_providers', "Total providers for user $username: " . scalar(@providers));
        } catch {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                'get_user_providers', "Failed to fetch external providers: $_");
        };
    }

    $c->response->body(encode_json({
        success            => JSON::true,
        providers          => \@providers,
        username           => $username || 'You',
        user_id            => $user_id  || 0,
        is_guest           => $is_guest  ? JSON::true : JSON::false,
        is_admin           => $is_admin  ? JSON::true : JSON::false,
        can_access_history => $is_admin  ? JSON::true : JSON::false,
    }));
}

sub reset_conversation :Local :Args(0) {
    my ($self, $c) = @_;
    
    # Clear the session-stored conversation_id to start a new conversation
    delete $c->session->{current_conversation_id};
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
        'reset_conversation', "Conversation session cleared - next prompt will start a new conversation");
    
    my $response = encode_json({
        success => JSON::true,
        message => 'Conversation reset - next chat will start fresh'
    });
    
    $c->response->content_type('application/json');
    $c->response->body($response);
}

=head2 sync_models

Fetch available models from a provider's API and store in user_api_keys metadata.
Returns JSON with the synced model list.

=cut

sub sync_models :Local :Args(0) {
    my ($self, $c) = @_;

    $c->response->content_type('application/json');

    unless ($c->session->{username}) {
        $c->response->status(401);
        $c->response->body(encode_json({ success => JSON::false, error => 'Login required' }));
        return;
    }

    my $user_id  = $c->session->{user_id};
    my $service  = $c->request->params->{service} || 'grok';

    my $user_roles_sync = $c->session->{roles} || [];
    if (!ref($user_roles_sync)) {
        $user_roles_sync = [split(/\s*,\s*/, $user_roles_sync)] if $user_roles_sync;
    }
    my $is_admin_sync = ref($user_roles_sync) eq 'ARRAY'
        ? grep { $_ =~ /^(admin|developer)$/i } @$user_roles_sync : 0;

    unless ($is_admin_sync) {
        $c->response->status(403);
        $c->response->body(encode_json({ success => JSON::false, error => 'Admin access required' }));
        return;
    }

    try {
        my $schema = $c->model('DBEncy')->schema;

        # Find the API key record (user's own first, then any active)
        my $key_obj = $schema->resultset('UserApiKeys')->search(
            { user_id => $user_id, service => $service, is_active => '1' }
        )->first;
        unless ($key_obj) {
            $key_obj = $schema->resultset('UserApiKeys')->search(
                { service => $service, is_active => '1' }
            )->first;
        }

        unless ($key_obj && $key_obj->api_key_encrypted) {
            $c->response->body(encode_json({
                success => JSON::false,
                error   => "No active $service API key found. Please add one first."
            }));
            return;
        }

        my $api_key = $key_obj->get_api_key() || '';
        unless ($api_key) {
            $c->response->body(encode_json({
                success => JSON::false,
                error   => "Failed to decrypt $service API key. Please re-save it."
            }));
            return;
        }

        # Provider endpoint map
        my %models_endpoint = (
            grok    => 'https://api.x.ai/v1/models',
            openai  => 'https://api.openai.com/v1/models',
        );

        my $endpoint = $models_endpoint{lc($service)};
        unless ($endpoint) {
            $c->response->body(encode_json({
                success => JSON::false,
                error   => "Model sync not supported for service: $service"
            }));
            return;
        }

        # Fetch models from the provider
        require LWP::UserAgent;
        require HTTP::Request;
        my $ua = LWP::UserAgent->new(timeout => 15);
        $ua->agent('Comserv/1.0');
        my $req = HTTP::Request->new(GET => $endpoint);
        $req->header('Authorization' => "Bearer $api_key");
        $req->header('Content-Type'  => 'application/json');

        my $resp = $ua->request($req);

        unless ($resp->is_success) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                'sync_models', "Failed to fetch models from $service: " . $resp->status_line);
            $c->response->body(encode_json({
                success => JSON::false,
                error   => "Provider returned error: " . $resp->status_line
            }));
            return;
        }

        my $data = eval { decode_json($resp->content) };
        if ($@) {
            $c->response->body(encode_json({ success => JSON::false, error => "Invalid JSON from provider" }));
            return;
        }

        # Extract model list (OpenAI-compatible format: data[].id)
        my @models;
        if ($data->{data} && ref($data->{data}) eq 'ARRAY') {
            foreach my $m (@{$data->{data}}) {
                next unless $m->{id};
                push @models, { id => $m->{id}, owned_by => $m->{owned_by} || '' };
            }
        }

        # Sort models alphabetically
        @models = sort { $a->{id} cmp $b->{id} } @models;

        # Store model list in metadata of the key record
        my $existing_meta = $key_obj->get_metadata() || {};
        $existing_meta->{available_models} = \@models;
        $existing_meta->{models_synced_at} = time();
        $key_obj->set_metadata($existing_meta);
        $key_obj->update;

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'sync_models', "Synced " . scalar(@models) . " models for service $service");

        $c->response->body(encode_json({
            success => JSON::true,
            service => $service,
            models  => \@models,
            count   => scalar(@models)
        }));
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'sync_models', "Error syncing models: $_");
        $c->response->body(encode_json({ success => JSON::false, error => "Sync failed: $_" }));
    };
}

=head1 AUTHOR

AI Assistant

=head1 LICENSE

This library is part of the Comserv application.

=cut

=head2 get_page_doc

Fetch plain-text content from a Documentation file so the AI can advise
the user on how to use a page.  Strips TT directives and HTML tags.

Query params:
  page  - page name or URL path, e.g. "AI", "/Documentation/ApplicationTtTemplate",
          "/admin/documentation/Planning"

Returns JSON: { success, content, page, file }

=cut

sub get_page_doc :Local :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');

    my $page = $c->request->params->{page} || '';
    $page =~ s{^\s+|\s+$}{}g;

    unless ($page) {
        $c->response->body(encode_json({ success => JSON::false, error => 'page param required' }));
        return;
    }

    # Resolve page name → candidate file paths (relative to root/)
    my @candidates = _doc_candidates($page);

    my $root = $c->path_to('root');
    my ($found_file, $content);

    for my $rel (@candidates) {
        my $full = "$root/$rel";
        next unless -f $full;
        local $/;
        open my $fh, '<:encoding(UTF-8)', $full or next;
        $content = <$fh>;
        close $fh;
        $found_file = $rel;
        last;
    }

    unless ($found_file) {
        # Return a guidance string rather than an error so the widget can still
        # include it in the system prompt and the AI won't hallucinate doc paths.
        $c->response->body(encode_json({
            success => JSON::true,
            page    => $page,
            file    => '',
            content => "No dedicated documentation file exists for the page '$page'. "
                     . "Answer based ONLY on the page content already provided to you. "
                     . "Do NOT invent documentation paths, file names, or URLs.",
        }));
        return;
    }

    # Strip TT directives [% ... %] (including multi-line META blocks)
    $content =~ s/\[%-?.*?-?%\]//gs;

    # Strip HTML tags
    $content =~ s/<[^>]+>//gs;

    # Decode common HTML entities
    $content =~ s/&amp;/&/g;
    $content =~ s/&lt;/</g;
    $content =~ s/&gt;/>/g;
    $content =~ s/&quot;/"/g;
    $content =~ s/&#39;/'/g;
    $content =~ s/&nbsp;/ /g;

    # Collapse whitespace
    $content =~ s/[ \t]+/ /g;
    $content =~ s/(\n[ \t]*){3,}/\n\n/g;
    $content =~ s/^\s+|\s+$//g;

    # Cap at 6000 chars to keep system prompt reasonable
    $content = substr($content, 0, 6000) . '…' if length($content) > 6000;

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__,
        'get_page_doc', "Served doc for '$page' from $found_file (" . length($content) . " chars)");

    $c->response->body(encode_json({
        success => JSON::true,
        page    => $page,
        file    => $found_file,
        content => $content,
    }));
}

# Build candidate file paths for a given page name or URL path.
sub _doc_candidates {
    my ($page) = @_;
    my @cands;

    # Normalise: strip leading slash, collapse slashes
    (my $norm = $page) =~ s{^/+}{};
    $norm =~ s{//+}{/}g;

    # 1. If the path already looks like a Documentation path, use it directly
    if ($norm =~ m{^(Documentation|admin/documentation)/}i) {
        my $base = $norm;
        push @cands, "$base.tt", "$base.md", $base;
    }

    # 2. Strip known route prefixes to get the page-name portion
    (my $leaf = $norm) =~ s{^(Documentation|documentation|admin/documentation|admin)/}{}i;
    $leaf =~ s{/.*$}{};   # take only the first segment after prefix
    $leaf =~ s{\?.*$}{};  # drop query string
    $leaf =~ s/\s+//g;

    # 3. Derive a CamelCase variant in case the user passed a lowercase path
    my $camel = join('', map { ucfirst($_) } split(/_|-/, $leaf));

    for my $name ($leaf, $camel) {
        next unless $name;
        push @cands,
            "Documentation/$name.tt",
            "Documentation/$name.md",
            "admin/documentation/$name.tt",
            "admin/documentation/$name.md";
    }

    # 4. Special-case known URL→doc mappings
    my %url_map = (
        'ai'            => ['Documentation/AI.tt', 'Documentation/AI_Chat_System_Master_Audit.tt'],
        'ai/models'     => ['Documentation/AiModelConfig.tt'],
        'ai/manage_api_keys' => ['Documentation/ApiCredentials.tt'],
        'project'       => ['Documentation/BMasterController.tt'],
        'css'           => ['Documentation/CssThemes.tt'],
        'helpdesk'      => ['Documentation/HelpDesk.tt'],
        'admin'         => ['Documentation/Admin.tt'],
        'Documentation' => ['Documentation/AllDocs.tt'],
        'documentation' => ['Documentation/AllDocs.tt'],
    );
    if (exists $url_map{$norm}) {
        push @cands, @{$url_map{$norm}};
    }
    # Try the normalised path without prefix too
    (my $norm_no_prefix = $norm) =~ s{^(ai|admin|Documentation|documentation)/}{}i;
    if (exists $url_map{$norm_no_prefix}) {
        push @cands, @{$url_map{$norm_no_prefix}};
    }

    # De-duplicate while preserving order
    my %seen;
    return grep { !$seen{$_}++ } @cands;
}

=head2 chat_progress

Polling endpoint called by the chat widget every 3 s while waiting for a
response.  Returns the server-side trace steps accumulated so far so admins
can watch the reasoning live (model selection, DB lookups, context budget, etc.)

=cut

sub chat_progress :Local :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');

    my $session_id = $c->sessionid || '';
    my $progress_file = "/tmp/comserv_chat_progress_${session_id}";

    unless ($session_id && -f $progress_file) {
        $c->response->body(encode_json({ steps => [], done => JSON::true }));
        return;
    }

    my @steps;
    my $done = 0;
    if (open my $fh, '<', $progress_file) {
        while (my $line = <$fh>) {
            chomp $line;
            if ($line eq '__DONE__') { $done = 1; next; }
            push @steps, $line;
        }
        close $fh;
    }

    $c->response->body(encode_json({
        steps => \@steps,
        done  => $done ? JSON::true : JSON::false,
    }));
}

=head2 _progress_file_path

Return the temp file path for real-time progress streaming for the current session.

=cut

sub _progress_file_path {
    my ($self, $c) = @_;
    my $sid = $c->sessionid || 'unknown';
    return "/tmp/comserv_chat_progress_${sid}";
}

=head2 _flush_progress

Write the accumulated trace steps to the progress temp file so the
chat_progress polling endpoint can serve them to the browser in real time.

=cut

sub _flush_progress {
    my ($self, $progress_file, $steps_ref, $done) = @_;
    return unless $progress_file && ref($steps_ref) eq 'ARRAY';
    if (open my $fh, '>', $progress_file) {
        for my $step (@$steps_ref) {
            print $fh $step, "\n";
        }
        print $fh "__DONE__\n" if $done;
        close $fh;
    }
}

=head2 preload_model

Send a minimal prompt to Ollama to pre-warm the selected model so subsequent
user queries don't hit cold-start delays.  Called automatically when the chat
widget opens.  Always returns JSON; never blocks longer than 30 s.

=cut

sub preload_model :Local :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');

    my $provider = $c->req->param('provider') || 'ollama';
    unless ($provider eq 'ollama') {
        $c->response->body('{"success":true,"message":"non-ollama provider, no preload needed"}');
        return;
    }

    my $preload_msg = 'skipped';
    eval {
        my ($host, $port, $default_model, $installed) = $self->_get_current_ollama_config($c, 0);
        unless ($host) {
            $c->response->body('{"success":false,"message":"no ollama config"}');
            return;
        }

        my $port_num = $port || 11434;

        # Check what is already in memory — avoid loading a model that is already warm
        my $check_ua = LWP::UserAgent->new(timeout => 5);
        my $ps_resp  = eval { $check_ua->get("http://$host:$port_num/api/ps") };
        my %in_mem;
        if ($ps_resp && $ps_resp->is_success) {
            eval {
                my $ps_data = decode_json($ps_resp->content);
                for my $m (@{ $ps_data->{models} || [] }) {
                    $in_mem{$m->{name}} = 1 if $m->{name};
                }
            };
        }

        my ($tier_small, undef) = $self->_pick_ollama_tier($installed, $default_model, '', '');
        my $model = $tier_small || $default_model;

        # If any suitable model is already loaded, skip the preload entirely
        if ($in_mem{$model}) {
            $preload_msg = "already_in_memory:$model";
        } else {
            # Prefer any already-in-memory installed model so we don't evict it
            my @inst_names = map { ref($_) ? ($_->{name} || '') : ($_ || '') } @$installed;
            my ($warm) = grep { $in_mem{$_} } @inst_names;
            if ($warm) {
                $preload_msg = "already_in_memory:$warm (skipping load of $model)";
            } else {
                # Nothing is loaded — fire a background load of tier_small
                # Use Ollama's "load-only" mode: POST /api/generate with no prompt
                my $url     = "http://$host:$port_num/api/generate";
                my $payload = encode_json({ model => $model, keep_alive => '5m' });
                my $pid = fork();
                if (defined $pid && $pid == 0) {
                    my $child_ua = LWP::UserAgent->new(timeout => 180);
                    $child_ua->post($url, 'Content-Type' => 'application/json', Content => $payload);
                    exit 0;
                }
                $preload_msg = "loading:$model";
            }
        }
    };

    $c->response->body(encode_json({ success => JSON::true, message => $preload_msg }));
}

=head2 action

POST /ai/action

Allows the Chat-with-AI system to take write actions inside the application on
behalf of the authenticated user.  Guests are rejected (403).  All writes use
the same DBEncy schema and respect the existing role system.

Supported actions (passed as JSON body):
  { "action": "update_todo_status",  "params": { "todo_id": N, "status": N } }
  { "action": "reschedule_todo",     "params": { "todo_id": N, "due_date": "YYYY-MM-DD" } }
  { "action": "create_log_entry",    "params": { "todo_id": N, "abstract": "...", "details": "..." } }
  { "action": "add_todo_comment",    "params": { "todo_id": N, "comment": "..." } }

Returns JSON: { success: true/false, message: "..." }

=cut

sub action :Local :Args(0) {
    my ($self, $c) = @_;

    $c->response->content_type('application/json; charset=utf-8');

    # Only POST accepted
    unless ($c->request->method eq 'POST') {
        $c->response->status(405);
        $c->response->body(encode_json({ success => JSON::false, error => 'Method not allowed' }));
        return;
    }

    # Guests may not write
    my $is_guest = !$c->session->{username} || lc($c->session->{username}) eq 'guest';
    if ($is_guest) {
        $c->response->status(403);
        $c->response->body(encode_json({ success => JSON::false, error => 'Login required to perform this action' }));
        return;
    }

    # Parse JSON body
    my $body_text = $c->request->content;
    my $req;
    eval { $req = decode_json($body_text) };
    if ($@ || !ref $req) {
        $c->response->status(400);
        $c->response->body(encode_json({ success => JSON::false, error => 'Invalid JSON body' }));
        return;
    }

    my $action_name = $req->{action} || '';
    my $params      = $req->{params} || {};
    my $current_user = $c->session->{username} || 'ai';
    my $today        = DateTime->now->ymd;

    my $schema = eval { $c->model('DBEncy')->schema };
    unless ($schema) {
        $c->response->status(500);
        $c->response->body(encode_json({ success => JSON::false, error => 'Database not available' }));
        return;
    }

    # ── update_todo_status ────────────────────────────────────────────────────
    if ($action_name eq 'update_todo_status') {
        my $todo_id = $params->{todo_id} or do {
            $c->response->status(400);
            $c->response->body(encode_json({ success => JSON::false, error => 'todo_id required' }));
            return;
        };
        my $new_status = $params->{status};
        unless (defined $new_status && $new_status =~ /^\d+$/) {
            $c->response->status(400);
            $c->response->body(encode_json({ success => JSON::false, error => 'status (numeric) required' }));
            return;
        }
        my $todo = eval { $schema->resultset('Todo')->find($todo_id) };
        unless ($todo) {
            $c->response->status(404);
            $c->response->body(encode_json({ success => JSON::false, error => "Todo #$todo_id not found" }));
            return;
        }
        eval { $todo->update({ status => $new_status, last_mod_by => $current_user, last_mod_date => $today }) };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'action', "update_todo_status failed: $@");
            $c->response->status(500);
            $c->response->body(encode_json({ success => JSON::false, error => 'Update failed' }));
            return;
        }
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'action',
            "AI action update_todo_status: todo=$todo_id status=$new_status by=$current_user");
        $c->response->body(encode_json({ success => JSON::true, message => "Todo #$todo_id status updated to $new_status" }));
        return;
    }

    # ── reschedule_todo ───────────────────────────────────────────────────────
    if ($action_name eq 'reschedule_todo') {
        my $todo_id  = $params->{todo_id}  or do {
            $c->response->status(400);
            $c->response->body(encode_json({ success => JSON::false, error => 'todo_id required' }));
            return;
        };
        my $new_due = $params->{due_date};
        unless ($new_due && $new_due =~ /^\d{4}-\d{2}-\d{2}$/) {
            $c->response->status(400);
            $c->response->body(encode_json({ success => JSON::false, error => 'due_date (YYYY-MM-DD) required' }));
            return;
        }
        my $todo = eval { $schema->resultset('Todo')->find($todo_id) };
        unless ($todo) {
            $c->response->status(404);
            $c->response->body(encode_json({ success => JSON::false, error => "Todo #$todo_id not found" }));
            return;
        }
        my $old_due   = $todo->due_date   // '';
        my $old_start = $todo->start_date // $today;
        eval { $todo->update({ due_date => $new_due, last_mod_by => $current_user, last_mod_date => $today }) };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'action', "reschedule_todo update failed: $@");
            $c->response->status(500);
            $c->response->body(encode_json({ success => JSON::false, error => 'Update failed' }));
            return;
        }
        # Audit interval
        if ($old_due ne $new_due) {
            eval {
                $schema->resultset('TodoInterval')->create({
                    todo_record_id => $todo_id,
                    start_date     => $old_start,
                    end_date       => $today,
                    interval_type  => 'rescheduled',
                    status         => "from:$old_due to:$new_due",
                    last_mod_by    => $current_user,
                    last_mod_date  => $today,
                });
            };
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'action',
                "reschedule interval create failed: $@") if $@;
        }
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'action',
            "AI action reschedule_todo: todo=$todo_id old=$old_due new=$new_due by=$current_user");
        $c->response->body(encode_json({ success => JSON::true, message => "Todo #$todo_id rescheduled to $new_due" }));
        return;
    }

    # ── create_log_entry ─────────────────────────────────────────────────────
    if ($action_name eq 'create_log_entry') {
        my $todo_id  = $params->{todo_id}  || 0;
        my $abstract = $params->{abstract} || 'AI-created log entry';
        my $details  = $params->{details}  || '';
        my $sitename = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';

        my $log_row;
        eval {
            $log_row = $schema->resultset('Log')->create({
                todo_record_id => $todo_id || undef,
                owner          => $current_user,
                sitename       => $sitename,
                start_date     => $today,
                abstract       => $abstract,
                details        => $details,
                start_time     => '00:00',
                end_time       => '00:00',
                time           => 0,
                group_of_poster => do {
                    my $roles = $c->session->{roles} || [];
                    ref $roles eq 'ARRAY' ? join(',', @$roles) : ($roles || 'default');
                },
                status        => 1,
                priority      => 2,
                last_mod_by   => $current_user,
                last_mod_date => $today,
            });
        };
        if ($@ || !$log_row) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'action', "create_log_entry failed: $@");
            $c->response->status(500);
            $c->response->body(encode_json({ success => JSON::false, error => 'Log creation failed' }));
            return;
        }
        my $log_id = $log_row->id // $log_row->record_id // '?';
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'action',
            "AI action create_log_entry: log=$log_id todo=$todo_id by=$current_user");
        $c->response->body(encode_json({ success => JSON::true, message => "Log entry #$log_id created", log_id => $log_id + 0 }));
        return;
    }

    # ── add_todo_comment ──────────────────────────────────────────────────────
    if ($action_name eq 'add_todo_comment') {
        my $todo_id = $params->{todo_id} or do {
            $c->response->status(400);
            $c->response->body(encode_json({ success => JSON::false, error => 'todo_id required' }));
            return;
        };
        my $comment = $params->{comment} || '';
        unless ($comment) {
            $c->response->status(400);
            $c->response->body(encode_json({ success => JSON::false, error => 'comment required' }));
            return;
        }
        my $todo = eval { $schema->resultset('Todo')->find($todo_id) };
        unless ($todo) {
            $c->response->status(404);
            $c->response->body(encode_json({ success => JSON::false, error => "Todo #$todo_id not found" }));
            return;
        }
        my $existing = $todo->comments // '';
        my $appended = $existing
            ? "$existing\n[$today $current_user] $comment"
            : "[$today $current_user] $comment";
        eval { $todo->update({ comments => $appended, last_mod_by => $current_user, last_mod_date => $today }) };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'action', "add_todo_comment failed: $@");
            $c->response->status(500);
            $c->response->body(encode_json({ success => JSON::false, error => 'Comment update failed' }));
            return;
        }
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'action',
            "AI action add_todo_comment: todo=$todo_id by=$current_user");
        $c->response->body(encode_json({ success => JSON::true, message => "Comment added to Todo #$todo_id" }));
        return;
    }

    # Unknown action
    $c->response->status(400);
    $c->response->body(encode_json({ success => JSON::false, error => "Unknown action: $action_name" }));
}

__PACKAGE__->meta->make_immutable;

1;