package Comserv::Model::AI::Provider;
use Moose;
use namespace::autoclean;
use Try::Tiny;
use LWP::UserAgent;
use HTTP::Request;
use JSON;
use Comserv::Util::Logging;

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

=head1 NAME

Comserv::Model::AI::Provider - Provider abstraction for Ollama, Grok, Groq, OpenAI-compatible, etc.

=head1 DESCRIPTION

Central place to list available providers, get client instances, and perform
common operations (list models, send chat, check health) across different backends.

Currently supports:
- ollama (via existing Comserv::Model::Ollama)
- grok (via existing Comserv::Model::Grok or direct OpenAI-compatible)
- openai, groq, and any other OpenAI-compatible endpoint (via DB-managed API keys)

=cut

=head2 list_available

Returns a list of provider descriptors that the current user/context can use.

=cut

sub list_available {
    my ($self, $c) = @_;

    my @providers;

    # Always offer Ollama if reachable (or configured)
    push @providers, {
        id       => 'ollama',
        label    => 'Local (Ollama)',
        type     => 'local',
        requires_key => 0,
    };

    # External providers that use UserApiKeys
    my $user_id = $c->session->{user_id};
    if ($user_id) {
        my $schema = eval { $c->model('DBEncy')->schema };
        if ($schema) {
            my @keys = $schema->resultset('UserApiKeys')->search({
                user_id   => $user_id,
                is_active => 1,
            })->all;

            my %seen;
            for my $k (@keys) {
                my $svc = lc($k->service || '');
                next unless $svc;
                next if $seen{$svc}++;
                push @providers, {
                    id       => $svc,
                    label    => ucfirst($svc) . ' (API key)',
                    type     => 'external',
                    requires_key => 1,
                    service  => $svc,
                };
            }
        }
    }

    # Also allow global/active keys for admins (they can fall back)
    # For simplicity we let the chat layer decide which key to use.

    return \@providers;
}

=head2 get_client

    my $client = $provider->get_client($c, provider => 'grok', model => '...');

Returns a lightweight client hashref or object that has at least:
    ->chat(messages => [...], %opts)   → returns { success, response, usage?, ... }
    ->list_models()                    → arrayref of model ids (for sync)

For now we return a simple hash with methods implemented here or delegated.

=cut

sub get_client {
    my ($self, $c, %args) = @_;

    my $prov   = lc($args{provider} || 'ollama');
    my $model  = $args{model};

    if ($prov eq 'ollama') {
        my $ollama = $c->model('Ollama');
        return {
            type => 'ollama',
            chat => sub {
                my %chat_args = @_;
                my $messages = $chat_args{messages} || [];
                my $model    = $chat_args{model} || 'llama3.1:latest';

                # Ollama::Chat::chat returns a hashref { response, model, ... }
                my $r = eval { $ollama->chat( messages => $messages, model => $model ) };

                if ($r && ref($r) eq 'HASH' && defined $r->{response} && length($r->{response})) {
                    return {
                        success  => 1,
                        response => $r->{response},
                        model    => $r->{model} || $model,
                        usage    => {},
                    };
                } else {
                    return {
                        success => 0,
                        error   => $ollama->last_error || 'Ollama returned empty response',
                    };
                }
            },
            list_models => sub {
                return $ollama->list_models();
            },
        };
    }

    if ($prov eq 'grok' || $prov eq 'xai') {
        # Prefer the dedicated Grok model when available
        my $grok = eval { $c->model('Grok') };
        if ($grok && $grok->api_key) {
            return {
                type => 'grok',
                chat => sub {
                    my %chat_args = @_;
                    my $msgs = $chat_args{messages} || [];
                    my $use_search = $chat_args{use_search} || 0;
                    return $grok->chat(messages => $msgs, use_search => $use_search);
                },
                list_models => sub {
                    # Grok models are mostly static or come from sync_models
                    return [
                        { id => 'grok-4-fast-reasoning' },
                        { id => 'grok-4-fast-non-reasoning' },
                        { id => 'grok-3' },
                        { id => 'grok-3-mini' },
                    ];
                },
            };
        }
        # Fall through to generic OpenAI-compatible using the DB key
    }

    # Generic OpenAI-compatible (Groq, OpenAI, OpenRouter, etc.)
    return $self->_build_openai_compatible_client($c, %args);
}

