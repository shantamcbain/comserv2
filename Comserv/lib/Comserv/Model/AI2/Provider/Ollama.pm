package Comserv::Model::AI2::Provider::Ollama;

use Moose;
use namespace::autoclean;

use Try::Tiny;
use LWP::UserAgent;
use JSON qw(decode_json);

use Comserv::Util::Logging;

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

# Placeholder for model sync (pull/refresh). Wire to real sync later.
sub sync_models {
    my ($self, $c) = @_;
    return { success => 1, models => [] };
}

__PACKAGE__->meta->make_immutable;

1;
