package Comserv::Middleware::ApiDomainDetector;

use Moose;
use namespace::autoclean;
use JSON::MaybeXS;
use Path::Tiny;
use Comserv::Util::Logging;

extends 'Plack::Middleware';

has 'config_path' => (
    is => 'rw',
    isa => 'Str',
    default => 'config/api_domains.json'
);

has 'config' => (
    is => 'ro',
    isa => 'HashRef',
    lazy => 1,
    builder => '_load_config'
);

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub _load_config {
    my ($self) = @_;
    
    my $config_file = path($self->config_path);
    
    unless ($config_file->exists) {
        $config_file = path('Comserv', $self->config_path);
    }
    
    unless ($config_file->exists) {
        warn "api_domains.json not found, using defaults\n";
        return {
            environments => {
                development => {
                    external_domain => 'api.workstation.local',
                    local_domains => ['*.local', 'localhost', '127.0.0.1'],
                    require_https => 0,
                    local_bypass_enabled => 1
                }
            },
            current_environment => 'development'
        };
    }
    
    return decode_json($config_file->slurp_utf8);
}

sub call {
    my ($self, $env) = @_;
    
    my $host = $env->{HTTP_HOST} || '';
    $host =~ s/:\d+$//;
    
    my $config = $self->config;
    my $env_name = $config->{current_environment} || 'development';
    my $env_config = $config->{environments}{$env_name};
    
    my $is_local = 0;
    if ($env_config && $env_config->{local_bypass_enabled}) {
        foreach my $pattern (@{$env_config->{local_domains} || []}) {
            if ($self->_domain_matches($host, $pattern)) {
                $is_local = 1;
                last;
            }
        }
    }
    
    $env->{'comserv.api.is_local_domain'} = $is_local;
    $env->{'comserv.api.request_domain'} = $host;
    
    return $self->app->($env);
}

sub _domain_matches {
    my ($self, $host, $pattern) = @_;
    
    return 1 if $host eq $pattern;
    
    if ($pattern =~ /^\*\.(.+)$/) {
        my $suffix = $1;
        return 1 if $host =~ /\.\Q$suffix\E$/;
        return 1 if $host eq $suffix;
    }
    
    return 0;
}

__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 NAME

Comserv::Middleware::ApiDomainDetector - Domain-based authentication detection middleware

=head1 DESCRIPTION

PSGI middleware that detects request domain and sets flags for local domain bypass.
Reads configuration from config/api_domains.json and determines if the request
should bypass authentication based on domain patterns.

=head1 CONFIGURATION

Configuration file: config/api_domains.json

  {
    "environments": {
      "development": {
        "external_domain": "api.workstation.local",
        "local_domains": ["*.local", "localhost", "127.0.0.1"],
        "require_https": false,
        "local_bypass_enabled": true
      }
    },
    "current_environment": "development"
  }

=head1 STASH VARIABLES

Sets the following values in the Catalyst stash:

  $c->stash->{is_local_domain}  - Boolean flag (1 if local, 0 if external)
  $c->stash->{request_domain}   - String containing the request domain

=head1 DOMAIN MATCHING

Supports:
- Exact match: "localhost", "127.0.0.1"
- Wildcard: "*.local" matches "api.workstation.local", "test.local", etc.

=head1 USAGE

In Comserv.pm:

  use Plack::Builder;
  use Comserv::Middleware::ApiDomainDetector;
  
  builder {
      enable "+Comserv::Middleware::ApiDomainDetector";
      $app->psgi_app;
  };

=head1 AUTHOR

Comserv Development Team

=cut
