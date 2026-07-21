package Comserv::Model::AI2::Provider::OpenRouter;

use Moose;
use namespace::autoclean;

use Try::Tiny;
use LWP::UserAgent;
use JSON qw(decode_json encode_json);

use Comserv::Util::Logging;

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

# ===================================================================
# AI2::Provider::OpenRouter — OpenAI-compatible aggregator.
#
# OpenRouter exposes an OpenAI-compatible API at https://openrouter.ai/api/v1.
# Mirrors the Grok provider: admin-gated key resolution from UserApiKeys
# (service => 'openrouter'), lists /api/v1/models, returns the catalog.
# Chat completion is handled generically by v1 Model::AI::Provider's
# OpenAI-compatible client (endpoint guessed from the service name) once the
# Router selects an 'openrouter' model. No raw SQL.
# ===================================================================

sub _resolve_api_key {
    my ($self, $c, $api_key) = @_;

    # Explicit key passed (already decrypted) takes precedence.
    return $api_key if $api_key && length $api_key;

    # K8s secret, then env var.
    my $k8s_secret = '/run/secrets/openrouter_api_key';
    if (-e $k8s_secret && open my $fh, '<', $k8s_secret) {
        my $k = do { local $/; <$fh> };
        close $fh;
        chomp($k);
        return $k if $k && length $k;
    }
    return $ENV{OPENROUTER_API_KEY} if $ENV{OPENROUTER_API_KEY} && length $ENV{OPENROUTER_API_KEY};

    my $user_id = $c->session->{user_id} or return undef;
    my $roles   = $c->session->{roles} || [];
    $roles = [split(/\s*,\s*/, $roles)] unless ref $roles;
    my $is_admin = grep { $_ =~ /^(admin|developer)$/i } @$roles;
    return undef unless $is_admin;   # key sync is admin-only (per v1)

    my $schema = eval { $c->model('DBEncy')->schema } or return undef;
    my $key_obj = $schema->resultset('UserApiKeys')->search(
        { user_id => $user_id, service => 'openrouter', is_active => '1' }
    )->first || $schema->resultset('UserApiKeys')->search(
        { service => 'openrouter', is_active => '1' }
    )->first;

    return undef unless $key_obj && $key_obj->api_key_encrypted;
    return eval { $key_obj->get_api_key() } || undef;
}

sub list_models {
    my ($self, $c, $api_key) = @_;

    $api_key = $self->_resolve_api_key($c, $api_key);
    return { success => 0, error => 'No active openrouter API key found' } unless $api_key;

    my $ua  = LWP::UserAgent->new(timeout => 8);
    my $res = try {
        $ua->get('https://openrouter.ai/api/v1/models',
            'Authorization' => "Bearer $api_key",
            'Content-Type'  => 'application/json',
        );
    } catch {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'openrouter_list_models', "OpenRouter request failed: $_");
        return undef;
    };
    return { success => 0, error => 'Provider API error' } unless $res && $res->is_success;

    my $data = try { decode_json($res->decoded_content) } catch { undef };
    return { success => 0, error => 'Bad JSON from provider' } unless $data;

    # OpenRouter returns { data: [ { id, name, ... }, ... ] }
    my @out = map { { id => $_->{id}, label => ($_->{name} || $_->{id}) } }
              grep { $_->{id} }
              @{ $data->{data} || [] };

    return { success => 1, models => \@out, count => scalar @out };
}

# Chat completion against OpenRouter (OpenAI-compatible). Returns the v2 shape.
sub chat {
    my ($self, $c, %args) = @_;

    my $api_key = $self->_resolve_api_key($c, $args{api_key});
    return { success => 0, error => 'No active openrouter API key found' } unless $api_key;

    my $messages = $args{messages} || [];
    return { success => 0, error => 'No messages provided' }
        unless ref($messages) eq 'ARRAY' && @$messages;

    my $model = $args{model} or return { success => 0, error => 'No model specified' };
    my $payload = {
        model       => $model,
        messages    => $messages,
        temperature => 0.7,
        max_tokens  => $args{max_tokens} // 4096,
    };

    my $ua = LWP::UserAgent->new(timeout => 180);
    $ua->agent('Comserv-AI/1.0');
    my $req = HTTP::Request->new(POST => 'https://openrouter.ai/api/v1/chat/completions');
    $req->header('Content-Type'  => 'application/json');
    $req->header('Authorization' => "Bearer $api_key");
    $req->content(encode_json($payload));

    my $res = try { $ua->request($req) } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'openrouter_chat', "OpenRouter request failed: $_");
        return undef;
    };
    return { success => 0, error => 'OpenRouter provider error' } unless $res && $res->is_success;

    my $data = try { decode_json($res->decoded_content) } catch { undef };
    return { success => 0, error => 'Bad JSON from OpenRouter' } unless $data;

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
