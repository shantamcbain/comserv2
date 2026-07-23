package Comserv::Controller::AI2;

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)

use Try::Tiny;
use JSON;
use File::Path qw(make_path);
use Comserv::Util::EditorFile;
use DateTime;

use Comserv::Util::Logging;
use Comserv::Util::AdminAuth;

BEGIN { extends 'Catalyst::Controller' }

__PACKAGE__->config(namespace => 'ai2');

# ===================================================================
# AI2 Controller - Clean, thin HTTP layer
# All business logic delegated to Model::AI2::*
# ===================================================================

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

# Thin index action example
sub index :Path :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'ai2_index', "AI2 interface accessed");

    $c->stash(
        template => 'ai/index.tt',  # reuse or create ai2/index.tt later
        page_title => 'AI Assistant (New)',
        # minimal stash - let Model provide data
    );
}

# Example thin models action
sub models :Local :Args(0) {
    my ($self, $c) = @_;

    my $models_data = $c->model('AI2')->get_available_models($c);

    $c->stash(
        template    => 'ai/models.tt',
        models_data => $models_data,
        page_title  => 'AI Models Management',
    );
}

# Add more thin actions as needed (chat, sync, etc.)

# JSON provider catalog for the chat widget. Returns the v1-compatible
# `providers` shape that local-chat.js consumes, sourced from the v2 Router
# (Ollama + Grok + OpenRouter + any keyed OpenAI-compatible service). This is
# what makes admin users see ALL available models in the chat dropdown.
sub providers :Local :Args(0) {
    my ($self, $c) = @_;

    my $roles = $c->session->{roles} || [];
    $roles = [split(/\s*,\s*/, $roles)] unless ref $roles;
    my $is_admin = grep { $_ =~ /^(admin|developer|editor)$/i } @$roles;

    my $catalog = try { $c->model('AI2')->get_available_models($c) } || [];

    # Group v2 catalog (each: name, provider, label, local) into providers[].
    my %by_service;
    for my $m (@$catalog) {
        my $svc = $m->{provider} || 'unknown';
        $by_service{$svc} ||= { service => $svc, models => [], name => ucfirst($svc) };
        push @{ $by_service{$svc}{models} }, { id => $m->{name}, label => $m->{label} };
    }

    my @providers = values %by_service;

    # Ollama gets a friendly name + active host hint for the admin switcher.
    for my $p (@providers) {
        if ($p->{service} eq 'ollama') {
            $p->{name}       = 'Ollama (Local AI)';
            $p->{active_host}= ($c->config->{Ollama}{host} || '192.168.1.199');
        }
    }

    $c->res->content_type('application/json');
    $c->res->body(encode_json({
        success           => 1,
        providers         => \@providers,
        is_admin          => $is_admin ? 1 : 0,
        can_access_history=> $is_admin ? 1 : 0,
        is_guest          => 0,
        username          => $c->session->{username} || 'Guest',
    }));
}


# PyCharm-like AI Code Editor popup (new clean system)
sub editing_widget_popup :Local :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'ai2_editing_widget_popup', "AI2 code editor popup opened");

    my $router = eval { $c->model('AI2::Router') } || undef;

    my $selected_model = $router ? $router->select_best_model($c) : 'grok-beta';
    my $recommended_models = $router ? $router->get_recommended_models($c) : ['grok-beta','ollama/llama3','ollama/codellama'];
    my $branches = $router ? $router->get_available_branches($c) : ['main','ai2-refactor','feature/ai2-popup'];

    # Sort branches: current branch first, then alphabetically
    my $current_branch = 'main';
    @$branches = sort { $a eq $current_branch ? -1 : $b eq $current_branch ? 1 : $a cmp $b } @$branches;

    # Accept optional file path to load on open
    my $file_to_load = $c->req->param('file') || '';

    $c->stash(
        template            => 'ai2/editor/editing_widget_popup.tt',
        selected_model      => $selected_model,
        recommended_models  => $recommended_models,
        branches            => $branches,
        no_wrapper          => 1,
        ai_popup_mode       => 1,   # triggers conditional loading of ai2editor/*.js in js_load.tt
        show_ai2_editor     => 1,
        file_to_load        => $file_to_load,
    );
    # Catalyst will render the fragment into the dialog
}

