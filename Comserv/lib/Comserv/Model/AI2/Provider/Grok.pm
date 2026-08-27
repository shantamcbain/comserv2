package Comserv::Model::AI2::Provider::Grok;

use Moose;
extends 'Catalyst::Model';
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)

use Try::Tiny;
use LWP::UserAgent;
use JSON qw(decode_json encode_json);
use File::Spec;

use Comserv::Util::Logging;

# SuperGrok / X Premium+ chat models Hermes pins (docs/guides/xai-grok-oauth.md).
# Used when the live /v1/models call fails but the prepaid OAuth token is present
# so the picker still offers the same set this workstation chats with.
my @SUPERGROK_CHAT_FALLBACK = qw(
    grok-4.6
    grok-build-0.1
    grok-4.3
    grok-4.20-0309-reasoning
    grok-4.20-0309-non-reasoning
    grok-4.20-multi-agent-0309
);

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

# ===================================================================
# AI2::Provider::Grok — x.AI (grok) model listing + sync.
#
# Mirrors v1 Model::AI::Router::list_grok_models / sync_models: resolves
# the API key from UserApiKeys (admin-gated), hits https://api.x.ai/v1/models,
# and returns the catalog. No raw SQL — uses DBIx::Class like v1.
# ===================================================================

# Path to Hermes auth.json (override for tests). Never log file contents.
sub hermes_auth_json_path {
    return $ENV{COMSERV_HERMES_AUTH_JSON} if $ENV{COMSERV_HERMES_AUTH_JSON};
    if ($ENV{HERMES_HOME}) {
        return File::Spec->catfile($ENV{HERMES_HOME}, 'auth.json');
    }
    my $home = $ENV{HOME} || '';
    return File::Spec->catfile($home, '.hermes', 'auth.json');
}

# Read SuperGrok prepaid OAuth access_token from Hermes auth store.
# Shape: { providers => { 'xai-oauth' => { tokens => { access_token => ... } } } }
# Returns the token string or undef. NEVER log the token.
sub _supergrok_oauth_token_from_file {
    my ($path) = @_;
    return undef unless $path && -r $path;
    my $raw;
    {
        open my $fh, '<', $path or return undef;
        local $/;
        $raw = <$fh>;
        close $fh;
    }
    return undef unless defined $raw && length $raw;
    my $data = eval { decode_json($raw) };
    return undef unless $data && ref $data eq 'HASH';
    my $tok = eval {
        $data->{providers}{'xai-oauth'}{tokens}{access_token}
    };
    return undef unless defined $tok && length $tok;
    return $tok;
}

sub _remember_source {
    my ($self, $source, $key) = @_;
    $self->{_last_cred_source} = $source;
    return $key;
}

# Last resolved credential class: explicit|supergrok_oauth|k8s|env_grok|env_xai|db.
# Used so the catalog can label SuperGrok separately from a pay-per-token key.
sub credential_source {
    my ($self, $c) = @_;
    return $self->{_last_cred_source} if $self->{_last_cred_source};
    $self->_resolve_api_key($c) if $c;
    return $self->{_last_cred_source} || '';
}

sub _read_secret_file {
    my ($path) = @_;
    return undef unless $path && -r $path;
    open my $fh, '<', $path or return undef;
    my $k = do { local $/; <$fh> };
    close $fh;
    return undef unless defined $k;
    $k =~ s/\A\s+|\s+\z//g;
    return length($k) ? $k : undef;
}

# Same paths in every container: K8s /run/secrets, the mounted
# ~/.comserv/secrets volume (compose already bind-mounts it at
# /home/comserv/.comserv/secrets), then COMSERV_SECRETS_DIR.
sub _portable_secret_paths {
    my @paths = (
        '/run/secrets/supergrok_oauth',
        '/run/secrets/xai_oauth_token',
        '/home/comserv/.comserv/secrets/supergrok_oauth',
    );
    if ($ENV{COMSERV_SECRETS_DIR}) {
        push @paths, File::Spec->catfile($ENV{COMSERV_SECRETS_DIR}, 'supergrok_oauth');
    }
    my $home = $ENV{HOME} || '';
    push @paths, File::Spec->catfile($home, '.comserv', 'secrets', 'supergrok_oauth') if $home;
    return @paths;
}

