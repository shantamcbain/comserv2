package Comserv::Util::OriginCheck;

# Same-origin check for state-changing POSTs (the app has no shared CSRF token).
# Every Origin/Referer header present must parse as scheme://host[:port] and
# match the request's canonical scheme, host and effective port. At least one
# must be present. Absent, "null", or malformed => refused (fail closed).
# The external scheme/port may come from X-Forwarded-Proto / X-Forwarded-Port
# ONLY when the direct peer is a trusted proxy (Comserv::Util::ClientIP).

use strict;
use warnings;

my %DEFAULT_PORT = ( http => 80, https => 443 );

# "https://Host:8443/x" -> { scheme, host, port } or undef if malformed.
sub parse {
    my ( $class, $v ) = @_;
    return undef unless defined $v && length $v && length($v) <= 2048;
    return undef unless $v =~ m{\A(https?)://([A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?|\[[0-9A-Fa-f:.]+\])(?::(\d{1,5}))?(?:[/?#]|\z)};
    my ( $scheme, $host, $port ) = ( lc $1, lc $2, $3 );
    $port = $DEFAULT_PORT{$scheme} unless defined $port && length $port;
    return undef if $port < 1 || $port > 65535;
    return { scheme => $scheme, host => $host, port => $port + 0 };
}

# Canonical origin of this request: { scheme, host, port }.
sub expected {
    my ( $class, $c ) = @_;
    my $req  = $c->req;
    my $uri  = eval { $req->uri } or return undef;
    my $host = lc( eval { $uri->host } // '' );
    return undef unless length $host;
    my $scheme = eval { $req->secure } ? 'https' : 'http';
    my $port   = eval { $uri->port };
    my $fp     = lc( $req->header('X-Forwarded-Proto') // '' );
    $fp =~ s/\s*,.*//;
    if ( $fp =~ /\A(https?)\z/ ) {
        require Comserv::Util::ClientIP;
        my $peer = eval { $req->address };
        if ( defined $peer && Comserv::Util::ClientIP->is_trusted_proxy($peer) ) {
            $scheme = $fp;
            my $xp = $req->header('X-Forwarded-Port') // '';
            $port = $xp =~ /\A(\d{1,5})\z/ ? $1 : $DEFAULT_PORT{$scheme};
        }
    }
    $port = $DEFAULT_PORT{$scheme} unless defined $port && $port =~ /\A\d+\z/;
    return { scheme => $scheme, host => $host, port => $port + 0 };
}

# Pure: $want = { scheme, host, port }; @hdrs = Origin/Referer values.
sub matches {
    my ( $class, $want, @hdrs ) = @_;
    return 0 unless ref $want eq 'HASH' && $want->{host};
    my $seen = 0;
    for my $v (@hdrs) {
        next unless defined $v && length $v;
        my $got = $class->parse($v) or return 0;    # "null"/malformed => refuse
        return 0 unless $got->{scheme} eq $want->{scheme}
                     && $got->{host}   eq lc $want->{host}
                     && $got->{port}   == $want->{port};
        $seen++;
    }
    return $seen ? 1 : 0;
}

sub request_ok {
    my ( $class, $c ) = @_;
    my $want = $class->expected($c) or return 0;
    return $class->matches( $want, $c->req->header('Origin'), $c->req->header('Referer') );
}

1;