# Right-side docked editor panels (PyCharm-style tool windows)
sub right_dock_panel   :Local :Args(0) { my ($self,$c)=@_; $c->stash(template=>'ai2/editor/right_dock_panel.tt',   no_wrapper=>1); }
sub right_dock_project :Local :Args(0) { my ($self,$c)=@_; $c->stash(template=>'ai2/editor/right_dock_project.tt', no_wrapper=>1); }
sub right_dock_commit  :Local :Args(0) { my ($self,$c)=@_; $c->stash(template=>'ai2/editor/right_dock_commit.tt',  no_wrapper=>1); }
sub right_dock_terminal:Local :Args(0) { my ($self,$c)=@_; $c->stash(template=>'ai2/editor/right_dock_terminal.tt',no_wrapper=>1); }
sub right_dock_settings:Local :Args(0) { my ($self,$c)=@_; $c->stash(template=>'ai2/editor/right_dock_settings.tt',no_wrapper=>1); }

# -------------------------------------------------------------------
# Secure file loading for the AI2 editor
# -------------------------------------------------------------------

# GET /ai2/load_file?path=...
sub load_file :Local :Args(0) {
    my ($self, $c) = @_;

    my $rel_path = $c->req->param('path') || '';
    my $ef       = Comserv::Util::EditorFile->new($c);
    my $result   = $ef->read_file($c, $rel_path);

    if ($result->{error}) {
        my $status = $result->{error} eq 'Forbidden' ? 403 : 404;
        $c->res->status($status);
        $c->res->body($result->{error});
        return;
    }

    $c->res->content_type('application/json');
    $c->res->body(encode_json($result));
}

# GET /ai2/file_checksum?path=...
sub file_checksum :Local :Args(0) {
    my ($self, $c) = @_;

    my $rel_path = $c->req->param('path') || '';
    my $root     = $c->path_to('');
    my $full     = $root->file($rel_path)->absolute;

    unless ($full =~ /^\Q$root\E/) {
        $c->res->status(403);
        $c->res->body('Forbidden');
        return;
    }
    unless (-e $full) {
        $c->res->status(404);
        $c->res->body('Not found');
        return;
    }

    my $mtime = (stat($full))[9];

    $c->res->content_type('application/json');
    $c->res->body(encode_json({
        path  => "$full",
        mtime => $mtime,
    }));
}

# -------------------------------------------------------------------
# Secure file saving for the AI2 editor
# -------------------------------------------------------------------

# POST /ai2/save_file
sub save_file :Local :Args(0) {
    my ($self, $c) = @_;

    $c->res->content_type('application/json');

    my $body;
    try {
        my $body_fh = $c->req->body;
        my $json_text = $body_fh ? do { local $/; <$body_fh> } : '';
        $body = decode_json($json_text || '{}');
    } catch {
        $c->res->status(400);
        $c->res->body(encode_json({ success => 0, error => 'Invalid JSON' }));
        return;
    };

    my $rel_path = $body->{path} || '';
    my $content  = $body->{content};

    my $ef     = Comserv::Util::EditorFile->new($c);
    my $result = $ef->write_file($c, $rel_path, $content);

    if ($result->{success}) {
        $c->res->body(encode_json($result));
    } else {
        my $status = $result->{error} eq 'Forbidden' ? 403
                   : $result->{error} eq 'Syntax error' ? 422
                   : $result->{error} eq 'No content provided' ? 400
                   : 500;
        $c->res->status($status);
        $c->res->body(encode_json($result));
    }
}

# -------------------------------------------------------------------
# Diagnostic / test surface for the v2 AI system.
#
# These exist so the system can be inspected and exercised WITHOUT a browser
# login — the AI tester logs in via /ai2/token-login (acting as the real
# user) and then calls /ai2/diagnostics and /ai2/test_model to see
# exactly what the user would see. No app restart required (Starman -r
# reloads .pm on save).
# -------------------------------------------------------------------