sub resolve_prepaid_key {
    my ($self, $c) = @_;
    $self->{_last_cred_source} = undef;
    for my $p ($self->_portable_secret_paths) {
        my $k = _read_secret_file($p);
        return $self->_remember_source('supergrok_file', $k) if $k;
    }
    if ($ENV{SUPERGROK_OAUTH_TOKEN} && length $ENV{SUPERGROK_OAUTH_TOKEN}) {
        return $self->_remember_source('supergrok_env', $ENV{SUPERGROK_OAUTH_TOKEN});
    }
    if ($ENV{XAI_OAUTH_TOKEN} && length $ENV{XAI_OAUTH_TOKEN}) {
        return $self->_remember_source('supergrok_env', $ENV{XAI_OAUTH_TOKEN});
    }
    my $oauth = _supergrok_oauth_token_from_file($self->hermes_auth_json_path);
    if ($oauth) {
        return $self->_remember_source('supergrok_oauth', $oauth);
    }
    my $schema = eval { $c && $c->model('DBEncy')->schema } or return undef;
    my $uid = eval { $c->session->{user_id} };
    for my $svc (qw(supergrok xai-oauth)) {
        my $key_obj = $schema->resultset('UserApiKeys')->search(
            { service => $svc, is_active => '1' }
        )->first;
        $key_obj ||= $uid ? $schema->resultset('UserApiKeys')->search(
            { user_id => $uid, service => $svc, is_active => '1' }
        )->first : undef;
        next unless $key_obj && $key_obj->api_key_encrypted;
        my $dbk = eval { $key_obj->get_api_key() } || next;
        return $self->_remember_source('db_supergrok', $dbk);
    }
    return undef;
}

sub resolve_paid_key {
    my ($self, $c) = @_;
    $self->{_last_cred_source} = undef;
    if (my $k = _read_secret_file('/run/secrets/grok_api_key')) {
        return $self->_remember_source('k8s', $k);
    }
    if ($ENV{GROK_API_KEY} && length $ENV{GROK_API_KEY}) {
        return $self->_remember_source('env_grok', $ENV{GROK_API_KEY});
    }
    if ($ENV{XAI_API_KEY} && length $ENV{XAI_API_KEY}) {
        return $self->_remember_source('env_xai', $ENV{XAI_API_KEY});
    }
    my $schema = eval { $c && $c->model('DBEncy')->schema } or return undef;
    my $uid = eval { $c->session->{user_id} };
    my $key_obj = $schema->resultset('UserApiKeys')->search(
        { service => 'grok', is_active => '1' }
    )->first;
    $key_obj ||= $uid ? $schema->resultset('UserApiKeys')->search(
        { user_id => $uid, service => 'grok', is_active => '1' }
    )->first : undef;
    return undef unless $key_obj && $key_obj->api_key_encrypted;
    my $dbk = eval { $key_obj->get_api_key() } || undef;
    return undef unless $dbk;
    return $self->_remember_source('db', $dbk);
}

sub _resolve_api_key {
    my ($self, $c, $api_key) = @_;
    $self->{_last_cred_source} = undef;
    if ($api_key && length $api_key) {
        return $self->_remember_source('explicit', $api_key);
    }
    return $self->resolve_prepaid_key($c) || $self->resolve_paid_key($c);
}

sub is_prepaid_source {
    my ($self) = @_;
    my $s = $self->{_last_cred_source} || '';
    return $s =~ /supergrok|oauth/ ? 1 : 0;
}

sub _is_chat_model_id {
    my ($id) = @_;
    return 0 unless $id;
    return $id !~ /embed|rerank|bge|nomic|clip|whisper|tts|imagine-image|imagine-video/i;
}

sub _label_models {
    my ($self, @ids) = @_;
    my $prepaid = $self->is_prepaid_source;
    my @out;
    for my $id (@ids) {
        next unless $id && _is_chat_model_id($id);
        push @out, {
            id      => $id,
            label   => $prepaid ? "SuperGrok: $id" : $id,
            prepaid => $prepaid ? 1 : 0,
        };
    }
    # Pin grok-4.6 first — same as the Hermes SuperGrok picker.
    @out = sort {
        ($b->{id} eq 'grok-4.6') <=> ($a->{id} eq 'grok-4.6')
        || $a->{id} cmp $b->{id}
    } @out;
    return @out;
}

