#!/usr/bin/env perl
# Comserv::Util::ClientIP: CF-Connecting-IP / X-Forwarded-For count only when the address Catalyst
# sees (REMOTE_ADDR after the psgi's trusted-proxy ReverseProxy) is itself a trusted proxy.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Comserv::Util::ClientIP;
my $P = 'Comserv::Util::ClientIP';
delete local $ENV{COMSERV_TRUSTED_PROXIES};

# 1. direct peer NOT trusted: spoofed headers ignored
is($P->pick('203.0.113.9', '1.2.3.4', '5.6.7.8'),          '203.0.113.9', 'untrusted peer: CF-Connecting-IP + XFF ignored');
is($P->pick('203.0.113.9', '127.0.0.1', '127.0.0.1'),       '203.0.113.9', 'untrusted peer: header claiming localhost ignored');
is($P->pick('172.30.5.5',  '1.1.1.1', undef),               '172.30.5.5',  'ZeroTier-style 172.30.x peer is not trusted (matches the psgi list)');
is($P->pick('10.1.2.3',    '1.1.1.1', '2.2.2.2'),           '10.1.2.3',    'LAN 10.x peer is not trusted');
is($P->pick('2001:db8::5', '1.1.1.1', undef),               '2001:db8::5', 'untrusted IPv6 peer');

# 2. trusted proxy + CF-Connecting-IP: used
is($P->pick('127.0.0.1',   '198.51.100.7', undef),          '198.51.100.7', 'loopback proxy + CF-Connecting-IP');
is($P->pick('::1',         '198.51.100.7', undef),          '198.51.100.7', '::1 proxy + CF-Connecting-IP');
is($P->pick('172.17.0.1',  '198.51.100.7', undef),          '198.51.100.7', 'Docker-range proxy + CF-Connecting-IP');
is($P->pick('172.70.1.1',  '198.51.100.8', '9.9.9.9, 172.70.1.1'), '198.51.100.8', 'Cloudflare edge address (ReverseProxy rewrote REMOTE_ADDR) + CF-Connecting-IP');
is($P->pick('::ffff:127.0.0.1', '198.51.100.9', undef),     '198.51.100.9', 'IPv4-mapped loopback');
is($P->pick('2606:4700::1', '2001:db8::77', undef),         '2001:db8::77', 'Cloudflare IPv6 edge + IPv6 client');
is($P->pick('127.0.0.1',   'not-an-ip', undef),             '127.0.0.1',    'garbage CF-Connecting-IP ignored');
is($P->pick('127.0.0.1',   '999.1.1.1', undef),             '127.0.0.1',    'out-of-range octets ignored');
is($P->pick('127.0.0.1',   "1.2.3.4\r\nX: y", undef),       '127.0.0.1',    'header with CR/LF ignored');

# 2b. trusted proxy, no CF header: rightmost untrusted X-Forwarded-For hop (never the client-chosen leftmost)
is($P->pick('127.0.0.1', undef, '6.6.6.6, 198.51.100.20'),                '198.51.100.20', 'XFF: rightmost hop');
is($P->pick('127.0.0.1', undef, '6.6.6.6, 198.51.100.20, 172.17.0.2'),    '198.51.100.20', 'XFF: trusted hops on the right are skipped');
is($P->pick('127.0.0.1', undef, 'garbage'),                                '127.0.0.1',     'XFF garbage ignored');

# 3. no headers
is($P->pick('203.0.113.9', undef, undef), '203.0.113.9', 'no headers: peer address');
is($P->pick('127.0.0.1',   undef, undef), '127.0.0.1',   'no headers, trusted peer: peer address');
is($P->pick(undef, undef, undef),         'unknown',     'no address at all: unknown');
is($P->pick('garbage', '1.2.3.4', undef), 'unknown',     'unparseable address: unknown');

# COMSERV_TRUSTED_PROXIES is the same list the psgi reads
{
    local $ENV{COMSERV_TRUSTED_PROXIES} = '192.168.1.0/24, 127.0.0.1';
    is($P->pick('192.168.1.10', '198.51.100.30', undef), '198.51.100.30', 'env list: configured proxy is trusted');
    is($P->pick('172.17.0.1',   '198.51.100.30', undef), '172.17.0.1',    'env list replaces the Docker default (same as the psgi)');
}

# from_c
{
    package FReq; sub new { my ($c, %a) = @_; bless {%a}, $c } sub address { $_[0]{address} } sub header { $_[0]{h}{$_[1]} }
    package FC;   sub new { bless { req => $_[1] }, $_[0] } sub req { $_[0]{req} }
}
is($P->from_c(FC->new(FReq->new(address => '203.0.113.9', h => { 'CF-Connecting-IP' => '1.2.3.4' }))), '203.0.113.9', 'from_c: untrusted peer');
is($P->from_c(FC->new(FReq->new(address => '127.0.0.1',   h => { 'CF-Connecting-IP' => '1.2.3.4' }))), '1.2.3.4',     'from_c: trusted proxy');
is($P->from_c(FC->new(FReq->new(address => '127.0.0.1',   h => {}))), '127.0.0.1', 'from_c: no headers');
is($P->from_c(undef), 'unknown', 'from_c: no context');
done_testing;