# Resolve the path to the application event log (Util::Logging writes here).
sub _app_log_file {
    my ($self, $c) = @_;
    my $dir = $ENV{'COMSERV_LOG_DIR'}
        || File::Spec->catdir($c->path_to('')->stringify, 'logs');
    return File::Spec->catfile($dir, 'application.log');
}

# GET /ai2/diagnostics — live "what is the system doing" snapshot.
# Auth: any logged-in user may read their own view; admins see key state.
sub diagnostics :Local :Args(0) {
    my ($self, $c) = @_;

    $c->res->content_type('application/json');

    unless ($c->session->{username}) {
        $c->res->status(401);
        $c->res->body(encode_json({ success => 0, error => 'Authentication required' }));
        return;
    }

    my $is_admin = grep { $_ =~ /^(admin|developer|editor)$/i }
        (ref($c->session->{roles}) ? @{$c->session->{roles}}
         : split(/\s*,\s*/, $c->session->{roles} || ''));

    my %diag;

    # --- Ollama: live model tags from the configured host ---
    try {
        my $cfg  = $c->config->{Ollama} || {};
        my $host = $cfg->{host} || '192.168.1.199';
        my $port = $cfg->{port} || 11434;
        my $ua   = LWP::UserAgent->new(timeout => 5);
        my $res  = $ua->get("http://$host:$port/api/tags");
        if ($res && $res->is_success) {
            my $d = eval { decode_json($res->decoded_content) };
            $diag{ollama} = {
                host        => $host,
                port        => $port,
                reachable   => 1,
                model_count => $d && $d->{models} ? scalar(@{$d->{models}}) : 0,
                models      => [ map { $_->{name} } @{$d->{models} || []} ],
            };
        } else {
            $diag{ollama} = { host => $host, port => $port, reachable => 0 };
        }
    } catch {
        $diag{ollama} = { error => "probe failed: $_" };
    };

    # --- Provider key state (admin only — never expose keys) ---
    if ($is_admin) {
        my %keys;
        for my $svc (qw(grok openrouter)) {
            my $cls = $svc eq 'grok' ? 'AI2::Provider::Grok'
                                         : 'AI2::Provider::OpenRouter';
            my $prov = try { $c->model($cls) } catch { undef };
            my $has  = try { $prov && $prov->can('_resolve_api_key')
                                  && $prov->_resolve_api_key($c) } catch { undef };
            $keys{$svc} = $has ? 1 : 0;
        }
        $diag{provider_keys} = \%keys;
    }

    # --- Router context preferences (what the brain prefers per role) ---
    try {
        my $router = $c->model('AI2::Router');
        $diag{router} = {
            context_prefs => $router->context_prefs,
            hardcoded_fallback => 'phi4:14b',
        };
    } catch {
        $diag{router} = { error => "unavailable: $_" };
    };

    # --- v2 catalog the widget would actually show (as this user) ---
    try {
        $diag{catalog} = $c->model('AI2')->get_available_models($c);
    } catch {
        $diag{catalog} = { error => "unavailable: $_" };
    };

    # --- Recent application.log lines (tail) ---
    try {
        my $log = $self->_app_log_file($c);
        my @lines;
        if (-f $log) {
            open my $fh, '<', $log or die "open $log: $!";
            my @all = <$fh>;
            close $fh;
            my @tail = @all > 40 ? @all[-40 .. $#all] : @all;
            @lines = map { s/^\s+|\s+$//gr } @tail;
        }
        $diag{recent_log} = \@lines;
    } catch {
        $diag{recent_log} = [ "log read failed: $_" ];
    };

    $diag{auth} = {
        username  => $c->session->{username},
        is_admin  => $is_admin ? 1 : 0,
        roles     => $c->session->{roles},
    };

    # --- Persist the snapshot so it can be reviewed later (the
    # "translation" of live system state, not lost in a terminal). ---
    try {
        my $dir = File::Spec->catdir($c->path_to('')->stringify, 'logs', 'ai2_diagnostics');
        make_path($dir) unless -d $dir;
        my $stamp = DateTime->now->ymd . '-' . do { my @t = localtime; sprintf '%02d%02d%02d', $t[2], $t[1], $t[0] };
        my $who = $c->session->{username} || 'guest';
        $who =~ s/[^A-Za-z0-9_.-]/_/g;
        my $out = File::Spec->catfile($dir, "$stamp-$who.json");
        if (open my $ofh, '>', $out) {
            print $ofh encode_json({ %diag });
            close $ofh;
            $diag{saved_snapshot} = "logs/ai2_diagnostics/" . "$stamp-$who.json";
        }
    } catch {
        $diag{saved_snapshot} = "save failed: $_";
    };

    $c->res->body(encode_json({ success => 1, diagnostics => \%diag }));
}

# GET /ai2/test_model?provider=ollama&model=phi4:14b — self-test a
# provider/model the way the user would, returning the raw model reply.
# Auth: any logged-in user (admin for external providers).
sub test_model :Local :Args(0) {
    my ($self, $c) = @_;

    $c->res->content_type('application/json');

    unless ($c->session->{username}) {
        $c->res->status(401);
        $c->res->body(encode_json({ success => 0, error => 'Authentication required' }));
        return;
    }

    my $provider = $c->req->param('provider') || 'ollama';
    my $model    = $c->req->param('model')    || '';
    unless ($model) {
        $c->res->status(400);
        $c->res->body(encode_json({ success => 0, error => 'model parameter required' }));
        return;
    }

    # External providers require admin key resolution.
    my $is_admin = grep { $_ =~ /^(admin|developer|editor)$/i }
        (ref($c->session->{roles}) ? @{$c->session->{roles}}
         : split(/\s*,\s*/, $c->session->{roles} || ''));
    if ($provider ne 'ollama' && !$is_admin) {
        $c->res->status(403);
        $c->res->body(encode_json({ success => 0, error => 'Admin role required for external provider test' }));
        return;
    }

    my $result = try {
        my $dispatch = {
            ollama     => 'AI2::Provider::Ollama',
            grok       => 'AI2::Provider::Grok',
            openrouter => 'AI2::Provider::OpenRouter',
            external   => 'AI2::Provider::OpenRouter',
        };
        my $cls = $dispatch->{$provider} || 'AI2::Provider::Ollama';
        my $prov = $c->model($cls);
        unless ($prov && $prov->can('chat')) {
            die "No chat client for provider $provider";
        }
        my ($host, $port) = ($c->config->{Ollama}{host} || '192.168.1.199',
                               $c->config->{Ollama}{port} || 11434);
        $prov->chat($c,
            messages => [{ role => 'user',
                content => "Reply with exactly the word PONG to confirm you are working." }],
            model    => $model,
            host     => $host,
            port     => $port,
        );
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'ai2_test_model', "test failed: $_");
        { success => 0, error => "Test threw: $_" };
    };

    $result //= { success => 0, error => 'No response' };
    $c->res->body(encode_json({
        success  => $result->{success} ? 1 : 0,
        provider => $provider,
        model    => $result->{model} || $model,
        response => $result->{response} // '',
        error    => $result->{error},
    }));
}

# POST /ai2/token-login — agent/test harness login.
#
# Mirrors the existing /api/* Bearer-token model: an admin generates a
# token (here, via the same ApiToken table), and this endpoint exchanges a
# token for a real authenticated Catalyst session — so a CLI/agent can act
# as the user and see exactly what the user would see (the v2 catalog,
# chat, diagnostics). Local + token only; never a browser login.
sub token_login :Local :Args(0) {
    my ($self, $c) = @_;

    $c->res->content_type('application/json');

    unless ($c->request->method eq 'POST') {
        $c->res->status(405);
        $c->res->body(encode_json({ success => 0, error => 'Method not allowed' }));
        return;
    }

    my $body;
    try {
        my $raw = $c->req->can('content') ? $c->req->content : $c->request->body;
        $raw = do { local $/; <$raw> } if ref($raw);
        $body = decode_json($raw) if $raw && length($raw);
    } catch {
        $c->res->status(400);
        $c->res->body(encode_json({ success => 0, error => 'Invalid JSON' }));
        return;
    };

    my $token = $body->{token} || '';
    unless ($token) {
        $c->res->status(400);
        $c->res->body(encode_json({ success => 0, error => 'token required' }));
        return;
    }

    my $validation = Comserv::Util::ApiTokenValidator->validate_token($c, $token);
    unless ($validation->{valid}) {
        $c->res->status(401);
        $c->res->body(encode_json({ success => 0, error => $validation->{error} || 'Invalid token' }));
        return;
    }

    my $schema = try { $c->model('DBEncy')->schema } catch { undef };
    my $user   = $schema && $schema->resultset('User')->find($validation->{user_id});
    unless ($user) {
        $c->res->status(401);
        $c->res->body(encode_json({ success => 0, error => 'Token user not found' }));
        return;
    }

    # Establish the real Catalyst session exactly as User.pm login does.
    $c->session->{user_id}  = $user->id;
    $c->session->{username} = $user->username;
    $c->session->{roles}    = $user->roles || 'user';
    $c->session->{SiteName} = $user->sitename if $user->can('sitename') && $user->sitename;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'ai2_token_login', "Agent session established for user " . $user->username);

    $c->res->body(encode_json({
        success  => 1,
        user_id  => $user->id,
        username => $user->username,
        roles    => $user->roles,
        message  => 'Session established. Subsequent /ai2/* calls act as this user.',
    }));
}

