package Comserv::Controller::AI;
use Moose;
use namespace::autoclean;
use Try::Tiny;
use JSON qw(encode_json decode_json);
use Catalyst::Controller;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

=head1 NAME

Comserv::Controller::AI - Thin controller for AI chat/widget

All heavy logic lives in Comserv::Model::AI::*
Controller only handles routing, session/guest, JSON, and delegation.
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

sub index :Path :Args(0) {
    my ($self, $c) = @_;

    my $username = $c->session->{username};
    my $guest_session_id = $c->session->{guest_session_id};

    unless ($username) {
        unless ($guest_session_id) {
            require Data::UUID;
            $guest_session_id = Data::UUID->new->create_str();
            $c->session->{guest_session_id} = $guest_session_id;
        }
        $username = "Guest-" . substr($guest_session_id, 0, 8);
    }

    my $can_select = $self->_can_select_model($c);
    my ($host, $port, $model, $installed) =
        $c->model('AI')->config->get_current_ollama_config($c, $can_select);

    $c->stash(
        template         => 'ai/index.tt',
        username         => $username,
        current_model    => $model,
        can_select_model => $can_select ? 1 : 0,
        ollama_host      => $host,
    );
}

sub _can_select_model {
    my ($self, $c) = @_;
    my $roles = $c->session->{roles} || [];
    $roles = [split(/\s*,\s*/, $roles)] unless ref $roles;
    return grep { $_ =~ /^(admin|developer|editor)$/i } @$roles ? 1 : 0;
}

sub generate :Local :Args(0) {
    my ($self, $c) = @_;

    my $input = {};
    try {
        # Prefer Catalyst's parsed body_data (works for form + json when body parsers are configured)
        $input = $c->req->body_data if $c->req->can('body_data') && $c->req->body_data;

        my $ct = lc($c->req->content_type || '');
        if (!$input || !keys %$input) {
            if ($ct =~ /json/) {
                my $body = $c->req->content || '';
                # Be careful not to consume the body fh if already parsed
                if (!$body && (my $fh = $c->req->body)) {
                    local $/; $body = <$fh> // '';
                }
                $input = decode_json($body) if $body && length($body);
            }
        }
        $input ||= $c->req->params || {};
    } catch {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'generate', "JSON parse error: $_");
        $input = $c->req->params || {};
    };

    my $prompt = $input->{prompt} // $input->{message} // '';
    unless ($prompt && length($prompt) > 0) {
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => JSON::false, error => 'Prompt is required' }));
        return;
    }

    # Lightweight keyword interceptor (Planning daily log)
    if ($prompt =~ /\b(daily\s*log|plan\s*for\s*today|today'?s?\s*plan|daily\s*plan)\b/i) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'generate',
            "Planning daily-log keyword intercepted");
        # The model layer + system prompt will handle detailed Planning context
    }

    my %args = (
        prompt            => $prompt,
        model             => $input->{model},
        history           => $input->{history} || [],
        conversation_id   => $input->{conversation_id},
        use_search        => $input->{use_search} ? 1 : 0,
        page_path         => $input->{page_path} // $c->req->path,
        page_title        => $input->{page_title} // '',
        page_content      => $input->{page_content} // $input->{page_context} // '',
        agent_id          => $input->{agent_id} // $input->{agent_type} // '',
        system            => $input->{system} // '',
        project_id        => $input->{project_id},
        task_id           => $input->{task_id},
        provider          => $input->{provider},
        skip_role_prompt  => $input->{skip_role_prompt},
    );

    my $result = $c->model('AI')->chat->process($c, %args);

    $c->res->content_type('application/json; charset=utf-8');
    $c->res->body(encode_json($result));
}

# Back-compat alias used by some widgets
sub chat :Local :Args(0) {
    my ($self, $c) = @_;
    $self->generate($c);
}

# Used by form assistant and chat widget for model/provider selection
sub get_user_providers :Local :Args(0) {
    my ($self, $c) = @_;
    my $providers = eval { $c->model('AI')->provider->list_available($c) } || [];
    my $models    = eval { $c->model('AI')->get_available_models($c) } || [];

    $c->res->content_type('application/json');
    $c->res->body(encode_json({
        success   => JSON::true,
        providers => $providers,
        models    => $models,
    }));
}

