package Comserv::Util::ClientIP;
use strict;
use warnings;

# Real client IP for rate limits / audit lines.
#
# Why this exists: script/comserv_server.psgi enables Plack's ReverseProxy only
# when the TCP peer is trusted (loopback + Docker ranges, or COMSERV_TRUSTED_PROXIES).
# ReverseProxy then REPLACES REMOTE_ADDR with the rightmost X-Forwarded-For hop,
# so $c->req->address is already the real client for a direct hit or an nginx
# front, but it is a Cloudflare edge address when the chain is
# client -> Cloudflare -> nginx -> app. HelpDesk.pm (_client_ip) and
# Util::AI::GuestGuard (client_ip) each solve part of this privately; this is the
# one shared version for the login throttle:
#
#   address NOT trusted  -> use it; CF-Connecting-IP / X-Forwarded-For are IGNORED
#                           (a client reaching the port directly can send any header)
#   address trusted      -> CF-Connecting-IP if it is a valid IP, else the
#                           rightmost X-Forwarded-For hop that is not itself trusted,
#                           else the address.
# "Trusted" = the SAME list the psgi uses (127.0.0.0/8, ::1, COMSERV_TRUSTED_PROXIES
# or the default Docker ranges) PLUS Cloudflare's published edge ranges, because of
# the REMOTE_ADDR rewrite described above.

my @CF_V4 = qw(173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22
    141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20
    197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13
    104.24.0.0/14 172.64.0.0/13 131.0.72.0/22);
my @CF_V6 = qw(2400:cb00: 2606:4700: 2803:f800: 2405:b500: 2405:8100: 2a06:98c0: 2a06:98c1: 2c0f:f248:);
my @DEFAULT_PSGI_V4 = qw(127.0.0.0/8 172.16.0.0/13 172.24.0.0/14 172.28.0.0/15);   # same default as comserv_server.psgi

sub _ip4_num { return $_[0] =~ /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/ && !grep({ $_ > 255 } $1, $2, $3, $4)
                   ? (($1 << 24) | ($2 << 16) | ($3 << 8) | $4) : undef }

sub _cidrs {
    my ($class, $list) = @_;
    my @out;
    for my $c (@$list) {
        next unless $c =~ m{^(\d+\.\d+\.\d+\.\d+)(?:/(\d+))?$};
        my ($n, $bits) = (_ip4_num($1), defined $2 ? $2 : 32);
        next unless defined $n && $bits <= 32;
        my $mask = $bits == 0 ? 0 : ((0xFFFFFFFF << (32 - $bits)) & 0xFFFFFFFF);
        push @out, [$n & $mask, $mask];
    }
    return \@out;
}

sub _psgi_list {
    my $raw = $ENV{COMSERV_TRUSTED_PROXIES};
    return (defined $raw && length $raw) ? [ split /[\s,]+/, $raw ] : [ @DEFAULT_PSGI_V4 ];
}

sub normalize {
    my ($class, $ip) = @_;
    return undef unless defined $ip;
    $ip =~ s/^\s+|\s+$//g;
    $ip =~ s/^::ffff://i;
    return undef unless $ip =~ /^(?:\d{1,3}(?:\.\d{1,3}){3}|(?=[0-9A-Fa-f:]*:)[0-9A-Fa-f:]{2,45})$/;
    return undef if $ip =~ /\./ && !defined _ip4_num($ip);
    return lc $ip;
}

sub is_trusted_proxy {
    my ($class, $addr) = @_;
    $addr = $class->normalize($addr);
    return 0 unless defined $addr;
    return 1 if $addr eq '::1';
    if ($addr =~ /\./) {
        my $n = _ip4_num($addr);
        for my $c (@{ $class->_cidrs(_psgi_list()) }, @{ $class->_cidrs(\@CF_V4) }) {
            return 1 if ($n & $c->[1]) == $c->[0];
        }
        return 0;
    }
    for my $p (@CF_V6) { return 1 if index($addr, $p) == 0 }
    return 0;
}

# Pure function (used by the tests): ($address, $cf_connecting_ip, $x_forwarded_for)
sub pick {
    my ($class, $addr, $cf, $xff) = @_;
    my $peer = $class->normalize($addr);
    return 'unknown' unless defined $peer;
    return $peer unless $class->is_trusted_proxy($peer);
    my $cfip = $class->normalize($cf);
    return $cfip if defined $cfip;
    if (defined $xff) {
        for my $hop (reverse split /\s*,\s*/, $xff) {
            my $h = $class->normalize($hop) // next;
            next if $class->is_trusted_proxy($h);
            return $h;
        }
    }
    return $peer;
}

sub from_c {
    my ($class, $c) = @_;
    my $req = eval { $c->req } or return 'unknown';
    return $class->pick(
        scalar(eval { $req->address }),
        scalar(eval { $req->header('CF-Connecting-IP') }),
        scalar(eval { $req->header('X-Forwarded-For') }),
    );
}

1;