# -------------------------------------------------------------------
# Main chat endpoint (v2). Mirrors the v1 /ai/chat request/response
# contract so local-chat.js needs no other changes — just point
# config.apiEndpoints.generateResponse at /ai2/chat. Routing of
# provider+model is delegated to Model::AI2::Router (openrouter/grok/
# ollama all handled), so any model in the dropdown works.
# -------------------------------------------------------------------
sub chat :Local :Args(0) {
    my ($self, $c) = @_;

    $c->response->content_type('application/json');

    my $username = $c->session->{username} || 'Guest';
    my $user_id  = $c->session->{user_id};

    # Parse JSON body (mirrors v1 parsing)
    my $json_data = {};
    my $content_type = $c->request->content_type || '';
    if ($content_type =~ /application\/json/i) {
        try {
            my $raw = $c->req->can('content') ? $c->req->content : $c->request->body;
            $raw = do { local $/; <$raw> } if ref($raw);
            $json_data = decode_json($raw) if $raw && length($raw);
        } catch {
            $c->res->body(encode_json({ success => 0, error => 'Invalid JSON' }));
            return;
        };
    }
    $json_data //= {};

    my $prompt  = $json_data->{prompt} // '';
    my $model   = $json_data->{model}  // '';
    my $history = $json_data->{history} // [];
    my $agent_id= $json_data->{agent_id} // '';
    my $system  = $json_data->{system} // '';
    my $page_path   = $json_data->{page_path} // '';
    my $page_title  = $json_data->{page_title} // '';
    my $page_content= $json_data->{page_content} // '';
    my $use_search  = $json_data->{use_search} ? 1 : 0;

    # The dropdown sends "provider|model" (e.g. openrouter|anthropic/...,
    # grok|grok-4..., ollama|llama3...). Extract the real model name.
    if ($model && $model =~ /^\s*([^|]+)\|(.+?)\s*$/) {
        $model = $2;
    }

    unless ($prompt && length($prompt) > 0) {
        $c->res->body(encode_json({ success => 0, error => 'Prompt is required' }));
        return;
    }

    my $result = try {
        $c->model('AI2::Chat')->process($c,
            prompt       => $prompt,
            model        => $model,
            history      => $history,
            agent_id     => $agent_id,
            system       => $system,
            page_path    => $page_path,
            page_title   => $page_title,
            page_content => $page_content,
            use_search   => $use_search,
        );
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'ai2_chat', "Chat process threw: $_");
        { success => 0, error => "Chat failed: $_" };
    };

    $result //= { success => 0, error => 'No response' };

    $c->res->body(encode_json({
        success          => $result->{success} ? 1 : 0,
        response         => $result->{response} // '',
        model            => $result->{model} // $model,
        provider         => $result->{provider} // '',
        needs_web_search => 0,
        error            => $result->{error},
    }));
}

__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 NAME

Comserv::Controller::AI2 - Clean thin Controller for AI functionality

=cut