package Comserv::Util::ApiDomainDetector;

use strict;
use warnings;
use JSON::MaybeXS;
use Path::Tiny;

sub is_local_domain {
    my ($class, $c) = @_;
    
    my $host = $c->req->header('Host') || '';
    $host =~ s/:\d+$//;
    
    my $config = $class->_load_config();
    my $env_name = $config->{current_environment} || 'development';
    my $env_config = $config->{environments}{$env_name};
    
    return 0 unless $env_config && $env_config->{local_bypass_enabled};
    
    foreach my $pattern (@{$env_config->{local_domains} || []}) {
        return 1 if $class->_domain_matches($host, $pattern);
    }
    
    return 0;
}

sub _load_config {
    my ($class) = @_;
    
    my @paths = (
        'config/api_domains.json',
        'Comserv/config/api_domains.json',
        '../config/api_domains.json'
    );
    
    foreach my $path (@paths) {
        my $config_file = path($path);
        if ($config_file->exists) {
            return decode_json($config_file->slurp_utf8);
        }
    }
    
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

sub _domain_matches {
    my ($class, $host, $pattern) = @_;
    
    return 1 if $host eq $pattern;
    
    if ($pattern =~ /^\*\.(.+)$/) {
        my $suffix = $1;
        return 1 if $host =~ /\.\Q$suffix\E$/;
        return 1 if $host eq $suffix;
    }
    
    return 0;
}

1;

__END__

=head1 NAME

Comserv::Util::ApiDomainDetector - Domain-based authentication detection utility

=head1 DESCRIPTION

Utility for detecting if API requests are from local domains that should bypass authentication.
Reads configuration from config/api_domains.json.

=head1 SYNOPSIS

  use Comserv::Util::ApiDomainDetector;
  
  sub api_list_todos {
      my ($self, $c) = @_;
      
      my $is_local = Comserv::Util::ApiDomainDetector->is_local_domain($c);
      
      unless ($is_local) {
          # Validate token...
      }
  }

=head1 METHODS

=head2 is_local_domain($c)

Returns 1 if the request is from a local domain (based on Host header and config), 0 otherwise.

Arguments:
  $c - Catalyst context

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

=head1 DOMAIN MATCHING

Supports:
- Exact match: "localhost", "127.0.0.1"
- Wildcard: "*.local" matches "api.workstation.local", "test.local", etc.

=head1 AUTHOR

Comserv Development Team

=cut
