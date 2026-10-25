#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;

# Set up local::lib and local paths for running under Starman/PSGI
use lib "$FindBin::Bin/../local/lib/perl5";
use Config;
BEGIN {
    my $archname = $Config{archname};
    my $version = $Config{version};
    unshift @INC, "$FindBin::Bin/../local/lib/perl5/$archname" if $archname;
    unshift @INC, "$FindBin::Bin/../local/lib/perl5/$version/$archname" if $version && $archname;
    unshift @INC, "$FindBin::Bin/../local/lib/perl5/$version" if $version;
    
    # Also add architecture specific multi-thread directories
    unshift @INC, "$FindBin::Bin/../local/lib/perl5/x86_64-linux-gnu-thread-multi";
    unshift @INC, "$FindBin::Bin/../local/lib/perl5/site_perl";
}

use lib $ENV{CATALYST_HOME} ? "$ENV{CATALYST_HOME}/lib" : "$FindBin::Bin/../lib";
use lib $ENV{CATALYST_HOME} ? $ENV{CATALYST_HOME} : "$FindBin::Bin/..";

use Comserv;
use Plack::Builder;

# Survives plackup -R restarts: marks Twiggy mode for WebSocket terminal detection.
my $_app_root = $ENV{CATALYST_HOME} ? $ENV{CATALYST_HOME} : "$FindBin::Bin/..";
if (-f "$_app_root/var/twiggy.enabled") {
    $ENV{COMSERV_TWIGGY}         = '1';
    $ENV{PLACK_SERVER_SOFTWARE} ||= 'Twiggy';
}

my $app = Comserv->psgi_app;

# Only honour X-Forwarded-For when the TCP peer is a trusted proxy (nginx or
# another local container). Without this, any client that can reach the port
# can send "X-Forwarded-For: 127.0.0.1" and be treated as local by the /api
# LAN bypass. Override with COMSERV_TRUSTED_PROXIES="cidr,cidr,..." (IPv4 only;
# "::1" and "127.0.0.1" always count). Default = loopback plus the Docker
# private ranges 172.16.0.0-172.29.255.255 (ZeroTier 172.30.x is NOT trusted).
sub _comserv_trusted_cidrs {
    my $raw = $ENV{COMSERV_TRUSTED_PROXIES};
    my @list = (defined $raw && length $raw)
        ? split(/\s*,\s*/, $raw)
        : qw(127.0.0.0/8 172.16.0.0/13 172.24.0.0/14 172.28.0.0/15);
    my @out;
    for my $c (@list) {
        next unless $c =~ m{^(\d+)\.(\d+)\.(\d+)\.(\d+)(?:/(\d+))?$};
        my ($ip, $bits) = (($1 << 24) | ($2 << 16) | ($3 << 8) | $4, defined $5 ? $5 : 32);
        next if $bits > 32;
        my $mask = $bits == 0 ? 0 : ((0xFFFFFFFF << (32 - $bits)) & 0xFFFFFFFF);
        push @out, [$ip & $mask, $mask];
    }
    return \@out;
}
my $_trusted_cidrs = _comserv_trusted_cidrs();

sub _comserv_peer_trusted {
    my ($addr) = @_;
    return 0 unless defined $addr;
    return 1 if $addr eq '::1';
    $addr =~ s/^::ffff://i;
    return 0 unless $addr =~ m{^(\d+)\.(\d+)\.(\d+)\.(\d+)$};
    my $ip = ($1 << 24) | ($2 << 16) | ($3 << 8) | $4;
    for my $c (@$_trusted_cidrs) {
        return 1 if ($ip & $c->[1]) == $c->[0];
    }
    return 0;
}

my $wrapped = builder {
    enable_if { _comserv_peer_trusted($_[0]->{REMOTE_ADDR}) } 'ReverseProxy';

    # Static file serving for the navigation/menu bar (CSS/JS) + general assets
    # This must come BEFORE the main app so static requests are handled first
    enable 'Plack::Middleware::Static',
        path => qr{^/(static|css|js|images|favicon|root|assets)},
        root => "$FindBin::Bin/../root";

    $app;
};
return $wrapped;
