package Comserv::Util::PortlessHost;
use strict;
use warnings;

=head1 NAME

Comserv::Util::PortlessHost - keep internal listen ports out of generated URLs

=head1 DESCRIPTION

Catalyst::Engine::prepare_path builds req->uri / req->base (and therefore every
uri_for, redirect and admin link) from HTTP_HOST, and APPENDS SERVER_PORT when
the host has no port and SERVER_PORT is not 80/443. A container that listens on
:5000 therefore emits http://computersystemconsulting.ca:5000/... even when the
client sent a portless Host. Public hostnames sit behind a balancer and do not
accept a port, so for those we drop any port from HTTP_HOST and present
SERVER_PORT as 80/443 (by scheme).

Exempt (port kept untouched): dev.* hosts (dev.computersystemconsulting.ca),
IP literals, localhost, single-label names and *.local/.localhost/.lan/.internal/
.zero/.test/.example style dev names.

Disable with COMSERV_PORTLESS_HOST=0.

=cut

sub is_port_exempt_host {
    my ($host) = @_;
    return 1 unless defined $host && length $host;
    $host = lc $host;
    return 1 if $host =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;      # IPv4
    return 1 if $host =~ /:/;                               # IPv6 / garbage
    return 1 if $host !~ /\./;                              # localhost, single label
    return 1 if $host =~ /^dev\./;                          # dev.computersystemconsulting.ca
    return 1 if $host =~ /\.(?:local|localhost|lan|internal|zero|test|example|invalid)$/;
    return 0;
}

# Returns the normalized Host header value (or the input unchanged).
sub normalize_host {
    my ($http_host) = @_;
    return $http_host unless defined $http_host && length $http_host;
    return $http_host if $http_host =~ /^\[/;               # bracketed IPv6
    return $http_host unless $http_host =~ /^([^:\s\/\@]+):(\d{1,5})$/;
    my ($h, $p) = ($1, $2);
    return $http_host if is_port_exempt_host($h);
    return $h;
}

# Mutates a PSGI env in place for non-exempt public hosts.
sub normalize_env {
    my ($env) = @_;
    return $env if defined $ENV{COMSERV_PORTLESS_HOST} && $ENV{COMSERV_PORTLESS_HOST} eq '0';
    my $hh = $env->{HTTP_HOST};
    my $name = defined $hh && length $hh ? $hh : $env->{SERVER_NAME};
    return $env unless defined $name && length $name;
    return $env if $name =~ /^\[/;
    my ($h) = $name =~ /^([^:\s\/\@]+)(?::\d{1,5})?$/;
    return $env unless defined $h;
    return $env if is_port_exempt_host($h);
    $env->{HTTP_HOST} = $h if defined $hh && length $hh;
    $env->{SERVER_NAME} = $h if defined $env->{SERVER_NAME} && $env->{SERVER_NAME} =~ /^\Q$h\E$/i;
    $env->{SERVER_PORT} = (($env->{'psgi.url_scheme'} // '') eq 'https') ? 443 : 80;
    return $env;
}

1;
