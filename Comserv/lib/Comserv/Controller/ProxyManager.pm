package Comserv::Controller::ProxyManager;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use JSON::MaybeXS qw(encode_json decode_json);
use LWP::UserAgent;
use Try::Tiny;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has 'npm_api' => (
    is => 'ro',
    default => sub {
        my $self = shift;
        return {
            url => $ENV{NPM_API_URL} || 'http://localhost:81/api',
            key => $ENV{NPM_API_KEY} || 'dummy_key_for_development'
        };
    }
);

sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto',
        "ProxyManager controller auto method called");

    # Check if we have a valid API key
    if ($self->npm_api->{key} eq 'dummy_key_for_development') {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto',
            "NPM_API_KEY environment variable not set. Using dummy key for development.");
        $c->stash->{api_warning} = "NPM API key not configured. Some features may not work correctly.";
    }

    # Initialize API client
    $c->stash->{npm_ua} = LWP::UserAgent->new(
        timeout => 10,
        default_headers => HTTP::Headers->new(
            Authorization => "Bearer " . $self->npm_api->{key},
            'Content-Type' => 'application/json'
        )
    );

    return 1;
}

sub index :Path :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "ProxyManager dashboard accessed");

    try {
        my $res = $c->stash->{npm_ua}->get($self->npm_api->{url} . "/nginx/proxy-hosts");
        unless ($res->is_success) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index',
                "Failed to fetch proxies: " . $res->status_line);
            $c->detach('/error');
        }

        $c->stash(
            proxies => decode_json($res->decoded_content),
            template => 'CSC/proxy_manager.tt'
        );
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index',
            "Proxy fetch failed: $_");
        $c->detach('/error');
    };
}

sub create_proxy :Local :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_proxy',
        "Creating new proxy mapping");

    my $params = {
        domain_names    => [$c->req->params->{domain}],
        forward_scheme  => $c->req->params->{scheme} || 'http',
        forward_host    => $c->req->params->{backend_ip},
        forward_port    => $c->req->params->{backend_port},
        ssl_forced      => $c->req->params->{ssl} ? JSON::true : JSON::false,
        advanced_config => join("\n",
            "proxy_set_header Host \$host;",
            "proxy_set_header X-Real-IP \$remote_addr;")
    };

    try {
        my $res = $c->stash->{npm_ua}->post(
            $self->npm_api->{url} . "/nginx/proxy-hosts",
            Content => encode_json($params)
        );

        unless ($res->is_success) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_proxy',
                "Proxy creation failed: " . $res->status_line);
            $c->detach('/error');
        }

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_proxy',
            "Successfully created proxy for " . $params->{domain_names}[0]);
        $c->res->redirect($c->uri_for('/proxymanager'));
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_proxy',
            "Proxy creation error: $_");
        $c->detach('/error');
    };
}

__PACKAGE__->meta->make_immutable;
1;