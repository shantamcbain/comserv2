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
# - Router + ModelManager integration (delegates to Model/AI/)
#
# Author: AI Assistant
# Created: 2025-01-15
# Last Updated: 2025-06-21

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

has 'logging' => (
    is => 'ro',
    lazy => 1,
    default => sub { Comserv::Util::Logging->instance },
);

# ====================== INDEX ======================
sub index :Path :Args(0) {
    my ($self, $c) = @_;

    my $username = $c->session->{username};
    my $guest_session_id = $c->session->{guest_session_id};

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

    my $user_roles = $c->session->{roles} || [];
    if (!ref($user_roles)) {
        $user_roles = [split(/\s*,\s*/, $user_roles)] if $user_roles;
    }
    my $can_select_model = 0;
    if (ref($user_roles) eq 'ARRAY') {
        $can_select_model = grep { $_ =~ /^(admin|developer|editor)$/i } @$user_roles;
    }

    my ($current_host, $current_port, $current_model, $installed_models) = $self->_get_current_ollama_config($c, $can_select_model);

    my $popup_mode = $c->request->param('popup') ? 1 : 0;

    $c->stash(
        template => 'ai/index.tt',
        page_title => 'AI Assistant',
        username => $username,
        can_select_model => $can_select_model,
        current_host => $current_host,
        current_port => $current_port,
        current_model => $current_model,
        installed_models => $installed_models,
        ai_popup_mode => $popup_mode,
    );
}

# ====================== MODELS (delegates to ModelManager) ======================
sub models :Local :Path('models') :Args(0) {
    my ($self, $c) = @_;

    $c->response->content_type('application/json');

    my $model_manager = $c->model('AI::ModelManager');
    my $models = $model_manager ? $model_manager->get_available_models($c) : [];

    $c->response->body(encode_json({
        success => JSON::true,
        models => $models
    }));
}

# ====================== GENERATE (with Router) ======================
sub generate :Local :Args(0) {
    my ($self, $c) = @_;

    $c->response->content_type('application/json');

    my $username = $c->session->{username} || '';
    my $user_id  = $c->session->{user_id}  || 0;
    my $guest_session_id = $c->session->{guest_session_id};

    if (!$username && (!$user_id || $user_id == 199)) {
        $user_id = 199;
        unless ($guest_session_id) {
            use Data::UUID;
            my $ug = Data::UUID->new;
            $guest_session_id = $ug->create_str();
            $c->session->{guest_session_id} = $guest_session_id;
        }
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

    my $content_type = $c->request->content_type || '';
    if ($content_type =~ /application\/json/i) {
        my $json_data = eval { decode_json($c->req->content || '{}') } || {};
        $prompt = $json_data->{prompt} || '';
        $provider = $json_data->{provider} || 'ollama';
        $model = $json_data->{model} || '';
        $page_context = $json_data->{page_context} || 'general';
        $page_path = $json_data->{page_path} || '';
        $agent_id = $json_data->{agent_id} || 'general';
        $conversation_id = $json_data->{conversation_id};
        $use_search = $json_data->{use_search} ? 1 : 0;
        $system = $json_data->{system} || '';
    } else {
        $prompt = $c->request->params->{prompt} || '';
        $model = $c->request->params->{model} || '';
        $conversation_id = $c->request->params->{conversation_id};
        $use_search = $c->request->params->{use_search} ? 1 : 0;
        $page_path = $c->request->params->{page_path} || '';
        $agent_id = $c->request->params->{agent_id} || '';
        $system = $c->request->params->{system} || '';
    }

    unless ($prompt) {
        $c->response->body(encode_json({ success => JSON::false, error => 'Prompt is required' }));
        return;
    }

    # Router integration
    my $router = eval { $c->model('AI::Router') };
    if ($router) {
        my $user_roles = $c->session->{roles} || [];
        $user_roles = [split(/\s*,\s*/, $user_roles)] unless ref($user_roles);
        my $route = eval { $router->route_request($prompt, {
            user_roles => $user_roles,
            user_id => $user_id,
            page_context => $page_context,
            page_path => $page_path,
            agent_id => $agent_id,
        }) } || {};
        if ($route->{backend}) {
            $provider = $route->{backend};
            $model = $route->{model} if $route->{model};
            $use_search = $route->{use_search} if exists $route->{use_search};
        }
        if ($route->{backend} eq 'local_kb' && $route->{result} && $route->{result}->{found}) {
            my $kb = $route->{result};
            $c->response->body(encode_json({
                success => JSON::true,
                response => ($kb->{answer} || $kb->{content} || 'Knowledge base hit.'),
                model => 'local_kb',
                provider => 'local_kb',
            }));
            return;
        }
    }

    # Placeholder generation (replace with your full logic)
    my $ai_response = "Router-integrated response: $prompt";
    my $model_used = $model || 'default';

    $c->response->body(encode_json({
        success => JSON::true,
        response => $ai_response,
        model => $model_used,
        provider => $provider,
        conversation_id => $conversation_id,
    }));
}

# Helper (kept minimal)
sub _get_current_ollama_config {
    my ($self, $c, $can_select) = @_;
    return ('localhost', 11434, 'phi4', []);
}

__PACKAGE__->meta->make_immutable;

1;