=head2 _build_openai_compatible_client (internal)

Builds a client that talks to any OpenAI-compatible /v1/chat/completions endpoint
using an API key from UserApiKeys.

=cut

sub _build_openai_compatible_client {
    my ($self, $c, %args) = @_;

    my $service = lc($args{provider} || 'openai');
    my $model   = $args{model};

    my $user_id = $c->session->{user_id};
    return undef unless $user_id;

    my $schema = eval { $c->model('DBEncy')->schema } or return undef;

    # Admins can use any active key for the service; normal users only their own
    my $is_admin = $c->check_user_roles('admin') || $c->session->{is_admin};

    my $key_rs = $schema->resultset('UserApiKeys')->search({
        service   => $service,
        is_active => 1,
        $is_admin ? () : (user_id => $user_id),
    }, { order_by => { -desc => 'id' } });

    my $key_obj = $key_rs->first;
    unless ($key_obj && $key_obj->api_key_encrypted) {
        return undef;
    }

    my $api_key = eval { $key_obj->get_api_key() } or return undef;

    # Endpoint guessing (can be overridden via key metadata later)
    my %default_endpoints = (
        groq   => 'https://api.groq.com/openai/v1/chat/completions',
        openai => 'https://api.openai.com/v1/chat/completions',
        grok   => 'https://api.x.ai/v1/chat/completions',
        xai    => 'https://api.x.ai/v1/chat/completions',
    );
    my $endpoint = $default_endpoints{$service} || 'https://api.openai.com/v1/chat/completions';

    my $ua = LWP::UserAgent->new(timeout => 180);
    $ua->agent('Comserv-AI/1.0');

    return {
        type => 'openai_compatible',
        service => $service,
        model   => $model,
        chat => sub {
            my %chat_args = @_;
            my $messages = $chat_args{messages} || [];

            my $payload = {
                model       => $model || 'gpt-3.5-turbo',
                messages    => $messages,
                temperature => $chat_args{temperature} // 0.7,
                max_tokens  => $chat_args{max_tokens}  // 4096,
            };

            if ($chat_args{use_search} && $service eq 'grok') {
                $payload->{search_parameters} = { mode => 'auto' };
            }

            my $req = HTTP::Request->new(POST => $endpoint);
            $req->header('Content-Type'  => 'application/json');
            $req->header('Authorization' => "Bearer $api_key");
            $req->content(encode_json($payload));

            my $res = $ua->request($req);
            unless ($res->is_success) {
                return {
                    success => 0,
                    error   => "Provider error: " . $res->status_line,
                };
            }

            my $data = eval { decode_json($res->content) } or return { success => 0, error => 'Bad JSON' };

            my $text = '';
            if ($data->{choices} && ref($data->{choices}) eq 'ARRAY' && @{$data->{choices}}) {
                $text = $data->{choices}[0]{message}{content} // '';
            }

            return {
                success  => 1,
                response => $text,
                model    => $data->{model} || $model,
                usage    => $data->{usage} || {},
            };
        },
        list_models => sub {
            # This is usually done via /ai/sync_models which stores in metadata.
            # For live list we can call the /models endpoint.
            my $models_ep = $endpoint;
            $models_ep =~ s|/chat/completions$|/models|;
            my $req = HTTP::Request->new(GET => $models_ep);
            $req->header('Authorization' => "Bearer $api_key");
            my $res = $ua->request($req);
            return [] unless $res->is_success;
            my $data = eval { decode_json($res->content) } or return [];
            my @out;
            if ($data->{data} && ref($data->{data}) eq 'ARRAY') {
                @out = map { $_->{id} } grep { $_->{id} } @{$data->{data}};
            }
            return \@out;
        },
    };
}

1;

__PACKAGE__->meta->make_immutable;