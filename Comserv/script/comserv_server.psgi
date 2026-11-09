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
use Comserv::Util::ApkDownload;
use Comserv::Util::PortlessHost;
use Plack::Builder;
use Plack::MIME;
use Plack::Util;

# The image's Plack::MIME map has no .apk entry. Without this, File.pm
# falls back to text/plain and Android saves ComservInventory.apk.txt.
Plack::MIME->add_type('.apk' => Comserv::Util::ApkDownload::CONTENT_TYPE);

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

    # Public hostnames never carry a port (balancer does not accept one). Catalyst appends
    # SERVER_PORT (:5000) to generated URLs when Host has none; normalise after ReverseProxy.
    # dev.* / IP / localhost / *.local keep their port. COMSERV_PORTLESS_HOST=0 disables.
    enable sub {
        my $inner = shift;
        sub { Comserv::Util::PortlessHost::normalize_env($_[0]); $inner->($_[0]) };
    };

    # Outside Static so an .apk response is rewritten even when an old
    # Plack::MIME map would have labeled it text/plain.
    enable sub {
        my $inner = shift;
        sub {
            my $env = shift;
            my $path = $env->{PATH_INFO} || '';
            if (Comserv::Util::ApkDownload::is_apk($path)) {
                my $pub = eval { Comserv::Util::ApkDownload::publish_latest_build() };
                warn "apk publish failed: " . ($@ || $pub->{error}) if $@ || (ref $pub eq 'HASH' && $pub->{error});
            }
            my $res = $inner->($env);
            my $fix = sub {
                my $r = shift;
                return $r unless Comserv::Util::ApkDownload::is_apk($path);
                return $r unless ref $r eq 'ARRAY' && ($r->[0] || 0) == 200;
                my $h = Plack::Util::headers($r->[1]);
                $h->set('Content-Type', Comserv::Util::ApkDownload::CONTENT_TYPE);
                my $disp = Comserv::Util::ApkDownload::disposition_for($path);
                $h->set('Content-Disposition', $disp) if $disp;
                return $r;
            };
            if (ref $res eq 'CODE') {
                return sub {
                    my $respond = shift;
                    $res->(sub { $respond->($fix->($_[0])) });
                };
            }
            return $fix->($res);
        };
    };

    # Static file serving for the navigation/menu bar (CSS/JS) + general assets
    # This must come BEFORE the main app so static requests are handled first.
    # content_type is required: the coderef replaces Plack::MIME, and a missing
    # .apk entry otherwise becomes text/plain; charset=utf-8.
    enable 'Plack::Middleware::Static',
        path => qr{^/(static|css|js|images|favicon|root|assets)},
        root => "$FindBin::Bin/../root",
        content_type => sub {
            my ($file) = @_;
            return Comserv::Util::ApkDownload::CONTENT_TYPE
                if Comserv::Util::ApkDownload::is_apk($file);
            return Plack::MIME->mime_type($file) || 'text/plain';
        };

    $app;
};
# Fork-safety for Starman workers (Oct 2026: retired workers stuck at 50-68%
# CPU for days, holding the listen socket, while the master spawned
# replacements -> 21/15 "starman worker" processes against --workers 8).
# A worker that leaves after --max-requests runs END blocks and global
# destruction, including DBI->disconnect_all over handles it shares with
# siblings/the master (the app is preloaded); that is where they spin or
# segfault in DBD::mysql. Leave workers via POSIX::_exit after flushing
# output. This END is compiled after DBI's, so it runs first. The master
# ("starman master") and non-Starman runs are unaffected.
END {
    if (($0 // '') =~ /^starman worker/) {
        my $rc = $?;
        eval { require IO::Handle; STDOUT->flush; STDERR->flush; 1 };
        require POSIX;
        POSIX::_exit($rc);
    }
}

return $wrapped;