# Conversation helpers (thin delegation)
sub get_conversation_list :Local :Args(0) {
    my ($self, $c) = @_;
    my $list = eval { $c->model('AI')->get_conversations($c) } || [];
    $c->res->body(encode_json({ success => 1, conversations => $list }));
}

sub get_conversation_messages :Local :Args(1) {
    my ($self, $c, $conv_id) = @_;
    my $msgs = eval { $c->model('AI')->get_conversation_messages($c, $conv_id) } || [];
    $c->res->body(encode_json({ success => 1, messages => $msgs }));
}

sub reset_conversation :Local :Args(0) {
    my ($self, $c) = @_;
    # Session-based reset is sufficient for now; model can extend later
    delete $c->session->{current_ai_conversation_id};
    $c->res->body(encode_json({ success => 1 }));
}

# Minimal host/model control used by widget
sub set_host :Local :Args(0) {
    my ($self, $c) = @_;
    my $host = $c->req->params->{host};
    if ($host && $self->_can_select_model($c)) {
        $c->session->{ollama_host} = $host;
    }
    $c->res->body(encode_json({ success => 1 }));
}

sub server_status :Local :Args(0) {
    my ($self, $c) = @_;
    my $ollama = eval { $c->model('Ollama') };
    my $ok = $ollama && eval { $ollama->check_connection() };
    $c->res->body(encode_json({ success => 1, status => $ok ? 'running' : 'stopped' }));
}

# editor_config - required by floating code editor widget and restart_dev_server.sh health check.
# Thin delegation to Model::AI::Config (the real logic lives there).
sub editor_config :Local :Args(0) {
    my ($self, $c) = @_;
    $c->res->content_type('application/json; charset=utf-8');

    my $cfg = eval { $c->model('AI')->config };
    my $enabled = 0;
    my $root = '';
    my $grok = undef;
    my $interactive = 0;

    if ($cfg) {
        $enabled    = eval { $cfg->_editor_enabled($c) } ? 1 : 0;
        $root       = eval { $cfg->_project_root_path($c) } || '';
        $grok       = $enabled ? eval { $cfg->_grok_home() . '/.grok/bin/grok' } : undef;
        $interactive = eval { $cfg->_interactive_ws_available($c) } ? 1 : 0;
    }

    $c->res->body(encode_json({
        success                    => JSON::true,
        enabled                    => $enabled ? JSON::true : JSON::false,
        grok_cli                   => $grok,
        project_root               => $root,
        interactive_ws_available   => $interactive ? JSON::true : JSON::false,
        cli_mode                   => $interactive ? 'pty' : 'http',
        coding_terminal_allowed    => $enabled ? JSON::true : JSON::false,
        coding_terminal_ws         => '/coding/terminal_ws',
        ollama_reachable           => JSON::true,
        ollama_host                => '',
    }));
}

# Stubs for actions still referenced by templates/JS (prevent 404s)
# Real implementation for admin/model ops lives in AIAdmin.pm
sub models        :Local :Args(0) { my $c=shift; $c->res->redirect('/ai/admin/models'); }
sub pull_model    :Local :Args(0) { shift->res->body(encode_json({success=>0,error=>'See /ai/models or admin'})); }
sub remove_model  :Local :Args(0) { shift->res->body(encode_json({success=>0,error=>'See admin'})); }
sub running_models:Local :Args(0) { shift->res->body(encode_json({success=>1,models=>[]})) ; }
sub unload_model  :Local :Args(0) { shift->res->body(encode_json({success=>1})); }
sub sync_models   :Local :Args(0) { shift->res->body(encode_json({success=>1,message=>'sync via admin'})); }
sub start_server  :Local :Args(0) { shift->res->body(encode_json({success=>0,error=>'manual start'})); }
sub upgrade_ollama:Local :Args(0) { shift->res->body(encode_json({success=>0})); }
sub test_model    :Local :Args(0) { shift->res->body(encode_json({success=>1,result=>'ok (stub)'})); }
sub auto_sync_models :Local :Args(0) { shift->res->body(encode_json({success=>1})); }

__PACKAGE__->meta->make_immutable;

1;
