use strict;
use warnings;
use lib 'lib';
use Test::More;
use JSON::MaybeXS qw(decode_json);
use Comserv::Util::ZeroTier;

my $Z = 'Comserv::Util::ZeroTier';

is($Comserv::Util::ZeroTier::DEFAULT_NETWORK_ID, 'af78bf943680bfeb', 'default network is the one this app cannot see');

my $members = [
    { nodeId => 'aaa', name => 'gw', config => { ipAssignments => ['172.30.39.1'], authorized => 1 } },
    { nodeId => 'bbb', name => 'ws', config => { ipAssignments => ['172.30.39.8'], authorized => 1 } },
];
my $routes = Comserv::Util::ZeroTier::flag_orphan_routes([
    { target => '192.168.1.0/24', via => '172.30.39.42' },
    { target => '172.30.39.0/24', via => '172.30.39.1' },
    { target => '10.0.0.0/8', via => undef },
], $members);
is($routes->[0]{orphan}, 1, 'via 172.30.39.42 is flagged: no device has it');
is($routes->[1]{orphan}, 0, 'via that a device has is not flagged');
is($routes->[2]{orphan}, 0, 'empty via is not an orphan');

my $bad = Comserv::Util::ZeroTier::parse_routes("192.168.1.0/24 via 999.1.1.1\n");
ok(!$bad->{ok}, 'bad via rejected');
my $empty = Comserv::Util::ZeroTier::parse_routes("\n# nothing\n");
ok(!$empty->{ok}, 'empty route list rejected so a preview cannot wipe routes');
my $ok = Comserv::Util::ZeroTier::parse_routes("192.168.1.0/24 via 172.30.39.1\n10.147.17.0/24\n");
ok($ok->{ok}, 'route text parsed');
is($ok->{routes}[1]{via}, '', 'route without via has an empty via');

my $dns = Comserv::Util::ZeroTier::parse_dns('lan.example', "1.1.1.1\n\n8.8.8.8\n");
ok($dns->{ok}, 'dns parsed');
is($dns->{dns}{servers}[1], '8.8.8.8', 'second dns server kept');
ok(!Comserv::Util::ZeroTier::parse_dns('bad domain!', "1.1.1.1")->{ok}, 'dns domain rejected');

my $secret = 'zt-test-token';
my $err = Comserv::Util::ZeroTier::redact("Authorization token $secret failed", $secret);
unlike($err, qr/\Q$secret\E/, 'redact removes the token');
like($err, qr/\[redacted\]/, 'redact leaves a marker');

my $body = Comserv::Util::ZeroTier::update_body(
    [{ target => '192.168.1.0/24', via => '' }, { target => '10.0.0.0/8', via => '172.30.39.1' }],
    { domain => '', servers => ['1.1.1.1'] },
);
is_deeply([sort keys %{ $body->{config} }], ['dns', 'routes'], 'update sends only routes and dns');
ok(!exists $body->{config}{name}, 'update does not send the network name');
my $encoded = JSON::MaybeXS::encode_json($body);
like($encoded, qr/"via":null/, 'empty via is sent as null so Central can clear it');
unlike($encoded, qr/rules|ipAssignmentPools|token/, 'update body has no rules, pools, or token');

my $proposed = { routes => $ok->{routes}, dns => $dns->{dns} };
my $sha = Comserv::Util::ZeroTier::pending_sha('update', 'af78bf943680bfeb', $proposed);
my $pending = { op => 'update', sha => $sha, at => 1000, proposed => $proposed, network_id => 'af78bf943680bfeb' };
ok(Comserv::Util::ZeroTier::pending_ok($pending, $sha, 1000), 'matching confirm is accepted');
ok(!Comserv::Util::ZeroTier::pending_ok($pending, 'not-the-sha', 1000), 'mismatched confirm is rejected');
ok(!Comserv::Util::ZeroTier::pending_ok($pending, $sha, 1000 + 901), 'expired confirm is rejected');

my $record = Comserv::Util::ZeroTier::undo_record($ok->{routes}, $dns->{dns}, 'Shanta');
ok(!exists $record->{token} && !exists $record->{api_token}, 'undo record has no token field');
is($record->{saved_by}, 'Shanta', 'undo record names who changed it');

my $calls = 0;
my $client = Comserv::Util::ZeroTier->new({
    token => $secret,
    network_id => 'af78bf943680bfeb',
    transport => sub { $calls++; die "live call\n" },
});
Comserv::Util::ZeroTier::flag_orphan_routes($routes, $members);
is($calls, 0, 'orphan check does not call ZeroTier');

my $fail = Comserv::Util::ZeroTier->new({
    token => $secret,
    network_id => 'af78bf943680bfeb',
    transport => sub {
        my ($method, $url, $body_json) = @_;
        die "token in url" if $url =~ /\Q$secret\E/;
        return { status => 401, body => qq({"error":"bad $secret"}) };
    },
});
my $read = $fail->fetch_network;
ok(!$read->{ok}, 'injected failure is not a success');
unlike($read->{error}, qr/\Q$secret\E/, 'API error text does not contain the token');
like($read->{error}, qr/HTTP 401/, 'API error keeps the status');

my $seen;
my $write = Comserv::Util::ZeroTier->new({
    token => $secret,
    network_id => 'af78bf943680bfeb',
    transport => sub {
        my ($method, $url, $body_json) = @_;
        $seen = { method => $method, url => $url, body => $body_json };
        return { status => 200, body => '{"id":"af78bf943680bfeb","config":{}}' };
    },
});
my $posted = $write->update_settings($ok->{routes}, $dns->{dns});
ok($posted->{ok}, 'injected update succeeds without a live call');
is($seen->{method}, 'POST', 'update is a POST');
unlike($seen->{url}, qr/\Q$secret\E/, 'token is not placed in the URL');
unlike($seen->{body}, qr/\Q$secret\E/, 'token is not placed in the body');

done_testing;
