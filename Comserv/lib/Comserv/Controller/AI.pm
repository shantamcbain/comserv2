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
use Comserv::Util::Logging;
use Comserv::Model::Ollama;
use Comserv::Model::Grok;
use Comserv::Util::SystemInfo;

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
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
        'index', "AI interface loaded for user: $username (host: $current_host, model: $current_model, can_select: " . ($can_select_model ? 'yes' : 'no') . ", external_models: " . scalar(@external_models) . ")");
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
    my $username = $c->session->{username};
    my $user_id = $c->session->{user_id};
    my $is_guest = 0;
    my $guest_session_id = $c->session->{guest_session_id};
    
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
        
        # Use guest user (ID 199) - created earlier
        $user_id = 199;
        $username = "Guest-" . substr($guest_session_id, 0, 8);
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
            'generate', "Guest user session created: $username (session: $guest_session_id)");
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
    my $normalized_agent_type = $agent_id || 'documentation';
    if ($agent_id && $agent_id =~ /^(documentation|helpdesk|ency|beekeeping|hamradio|chat|cleanup|cleanup-agent|docker|master-plan-updater|daily-audit|daily-plan-automator|master-plan-manager|daily-plans-generator|daily-plans|documentation-sync|main|MainAgent|planning|prompt-logging)$/i) {
        $normalized_agent_type = lc($agent_id);
        # Special case for MainAgent which is camelcase in enum
        $normalized_agent_type = 'MainAgent' if lc($agent_id) eq 'mainagent';
    } elsif ($agent_id && ($agent_id eq 'general' || $agent_id eq 'documentation-agent')) {
        $normalized_agent_type = 'documentation';  # map general and documentation-agent to documentation
    } else {
        # Allow any agent_id since we switched to VARCHAR
        $normalized_agent_type = $agent_id if $agent_id;
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
    my $role_prompt = $self->_build_role_system_prompt($c, $user_roles_gen, $provider);
    if ($role_prompt && $system) {
        $system .= "\n\n" . $role_prompt;
    } elsif ($role_prompt) {
        $system = $role_prompt;
    }

    # Only admins/editors may use web search (costs money per call)
    unless ($can_select_model_gen) {
        $use_search = 0;
    }

    my $response_data;
    my $ollama_started = 0;
    my $model_used = 'unknown';
    my $active_ollama_host = '';
    
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
            
            $response = $grok->chat(
                messages => [
                    { role => 'system', content => $system || 'You are a helpful assistant.' },
                    { role => 'user', content => $prompt }
                ],
                use_search => $use_search,
            );
            
            unless ($response) {
                my $error = $grok->last_error || 'Unknown error';
                die "Grok query failed: $error";
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
            
            # Context-aware model selection when user has not picked a specific model
            unless ($model) {
                $current_model = $self->_select_model_for_context($agent_id, $page_context, $installed_models, $current_model);
            } else {
                $current_model = $model;
            }

            $ollama->host($current_host);
            $ollama->port($current_port) if $current_port;
            $ollama->model($current_model) if $current_model;
            $ollama->clear_endpoint;
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
                'generate', "Ollama model selected: $current_model (agent=$agent_id context=$page_context)");
            
            # Fast availability check (3-second timeout) before committing
            my $fast_check = Comserv::Model::Ollama->new(host => $current_host, port => $current_port || 11434, timeout => 3);
            unless ($fast_check && $fast_check->check_connection()) {
                die "Ollama is not reachable at $current_host. Please select an external AI model (Grok) or try again later.";
            }
            $ollama->timeout(90);
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
                'generate', "Querying Ollama host=$current_host model=$current_model timeout=90s prompt_len=" . length($prompt));
            
            my $query_start = time();
            # Query the API
            $response = $ollama->query(
                prompt => $prompt,
                format => $format eq 'json' ? 'json' : undef,
                system => $system || undef
            );
            my $query_elapsed = time() - $query_start;
            
            unless ($response) {
                my $error = $ollama->last_error || 'Unknown error';
                my $error_class = ref($error) || 'string';
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
                    'generate', "Ollama FAILED host=$current_host model=$current_model elapsed=${query_elapsed}s error_class=$error_class error=$error");
                die "Ollama query failed: $error";
            }
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
                'generate', "Ollama SUCCESS elapsed=${query_elapsed}s model=" . ($response->{model} || $current_model));
            
            $model_used = $response->{model} || $ollama->model;
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
            
            # Save user's message (the prompt)
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'generate', "Saving user message to conversation: $conversation_id");
            
            my $user_metadata = {
                system_prompt => $system || '',
                format => $format || 'text',
                page_context => $page_context,
                page_path => $page_path,
                page_title => $page_title
            };
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'generate', "USER_MSG: conversation_id=$conversation_id, role=user, content_length=" . length($prompt));
            
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
            
            unless ($user_msg) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
                    'generate', "FAILED_USER_MSG: create() returned undef for conversation_id=$conversation_id");
            } else {
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                    'generate', "SUCCESS_USER_MSG: created message ID=" . $user_msg->id . " for conversation_id=$conversation_id");
            }
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'generate', "Saved user message to conversation $conversation_id");
            
            # Save AI's response message
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'generate', "Saving AI response to conversation: $conversation_id");
            
            my $ai_metadata = {
                total_duration => $response->{total_duration} || 0,
                eval_count => $response->{eval_count} || 0
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
            eval_count => $response->{eval_count} || 0
        };
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
            'generate', "AI query failed for user '$username' (provider: $provider): $error");
        
        my $user_error = "$error";
        $user_error =~ s/ at \/.*? line \d+.*$//s;
        
        # Save user question and error to DB so the conversation record is complete
        if ($user_id && $prompt) {
            eval {
                my $schema = $c->model('DBEncy')->schema;
                if ($schema) {
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
                        $schema->resultset('AiMessage')->create({
                            conversation_id => $conversation_id,
                            user_id  => $user_id,
                            role     => 'user',
                            content  => $prompt,
                            agent_type => $agent_id || 'general',
                            model_used => $provider || 'unknown',
                            ip_address => $c->request->address,
                        });
                        $schema->resultset('AiMessage')->create({
                            conversation_id => $conversation_id,
                            user_id  => $user_id,
                            role     => 'assistant',
                            content  => '[ERROR] ' . ($user_error || 'Failed to process AI request'),
                            agent_type => $agent_id || 'general',
                            model_used => $provider || 'unknown',
                            ip_address => $c->request->address,
                        });
                    }
                }
            };
        }

        $response_data = {
            success => JSON::false,
            error => $user_error || 'Failed to process AI request',
            conversation_id => $conversation_id || undef,
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
    
    # Check authentication
    unless ($c->session->{username}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 
            'query_form', "Unauthorized access attempt to AI query form");
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    my $username = $c->session->{username};
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
        'query_form', "User accessing AI query form");
    
    # Set template variables
    $c->stash(
        template => 'ai/query_form.tt',
        page_title => 'AI Query Form',
        username => $username
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
        'query_form', "AI query form loaded for user: $username");
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
    my $role_prompt_chat = $self->_build_role_system_prompt($c, $user_roles_chat, $is_grok_model ? 'grok' : 'ollama');

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

    try {
        my $ai_response = '';
        my $model_used = 'unknown';
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

            # Prepend role-based system prompt if available
            my @final_messages = @messages;
            if ($role_prompt_chat) {
                unshift @final_messages, { role => 'system', content => $role_prompt_chat };
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

        } else {
            # Default: Use Ollama
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
            $ollama->timeout(90);
            $ollama->port($current_port) if $current_port;
            $ollama->model($current_model) if $current_model;

            if ($model && $can_select_model_perm) {
                $ollama->model($model);
            }

            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                'chat', "Querying Ollama host=$current_host model=" . $ollama->model . " timeout=90s messages=" . scalar(@messages));

            my $chat_start = time();
            my $response = $ollama->chat(messages => \@messages);
            my $chat_elapsed = time() - $chat_start;

            unless ($response) {
                my $error = $ollama->last_error || 'Unknown error';
                my $error_class = ref($error) || 'string';
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                    'chat', "Ollama FAILED host=$current_host model=" . $ollama->model . " elapsed=${chat_elapsed}s error_class=$error_class error=$error");
                die "Ollama chat failed: $error";
            }
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                'chat', "Ollama SUCCESS elapsed=${chat_elapsed}s model=" . ($response->{model} || $ollama->model));

            if ($response->{message} && $response->{message}->{content}) {
                $ai_response = $response->{message}->{content};
            } elsif ($response->{response}) {
                $ai_response = $response->{response};
            }

            $model_used = $response->{model} || $ollama->model;
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
            
            # Save AI's response message
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
                    total_duration => $response_total_duration,
                    eval_count => $response_eval_count,
                    is_guest => $is_guest ? 1 : 0,
                    guest_session_id => $guest_session_id
                }),
                ip_address => $c->request->address,
                user_role => $c->session->{roles} ? join(',', @{$c->session->{roles}}) : 'normal'
            });
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'chat', "Saved AI response to conversation $final_conversation_id");
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
                'chat', "Messages saved to conversation ID: $final_conversation_id for user: $username");
            
        } catch {
            my $db_error = $_;
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
                'chat', "Failed to save conversation to database: $db_error (Final Conv ID: $final_conversation_id, User ID: $user_id)");
        };
        
        # Build JSON response
        $response_data = {
            success => JSON::true,
            response => $ai_response,
            model => $model_used,
            conversation_id => $final_conversation_id || undef,
            created_at => $response_created_at,
            total_duration => $response_total_duration,
            eval_count => $response_eval_count
        };
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
            'chat', "AI chat failed for user '$username' (model: $model): $error");
        
        my $user_error = "$error";
        $user_error =~ s/ at \/.*? line \d+.*$//s;
        
        # Save failed request to DB so conversation record is complete
        if ($user_id && $prompt) {
            eval {
                my $schema = $c->model('DBEncy')->schema;
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
                            agent_type => 'documentation',
                            model_used => $model || 'unknown',
                            ip_address => $c->request->address,
                        });
                        $schema->resultset('AiMessage')->create({
                            conversation_id => $save_conv_id,
                            user_id  => $user_id,
                            role     => 'assistant',
                            content  => '[ERROR] ' . $user_error,
                            agent_type => 'documentation',
                            model_used => $model || 'unknown',
                            ip_address => $c->request->address,
                        });
                    }
                }
            };
        }
        
        $response_data = {
            success => JSON::false,
            error => $user_error || 'Failed to process AI chat request'
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
                    
                    # Get available models (this returns static list)
                    my $available = $ollama->list_available_models();
                    if ($available && ref($available) eq 'ARRAY') {
                        $server_info->{available_models} = $available;
                        
                        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                            'models', "Retrieved " . scalar(@$available) . " available models from catalog");
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

=head2 _build_role_system_prompt

Build a role-aware addition to the system prompt granting or restricting
capabilities based on the user's session roles.

  admin/developer/editor  → full internal API access (workshop, ency, todo, project)
  normal user             → general help
  guest                   → HelpDesk, navigation, documentation only

=cut

sub _build_role_system_prompt {
    my ($self, $c, $roles, $provider) = @_;

    $roles   //= [];
    $provider //= 'ollama';

    my $base_url = '';
    eval { $base_url = $c->uri_for('/') . ''; $base_url =~ s{/$}{}; };

    my @role_list = ref($roles) eq 'ARRAY' ? @$roles : split(/\s*,\s*/, $roles || '');
    my $is_admin = grep { /^(admin|developer|editor)$/i } @role_list;
    my $is_guest = !@role_list || (grep { /guest/i } @role_list);

    if ($is_admin) {
        return "You have access to the following internal application APIs when you need live data:\n"
             . "- Workshops (GET $base_url/workshop/list_active) — returns JSON list of active workshops\n"
             . "- Encyclopedia search (GET $base_url/ency/search?q=TERM) — searches the Ency system\n"
             . "- Todos for a project (GET $base_url/todo/list?project_id=ID) — lists todos\n"
             . "- Projects (GET $base_url/project/list) — lists all projects\n"
             . "When a user asks about current data (workshops, projects, tasks), CALL the relevant API "
             . "and base your answer on the result. Do not invent data.\n"
             . ($provider eq 'grok' ? "Web search may also be available if the user has enabled it.\n" : '');
    }

    if ($is_guest) {
        my $guest_no_internet = ($provider ne 'grok')
            ? " You have NO internet access. Never invent live data such as workshop lists, "
            . "event schedules, or website content — say 'I don't have access to that information'."
            : '';
        return "You are a HelpDesk assistant for guest users. "
             . "Provide: navigation help, general application guidance, "
             . "and information from public documentation only. "
             . "Do NOT access private data or APIs. "
             . "If the user needs account-specific help, ask them to log in."
             . $guest_no_internet;
    }

    my $no_internet = ($provider ne 'grok')
        ? " You have NO internet access and NO knowledge of live data. "
        . "If asked about current events, live website content, or dynamic data you were not given, "
        . "say 'I don't have access to that information right now' — never invent an answer."
        : '';

    return "You are a helpful assistant for logged-in users of this application. "
         . "Answer based on the page content and documentation provided. "
         . "Do not invent data; if you don't know something, say so."
         . $no_internet;
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

    # Build a quick lookup: short name → full model name
    my %installed;
    for my $m (@$installed_models) {
        my $name = ref($m) ? ($m->{name} || '') : ($m || '');
        next unless $name;
        $installed{$name} = $name;
        (my $short = $name) =~ s/:.*$//;
        $installed{$short} = $name;
    }

    # Preferred models per context (ordered: first match wins)
    my %context_prefs = (
        chat      => ['llama3.1', 'llama3', 'tinyllama', 'mistral'],
        helpdesk  => ['llama3.1', 'llama3', 'tinyllama', 'mistral'],
        ency      => ['llama3.1', 'llama3', 'mistral', 'tinyllama'],
        bmaster   => ['llama3.1', 'llama3', 'mistral', 'tinyllama'],
        general   => ['llama3.1', 'llama3', 'tinyllama', 'mistral'],
        code      => ['starcoder2', 'qwen2.5-coder', 'qwen-coder', 'codellama', 'llama3.1'],
        developer => ['starcoder2', 'qwen2.5-coder', 'codellama', 'llama3.1'],
        docker    => ['starcoder2', 'qwen2.5-coder', 'llama3.1'],
    );

    my $ctx = lc($agent_id);
    $ctx = 'helpdesk' if $ctx =~ /helpdesk/;
    $ctx = 'code'     if $ctx =~ /code|developer/;
    $ctx = 'ency'     if $ctx =~ /ency|beekeeping|bmast/;
    $ctx = 'docker'   if $ctx =~ /docker/;
    $ctx = 'general'  unless exists $context_prefs{$ctx};

    my $prefs = $context_prefs{$ctx} || $context_prefs{general};

    for my $pref (@$prefs) {
        for my $key (keys %installed) {
            if ($key =~ /\Q$pref\E/i) {
                return $installed{$key};
            }
        }
    }

    # Fall back: default_model if installed, else first available, else hardcoded
    return $default_model if $default_model && ($installed{$default_model} || grep { $_ eq $default_model } values %installed);
    return (values %installed)[0] if %installed;
    return 'llama3.1:latest';
}

=head2 _get_current_ollama_config

Private method to determine current Ollama configuration with automatic fallback.

=cut

sub _get_current_ollama_config {
    my ($self, $c, $can_select_model) = @_;

    # ── Single source of truth: comserv.conf <Ollama> block ──────────────────
    my $ollama_cfg      = $c->config->{Ollama} || {};
    my $primary_host    = $ollama_cfg->{host}          || 'localhost';
    my $fallback_host   = $ollama_cfg->{fallback_host} || $primary_host;
    my $config_port     = $ollama_cfg->{port}          || 11434;

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
            push @messages, {
                id => $msg->id,
                role => $msg->role,
                content => $msg->content,
                created_at => $msg->created_at->strftime('%Y-%m-%d %H:%M:%S')
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
    
    my $user_id = $c->session->{user_id};
    my @providers;
    
    # Map service names to display names
    my %service_display = (
        grok => 'Grok (xAI)',
        openai => 'OpenAI',
        claude => 'Claude',
        gemini => 'Gemini',
        anthropic => 'Anthropic',
        cohere => 'Cohere'
    );
    
    my $user_roles_prov = $c->session->{roles} || [];
    if (!ref($user_roles_prov)) {
        $user_roles_prov = [split(/\s*,\s*/, $user_roles_prov)] if $user_roles_prov;
    }
    my $is_admin = ref($user_roles_prov) eq 'ARRAY'
        ? grep { $_ =~ /^(admin|developer|editor)$/i } @$user_roles_prov
        : 0;

    if ($user_id) {
        try {
            my $schema = $c->model('DBEncy')->schema;
            my %seen_services;

            my %synced_models_by_service;

            # User's own keys
            my $own_keys = $schema->resultset('UserApiKeys')->search(
                { user_id => $user_id, is_active => '1' },
                { order_by => { -asc => 'service' } }
            );
            foreach my $key ($own_keys->all) {
                next if $seen_services{$key->service}++;
                my $meta = $key->get_metadata() || {};
                if ($meta->{available_models} && ref($meta->{available_models}) eq 'ARRAY') {
                    $synced_models_by_service{$key->service} = $meta->{available_models};
                }
                push @providers, {
                    service      => $key->service,
                    display_name => $service_display{$key->service} || ucfirst($key->service),
                    models       => $synced_models_by_service{$key->service} || undef
                };
            }

            # Admins: also pick up any active keys not owned by this user
            if ($is_admin) {
                my $any_keys = $schema->resultset('UserApiKeys')->search(
                    { is_active => '1' },
                    { order_by => { -asc => 'service' } }
                );
                foreach my $key ($any_keys->all) {
                    next if $seen_services{$key->service}++;
                    my $meta = $key->get_metadata() || {};
                    if ($meta->{available_models} && ref($meta->{available_models}) eq 'ARRAY') {
                        $synced_models_by_service{$key->service} = $meta->{available_models};
                    }
                    push @providers, {
                        service      => $key->service,
                        display_name => $service_display{$key->service} || ucfirst($key->service),
                        models       => $synced_models_by_service{$key->service} || undef
                    };
                }
            }
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 
                'get_user_providers', "Found " . scalar(@providers) . " providers for user $user_id (is_admin: $is_admin)");
        } catch {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 
                'get_user_providers', "Failed to fetch providers: $_");
        };
    }
    
    $c->response->body(encode_json({
        success  => JSON::true,
        providers => \@providers,
        username  => $c->session->{username} || 'You',
        user_id   => $user_id || 0,
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

__PACKAGE__->meta->make_immutable;

1;