sub list_models {
    my ($self, $c, $api_key, %opts) = @_;
    my $mode = $opts{mode} || 'auto';
    if ($mode eq 'prepaid') {
        $api_key = $api_key || $self->resolve_prepaid_key($c);
    }
    elsif ($mode eq 'paid') {
        $api_key = $api_key || $self->resolve_paid_key($c);
    }
    else {
        $api_key = $self->_resolve_api_key($c, $api_key);
    }
    return { success => 0, error => 'No active SuperGrok/Grok credential found' } unless $api_key;

    my $ua  = LWP::UserAgent->new(timeout => 8);
    my $res = try {
        $ua->get('https://api.x.ai/v1/models',
            'Authorization' => "Bearer $api_key",
            'Content-Type'  => 'application/json',
        );
    } catch {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'grok_list_models', "x.AI request failed: $_");
        return undef;
    };

    if ($res && $res->is_success) {
        my $data = try { decode_json($res->decoded_content) } catch { undef };
        if ($data) {
            my @ids = grep { $_ } map { $_->{id} } @{ $data->{data} || [] };
            my @out = $self->_label_models(@ids);
            if (@out) {
                return { success => 1, models => \@out, count => scalar @out,
                         source => $self->{_last_cred_source} || '' };
            }
        }
    }

    # Prepaid token present but /v1/models failed (OAuth sometimes 403s the
    # catalog). Still offer the Hermes SuperGrok chat set so the picker works.
    if ($self->is_prepaid_source) {
        my @out = $self->_label_models(@SUPERGROK_CHAT_FALLBACK);
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'grok_list_models',
            'Live x.AI model list failed; using SuperGrok prepaid fallback catalog');
        return { success => 1, models => \@out, count => scalar @out,
                 source => $self->{_last_cred_source} || '', fallback => 1 };
    }

    return { success => 0, error => 'Provider API error' };
}

# Chat completion against x.AI (Grok). Migrated from v1 Model::Grok::chat.
# Returns { success, response, model, usage } to match the v2 shape.
sub chat {
    my ($self, $c, %args) = @_;

    my $api_key = $self->_resolve_api_key($c, $args{api_key});
    return { success => 0, error => 'No active grok API key found' } unless $api_key;

    my $messages = $args{messages} || [];
    return { success => 0, error => 'No messages provided' }
        unless ref($messages) eq 'ARRAY' && @$messages;

    my $model = $args{model} || ($self->is_prepaid_source ? 'grok-4.6' : 'grok-3');
    my $payload = {
        model       => $model,
        messages    => $messages,
        temperature => 0.7,
        max_tokens  => $args{max_tokens} // 2048,
    };
    if ($args{use_search}) {
        $payload->{search_parameters} = { mode => 'auto' };
    }

    my $ua = LWP::UserAgent->new(timeout => 180);
    $ua->agent('Comserv-AI/1.0');
    my $req = HTTP::Request->new(POST => 'https://api.x.ai/v1/chat/completions');
    $req->header('Content-Type'  => 'application/json');
    $req->header('Authorization' => "Bearer $api_key");
    $req->content(encode_json($payload));

    my $res = try { $ua->request($req) } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'grok_chat', "x.AI request failed: $_");
        # Pass the transport failure through VERBATIM so Router's
        # _credits_exhausted can match it ("can't connect", "timed out")
        # and fall through to the free-model chain instead of dead-ending.
        return { success => 0, error => "Can't connect to api.x.ai:443: $_" };
    };
    unless ($res && $res->is_success) {
        my $code = $res ? $res->code : 599;
        my $body = $res ? substr(($res->decoded_content // ''), 0, 200) : 'no response';
        $body =~ s/\s+/ /g;
        # Verbatim status + detail (429 rate limit, 401 bad key, 402/429
        # quota...) so the Router fallback chain engages on this hop.
        return {
            success => 0,
            error   => "$code $body",
            ($code == 401 ? (auth_failed => 1) : ()),
        };
    }

    my $data = try { decode_json($res->decoded_content) } catch { undef };
    return { success => 0, error => 'Bad JSON from Grok' } unless $data;

    my $text = '';
    if ($data->{choices} && ref($data->{choices}) eq 'ARRAY' && @{$data->{choices}}) {
        $text = $data->{choices}[0]{message}{content} // '';
    }
    return { success => 1, response => $text, model => $data->{model} || $model, usage => $data->{usage} || {} };
}

# Admin-only sync: returns the live catalog (UI stores it in metadata if desired).
sub sync_models {
    my ($self, $c, $api_key) = @_;
    return $self->list_models($c, $api_key);
}

__PACKAGE__->meta->make_immutable;

1;
