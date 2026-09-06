package Comserv::Model::AI2::Provider::Ollama;

use Moose;
extends 'Catalyst::Model';
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)

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

    my $ua  = LWP::UserAgent->new(timeout => 2);
    my $res = try { $ua->get("http://$host:$port/api/tags") } catch { undef };
    return $res && $res->is_success ? 1 : 0;
}

# Resolve the FIRST reachable Ollama host/port for THIS deployment.
#
# The workstation is reachable at two addresses for the same machine:
#   192.168.1.199   (LAN — works from the host process on :4006/:3001)
#   172.30.131.126  (ZeroTier — works from remote hosts like production1)
# A Docker container on the workstation reaches the host via
# host.docker.internal (mapped in the compose extra_hosts) — IF the host
# firewall accepts docker-bridge → host:11434. Without that path, probes
# time out and MUST NOT fall into a 120–480s chat hang (CSC-20260831-1585).
#
# Probe order:
#   1) $ENV{OLLAMA_HOST}            (per-deployment override, e.g. compose env)
#   2) host.docker.internal         (when running inside a container)
#   3) comserv.conf <Ollama> host   (primary — LAN)
#   4) comserv.conf fallback_host   (ZeroTier / alternate)
# Returns ($host, $port, $reachable). $reachable is 0 when nothing answered.
# Negative results are cached ~30s so Starman workers are not pinned by
# repeated dead probes on every /ai2/chat or catalog refresh.
our %_RESOLVE_CACHE;    # key => [epoch, host, port, reachable]
our $_RESOLVE_TTL = 30;

sub resolve_host {
    my ($self, $c) = @_;
    my $cfg      = ($c && $c->config->{Ollama}) || {};
    my $primary  = $cfg->{host}          || '192.168.1.199';
    my $fallback = $cfg->{fallback_host} || $primary;
    my $port     = ($ENV{OLLAMA_PORT} && $ENV{OLLAMA_PORT} =~ /^\d+$/)
                 ? $ENV{OLLAMA_PORT} : ($cfg->{port} || 11434);

    my $in_docker = (-f '/.dockerenv' || ($ENV{SYSTEM_IDENTIFIER} // '') =~ /prod-local|docker/i) ? 1 : 0;
    my $cache_key = join('|', $ENV{OLLAMA_HOST} // '', $primary, $fallback, $port, $in_docker);
    if (my $hit = $_RESOLVE_CACHE{$cache_key}) {
        my ($ts, $h, $p, $ok) = @$hit;
        if ((time - $ts) < $_RESOLVE_TTL) {
            return ($h, $p, $ok);
        }
    }

    my @candidates;
    push @candidates, $ENV{OLLAMA_HOST} if $ENV{OLLAMA_HOST};
    push @candidates, 'host.docker.internal' if $in_docker;
    push @candidates, $primary;
    push @candidates, $fallback if $fallback ne $primary;

    my %seen;
    for my $h (grep { $_ && !$seen{$_}++ } @candidates) {
        if ($self->check_connection($c, $h, $port)) {
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__,
                'ollama_resolve_host', "Ollama reachable at $h:$port");
            $_RESOLVE_CACHE{$cache_key} = [time, $h, $port, 1];
            return ($h, $port, 1);
        }
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'ollama_resolve_host', "Ollama not reachable at $h:$port, trying next");
    }
    # Nothing answered — return primary with reachable=0 so callers fail fast
    # instead of issuing a multi-minute generate against a dead host.
    $_RESOLVE_CACHE{$cache_key} = [time, $primary, $port, 0];
    return ($primary, $port, 0);
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
    my $model    = $args{model}    || 'phi4:14b';
    my ($rhost, $rport, $reachable) = $self->resolve_host($c);
    my $host     = $args{host}     || $rhost;
    my $port     = $args{port}     || $rport;

    # Fail fast when resolve_host already proved the endpoint dead. Without
    # this guard, get_running_models/chat use 120–480s timeouts and the UI
    # sticks on "Thinking… (Ollama/fast)" (CSC-20260831-1585 / docker).
    if (defined $reachable && !$reachable && !$args{host}) {
        my $err = "Can't connect to Ollama at $host:$port (timed out). "
                . 'Pick an external/free model, or fix docker→host Ollama '
                . '(compose extra_hosts + host firewall / OLLAMA_HOST).';
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'ollama_chat', $err);
        return { success => 0, error => $err, unreachable => 1 };
    }
    unless ($self->check_connection($c, $host, $port)) {
        my $err = "Can't connect to Ollama at $host:$port (timed out). "
                . 'Pick an external/free model, or fix docker→host Ollama networking.';
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'ollama_chat', $err);
        return { success => 0, error => $err, unreachable => 1 };
    }

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

# Return the list of models currently RESIDENT in the Ollama server (loaded in
# RAM/VRAM), newest-first by nothing in particular — just what /api/ps reports.
# Used to prefer an already-warm model and avoid a cold weight-load when the
# task (e.g. commit-message drafting) doesn't need a specific model.
sub running_models {
    my ($self, $c, $host, $port) = @_;
    ($host, $port) = $self->resolve_host($c) unless $host && $port;

    my $ua  = LWP::UserAgent->new(timeout => 5);
    my $url = "http://$host:$port/api/ps";

    my $res = try { $ua->get($url) } catch {
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__,
            'ollama_running_models', "ps failed at $url: $_");
        undef;
    };
    return [] unless $res && $res->is_success;

    my $data = try { decode_json($res->decoded_content) } catch { undef };
    return [] unless $data && $data->{models};

    return [ map { ref($_) ? ($_->{name} // '') : $_ } @{ $data->{models} } ];
}

__PACKAGE__->meta->make_immutable;

1;
