package Comserv::Model::AI2::Provider::Ollama;

use Moose;
use namespace::autoclean;

use Try::Tiny;
use JSON qw(encode_json decode_json);

use Comserv::Util::Logging;
use Comserv::Model::Ollama;   # Moose model composing Connection/Chat/Models roles

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

# Read the locally-installed Ollama model tags (name + size + modified).
# Mirrors the v1 Model::AI::Router::list_ollama_models helper so v2 has a
# single real source for local model discovery.
sub list_models {
    my ($self, $c, $host, $port) = @_;
    $host ||= 'localhost';
    $port ||= 11434;

    my $ua  = LWP::UserAgent->new(timeout => 5);
    my $url = "http://$host:$port/api/tags";

    my $res = try {
        $ua->get($url);
    } catch {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'ollama_list_models', "Ollama list failed at $url: $_");
        return undef;
    };
    return [] unless $res && $res->is_success;

    my $data = try { decode_json($res->decoded_content) } catch { undef };
    return [] unless $data;

    return $data->{models} || [];
}

# Confirm the Ollama host is reachable (used by Router for failover decisions).
sub check_connection {
    my ($self, $c, $host, $port) = @_;
    $host ||= 'localhost';
    $port ||= 11434;

    my $ua  = LWP::UserAgent->new(timeout => 3);
    my $res = try { $ua->get("http://$host:$port/api/tags") } catch { undef };
    return $res && $res->is_success ? 1 : 0;
}

# Migrated from v1 Controller::AI generate path (cold-start timeout logic).
#
# Returns a hashref { success, response, model, usage } so it matches the
# shape the v2 Chat brain and local-chat.js expect. On a cold start (model
# not already loaded in RAM) we raise the Ollama UA timeout to 480s so large
# CPU-loaded models like gemma4-64k don't get cut off at the default 120s —
# the Connection role's timeout trigger clears and rebuilds the UA.
sub chat {
    my ($self, $c, %args) = @_;

    my $messages = $args{messages} || [];
    my $model    = $args{model}    || 'llama3.1:latest';
    my $host     = $args{host}     || $c->config->{Ollama}{host} || '192.168.1.199';
    my $port     = $args{port}     || $c->config->{Ollama}{port} || 11434;

    my $ollama = try {
        Comserv::Model::Ollama->new(host => $host, port => $port);
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'ollama_chat', "Failed to build Ollama model: $_");
        return undef;
    };
    return { success => 0, error => 'Ollama client unavailable' } unless $ollama;

    $ollama->model($model);

    # Cold-start detection: if the model isn't already resident, generation
    # must load weights from disk — give it the long timeout.
    my $is_cold = 1;
    try {
        my $running = $ollama->get_running_models() || [];
        $is_cold = 0 if grep {
            (ref $_ ? ($_->{name} // '') : $_ // '') eq $model
        } @$running;
    };
    my $timeout = $is_cold ? 480 : 120;
    $ollama->timeout($timeout);   # triggers UA rebuild via Connection role

    my $r = try {
        $ollama->chat(messages => $messages, model => $model);
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'ollama_chat', "Ollama chat threw: $_");
        undef;
    };

    unless ($r && ref($r) eq 'HASH' && defined $r->{response} && length $r->{response}) {
        return {
            success => 0,
            error   => $ollama->last_error || 'Ollama returned an empty response',
        };
    }

    return {
        success  => 1,
        response => $r->{response},
        model    => $r->{model} || $model,
        usage    => {},
    };
}

# Placeholder for model sync (pull/refresh). Wire to real sync later.
sub sync_models {
    my ($self, $c) = @_;
    return { success => 1, models => [] };
}

__PACKAGE__->meta->make_immutable;

1;
