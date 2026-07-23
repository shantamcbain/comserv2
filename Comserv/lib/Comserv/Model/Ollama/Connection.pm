package Comserv::Model::Ollama::Connection;
use Moose::Role;
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)
use LWP::UserAgent;
use HTTP::Request;
use JSON;
use Try::Tiny;
use Comserv::Util::Logging;

has 'host' => (
    is => 'rw',
    isa => 'Str',
    default => '192.168.1.199',
    trigger => sub {
        my ($self) = @_;
        $self->clear_endpoint if $self->can('clear_endpoint');
    },
    documentation => 'Ollama server host (default: 192.168.1.199 — overridden by comserv.conf <Ollama> block)'
);

has 'port' => (
    is => 'rw',
    isa => 'Int',
    default => 11434,
    trigger => sub {
        my ($self) = @_;
        $self->clear_endpoint if $self->can('clear_endpoint');
    },
    documentation => 'Ollama server port'
);

has 'endpoint' => (
    is => 'rw',
    isa => 'Str',
    lazy => 1,
    builder => '_build_endpoint',
    clearer => 'clear_endpoint',
    documentation => 'Full Ollama API endpoint URL'
);

has 'timeout' => (
    is => 'rw',
    isa => 'Int',
    default => 120,
    # Propagate timeout changes to the (lazy-built) UA. The UA is built once from
    # $self->timeout at construction; if AI.pm raises timeout later (e.g. 480s for
    # warm/cold models) the already-built UA would keep the old 120s and silently
    # time out. Clearing ua forces a rebuild with the new value on next request.
    trigger => sub {
        my ($self) = @_;
        $self->clear_ua if $self->can('clear_ua');
    },
    documentation => 'HTTP request timeout in seconds'
);

has 'ua' => (
    is => 'rw',
    isa => 'LWP::UserAgent',
    lazy => 1,
    builder => '_build_ua',
    clearer => 'clear_ua',
    documentation => 'LWP UserAgent for HTTP requests'
);

has 'last_error' => (
    is => 'rw',
    isa => 'Str',
    default => '',
    documentation => 'Last error message from API calls'
);

sub _build_endpoint {
    my ($self) = @_;
    return sprintf("http://%s:%d", $self->host, $self->port);
}

sub _build_ua {
    my ($self) = @_;
    my $ua = LWP::UserAgent->new(
        timeout => $self->timeout,
        agent   => 'Comserv-Ollama-Client/1.0',
    );
    return $ua;
}

sub set_host {
    my ($self, $host) = @_;
    $self->host($host);
    return $self;
}

sub get_connection_info {
    my ($self) = @_;
    return {
        host     => $self->host,
        port     => $self->port,
        endpoint => $self->endpoint,
        timeout  => $self->timeout,
    };
}

sub check_connection {
    my ($self) = @_;
    my $url = $self->endpoint . '/api/tags';
    my $req = HTTP::Request->new(GET => $url);
    my $res = $self->ua->request($req);
    if ($res->is_success) {
        $self->last_error('');
        return 1;
    } else {
        $self->last_error($res->status_line);
        return 0;
    }
}

sub get_version {
    my ($self) = @_;
    my $url = $self->endpoint . '/api/version';
    my $req = HTTP::Request->new(GET => $url);
    my $orig = $self->ua->timeout;
    $self->ua->timeout(3);
    my $res = $self->ua->request($req);
    $self->ua->timeout($orig);
    return undef unless $res->is_success;
    my $data;
    eval { $data = decode_json($res->content); };
    return $data && $data->{version};
}

1;