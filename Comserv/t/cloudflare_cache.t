#!/usr/bin/env perl
# Offline tests for the Cloudflare cache-rules admin feature.
# All HTTP is mocked: no network, no real token, nothing is written to Cloudflare.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use File::Spec;
use HTTP::Response;
use JSON::MaybeXS qw(encode_json decode_json);

use_ok('Comserv::Util::CloudflareCache');
use_ok('Comserv::Controller::Admin::CloudflareCache');

my $isolated = tempdir(CLEANUP => 1);
$ENV{COMSERV_SECRETS_DIR} = $isolated;   # never read the real secrets in tests
$ENV{CATALYST_HOME}       = $isolated;
my $FAKE_TOKEN = 'FAKETOKEN_abcdefghijklmnopqrstuvwxyz0123456789';
my $ZID  = 'a' x 32;
my $ZID2 = 'b' x 32;

# ---------------------------------------------------------------- mock HTTP --
{
    package MockHTTP;
    sub new { my ($c, %r) = @_; bless { routes => \%r, log => [] }, $c }
    sub request {
        my ($s, $req) = @_;
        my $key = $req->method . ' ' . $req->uri->path_query;
        push @{ $s->{log} }, { method => $req->method, path => $req->uri->path_query, body => $req->content, auth => scalar $req->header('Authorization') };
        my $h = $s->{routes}{$key} // $s->{routes}{ $req->method . ' *' };
        die "MockHTTP: unexpected request $key\n" unless $h;
        return $h->($req);
    }
    sub writes { my $s = shift; return grep { $_->{method} ne 'GET' } @{ $s->{log} } }
}
sub cf_ok  { my ($result, $info) = @_; HTTP::Response->new(200, 'OK', ['Content-Type' => 'application/json'], encode_json({ success => JSON::MaybeXS::true, errors => [], result => $result, ($info ? (result_info => $info) : ()) })) }
sub cf_err { my ($code, $cfcode, $msg) = @_; HTTP::Response->new($code, 'ERR', ['Content-Type' => 'application/json'], encode_json({ success => JSON::MaybeXS::false, errors => [ { code => $cfcode, message => $msg } ], result => undef })) }

my $tmp = tempdir(CLEANUP => 1);
sub mk { my ($http, %o) = @_; return Comserv::Util::CloudflareCache->new(token => $FAKE_TOKEN, http => $http, export_dir => ($o{dir} // "$tmp/exp" . int(rand 1e9)), %o) }

my $TAG = Comserv::Util::CloudflareCache::TAG();
my $PHASE = 'http_request_cache_settings';
my $EP = "/client/v4/zones/$ZID/rulesets/phases/$PHASE/entrypoint";

# ------------------------------------------------------------- rule content --
{
    my $cf = mk(MockHTTP->new);
    my @only1 = $cf->build_rules;
    is(scalar(@only1), 1, 'default: only rule 1 (ENCY rule and phase 2 are OFF by default)');
    like($only1[0]{description}, qr/^\Q$TAG\E Never cache private paths/, 'rule 1 tagged + named');
    my @r = $cf->build_rules(ency => 1);
    is(scalar(@r), 2, 'ency=>1: two rules');
    like($r[1]{description}, qr/^\Q$TAG\E Anonymous ENCY pages/, 'rule 2 tagged + named');
    is($r[0]{expression},
       '(starts_with(http.request.uri.path, "/user") or starts_with(http.request.uri.path, "/admin") or starts_with(http.request.uri.path, "/api") or starts_with(http.request.uri.path, "/todo") or starts_with(http.request.uri.path, "/cgi-bin") or http.cookie contains "comserv_session")',
       'rule 1 expression: private paths OR any comserv_session cookie');
    my $r2e = $r[1]{expression};
    like($r2e, qr{^\(http\.request\.method eq "GET" and starts_with\(http\.request\.uri\.path, "/ENCY/"\) and not http\.cookie contains "comserv_session" and }, 'rule 2 expression head: GET, /ENCY/, no session cookie');
    for my $w (qw(add edit delete create update)) {
        like($r2e, qr{not lower\(http\.request\.uri\.path\) contains "/$w"}, "rule 2 excludes paths containing /$w");
        like($r2e, qr{not lower\(http\.request\.uri\.query\) contains "$w"}, "rule 2 excludes query strings containing $w");
    }
    ok(length($r2e) < 4000, 'rule 2 expression within Cloudflare length limit');
    unlike($r2e, qr/ or /, 'rule 2 has no OR (every term narrows)');
    is($r[0]{action}, 'set_cache_settings', 'rule 1 action');
    ok(!$r[0]{action_parameters}{cache}, 'rule 1 cache=false (bypass)');
    ok($r[1]{action_parameters}{cache}, 'rule 2 cache=true');
    is_deeply($r[1]{action_parameters}{edge_ttl}, { mode => 'override_origin', default => 14400 }, 'rule 2 edge TTL 4h override_origin');
    is_deeply($r[1]{action_parameters}{browser_ttl}, { mode => 'bypass' }, 'rule 2 browser TTL bypass');
    is(encode_json($r[0]{action_parameters}), '{"cache":false}', 'cache false serialises as JSON false');

    my @p2 = $cf->build_rules(phase2 => 1, ency => 1);
    is(scalar(@p2), 3, 'phase 2 adds a third rule');
    like($p2[2]{expression}, qr{starts_with\(http\.request\.uri\.path, "/$_"\)}, "phase 2 includes /$_") for qw(marketplace membership faq newsletters jobs workshop page);
    like($p2[2]{expression}, qr/not http\.cookie contains "comserv_session"/, 'phase 2 requires no session cookie');
    like($p2[2]{expression}, qr/http\.request\.method eq "GET"/, 'phase 2 GET only');
    like($p2[2]{expression}, qr{not lower\(http\.request\.uri\.path\) contains "/edit"}, 'phase 2 also excludes action paths');
    for my $rule (@p2) {
        unlike($rule->{expression}, qr{/shop|/Cart|/HelpDesk}i, "excluded paths absent from: $rule->{description}");
        is(index($rule->{description}, $TAG), 0, 'every rule carries the tag');
    }
    my $pv = $cf->preview;
    is(scalar @{ $pv->{rules} }, 1, 'preview = what would be sent (rule 1 only by default)');
    is(scalar($cf->{http}->writes), 0, 'preview made no write');
    is(scalar @{ $cf->{http}{log} }, 0, 'preview made no HTTP call at all');
}

# -------------------------------------------------------------- list zones ---
{
    my $http = MockHTTP->new(
        'GET /client/v4/zones?per_page=50&page=1' => sub { cf_ok([ { id => $ZID2, name => 'zeta.example', status => 'active' } ], { total_pages => 2 }) },
        'GET /client/v4/zones?per_page=50&page=2' => sub { cf_ok([ { id => $ZID, name => 'alpha.example', status => 'pending' } ], { total_pages => 2 }) },
    );
    my $z = mk($http)->list_zones;
    ok($z->{ok}, 'list_zones ok');
    is_deeply([ map { $_->{name} } @{ $z->{zones} } ], [ 'alpha.example', 'zeta.example' ], 'both pages fetched, sorted');
    is($http->{log}[0]{auth}, "Bearer $FAKE_TOKEN", 'token sent only as Authorization header');
}

# --------------------------------------------- apply: export-before-write -----
my @existing = (
    { id => 'r-other-1', description => 'Customer rule 1', expression => 'true', action => 'set_cache_settings', action_parameters => { cache => JSON::MaybeXS::true() }, enabled => JSON::MaybeXS::true(), last_updated => '2026-01-01', version => '3', ref => 'zzz' },
    { id => 'r-old-ours', description => "$TAG Never cache private paths", expression => 'old', action => 'set_cache_settings', action_parameters => { cache => JSON::MaybeXS::false() }, enabled => JSON::MaybeXS::true() },
    { id => 'r-other-2', description => 'Customer rule 2', expression => 'false', action => 'set_cache_settings', action_parameters => { cache => JSON::MaybeXS::false() }, enabled => JSON::MaybeXS::false() },
);
{
    my $dir = "$tmp/apply";
    my ($export_existed_at_put, $put_body);
    my $http = MockHTTP->new(
        "GET $EP" => sub { cf_ok({ id => 'rs1', phase => $PHASE, rules => [ @existing ] }) },
        "PUT $EP" => sub {
            my $req = shift;
            opendir(my $dh, $dir); my @f = grep { /\.json$/ && $_ ne 'manifest.jsonl' } readdir $dh;
            $export_existed_at_put = scalar @f;
            $put_body = decode_json($req->content);
            cf_ok({ id => 'rs1' });
        },
    );
    my $cf = mk($http, dir => $dir);
    my $r = $cf->apply($ZID, 'alpha.example', ency => 1);
    ok($r->{ok}, 'apply ok') or diag explain $r;
    ok($export_existed_at_put, 'export file was already on disk when the PUT happened');
    ok(-f $r->{export_path}, 'export path recorded and exists');
    my $doc = decode_json(do { open my $fh, '<', $r->{export_path}; local $/; <$fh> });
    is(scalar @{ $doc->{ruleset}{rules} }, 3, 'export holds the full previous ruleset');
    is_deeply([ map { $_->{method} } @{ $http->{log} } ], [ 'GET', 'PUT' ], 'only GET then PUT');
    my @sent = @{ $put_body->{rules} };
    is_deeply([ map { $_->{id} // '(new)' } @sent ], [ 'r-other-1', 'r-other-2', '(new)', '(new)' ], 'other rules kept in order, old ours replaced, new ours last');
    is_deeply([ map { index($_->{description}, $TAG) == 0 ? 1 : 0 } @sent ], [ 0, 0, 1, 1 ], 'only ours are tagged');
    like($sent[2]{description}, qr/Never cache private/, 'rule 1 before rule 2');
    like($sent[3]{description}, qr/Anonymous ENCY/, 'rule 2 after rule 1');
    ok(!exists $sent[0]{last_updated} && !exists $sent[0]{version}, 'read-only metadata stripped from kept rules');
    is($sent[0]{expression}, 'true', 'other rule content untouched');
    is($r->{kept_other_rules}, 2, 'reports kept other rules');
    is(scalar(@{ [ $http->writes ] }), 1, 'exactly one write');
}

# apply WITHOUT ency (zone does not serve /ENCY/): only rule 1 is sent, and an old ENCY rule is removed
{
    my $put;
    my $old_ency = { id => 'r-old-ency', description => "$TAG Anonymous ENCY pages", expression => 'old', action => 'set_cache_settings' };
    my $http = MockHTTP->new(
        "GET $EP" => sub { cf_ok({ rules => [ $existing[0], $old_ency ] }) },
        "PUT $EP" => sub { $put = decode_json(shift->content); cf_ok({}) },
    );
    my $r = mk($http)->apply($ZID, 'alpha.example');
    ok($r->{ok}, 'apply (rule 1 only) ok');
    is_deeply([ map { $_->{id} // '(new)' } @{ $put->{rules} } ], [ 'r-other-1', '(new)' ], 'rule 1 only added; other rule kept; stale ENCY rule dropped');
    like($put->{rules}[1]{description}, qr/Never cache private/, 'the new rule is rule 1');
}

# apply aborts when the export cannot be written -> no write at all
{
    my $blocker = "$tmp/not_a_dir"; open my $fh, '>', $blocker; close $fh;
    my $http = MockHTTP->new("GET $EP" => sub { cf_ok({ rules => [ @existing ] }) }, "PUT $EP" => sub { die "must not write" });
    my $r = mk($http, dir => "$blocker/sub")->apply($ZID, 'alpha.example');
    ok(!$r->{ok}, 'apply fails when export fails');
    is($r->{step}, 'export', 'failed at export step');
    is(scalar($http->writes), 0, 'no write happened');
}

# apply on a zone with no ruleset yet (404) still exports (null) and writes ours
{
    my $put;
    my $http = MockHTTP->new(
        "GET $EP" => sub { cf_err(404, 10003, 'could not find entrypoint ruleset') },
        "PUT $EP" => sub { $put = decode_json(shift->content); cf_ok({}) },
    );
    my $r = mk($http)->apply($ZID, 'alpha.example', phase2 => 1, ency => 1);
    ok($r->{ok}, 'apply works when zone has no cache ruleset yet');
    is(scalar @{ $put->{rules} }, 3, 'phase 2 rule included when asked');
    ok(-f $r->{export_path}, 'export still written (ruleset: null)');
}

# ------------------------------------------------------------------- undo ----
{
    my $dir = "$tmp/undo";
    my $put; my $export_before;
    my @with_ours = (@existing, { id => 'r-ours-2', description => "$TAG Anonymous ENCY pages", expression => 'x', action => 'set_cache_settings', enabled => JSON::MaybeXS::true() });
    my $http = MockHTTP->new(
        "GET $EP" => sub { cf_ok({ rules => [ @with_ours ] }) },
        "PUT $EP" => sub { opendir(my $dh, $dir); $export_before = scalar grep { /\.json$/ } readdir $dh; $put = decode_json(shift->content); cf_ok({}) },
    );
    my $r = mk($http, dir => $dir)->undo($ZID, 'alpha.example');
    ok($r->{ok}, 'undo ok');
    ok($export_before, 'fresh export saved before undo write');
    is_deeply([ map { $_->{id} } @{ $put->{rules} } ], [ 'r-other-1', 'r-other-2' ], 'undo removes only tagged rules');
    is($r->{removed}, 2, 'two tagged rules removed');

    my $http2 = MockHTTP->new("GET $EP" => sub { cf_ok({ rules => [ $existing[0] ] }) }, "PUT $EP" => sub { die 'must not write' });
    my $r2 = mk($http2)->undo($ZID, 'alpha.example');
    ok($r2->{ok} && $r2->{nothing_to_do}, 'undo with nothing tagged is a no-op');
    is(scalar($http2->writes), 0, 'no write when nothing to undo');
}

# ---------------------------------------------------------------- restore ----
{
    my $dir = "$tmp/restore";
    my $put;
    my $http = MockHTTP->new(
        "GET $EP" => sub { cf_ok({ rules => [ @existing ] }) },
        "PUT $EP" => sub { $put = decode_json(shift->content); cf_ok({}) },
    );
    my $cf = mk($http, dir => $dir);
    my $a = $cf->apply($ZID, 'alpha.example', ency => 1);
    my ($file) = @{ $cf->list_exports($ZID) };
    ok($file, 'export is listed for the zone');
    my $bad = $cf->restore($ZID, 'alpha.example', '../../etc/passwd');
    ok(!$bad->{ok}, 'restore rejects arbitrary file names');
    my $wr = scalar($http->writes);
    sleep 1; # new timestamped export name
    my $r = $cf->restore($ZID, 'alpha.example', $file);
    ok($r->{ok}, 'restore ok') or diag explain $r;
    is_deeply([ map { $_->{id} } @{ $put->{rules} } ], [ 'r-other-1', 'r-old-ours', 'r-other-2' ], 'restore puts the exported rules back');
    is(scalar($http->writes), $wr + 1, 'one write for restore');
}

# ------------------------------------------------------------- zone state ----
{
    my $mk = sub { my @rules = @_; mk(MockHTTP->new("GET $EP" => sub { cf_ok({ rules => [@rules] }) })) };
    is($mk->($existing[0])->zone_state($ZID)->{state}, 'none', 'state none');
    my $cf = mk(MockHTTP->new);
    my @ours = map { +{ id => "o$_", description => $_->{description}, expression => $_->{expression}, action => 'set_cache_settings' } } $cf->build_rules(ency => 1);
    is($mk->(@ours, $existing[0])->zone_state($ZID)->{state}, 'applied', 'state applied');
    is($mk->(@ours, $existing[0])->zone_state($ZID)->{ency}, 1, 'ENCY rule detected');
    is($mk->($ours[0])->zone_state($ZID)->{ency}, 0, 'rule 1 only: ency flag off');
    is($mk->($ours[0])->zone_state($ZID)->{state}, 'applied', 'rule 1 alone counts as applied');
    is($mk->($ours[1])->zone_state($ZID)->{state}, 'partial', 'ENCY rule without rule 1 is partial');
    my $with2 = $mk->(@ours, { id => 'p2', description => "$TAG Anonymous public pages (phase 2)", expression => 'x', action => 'set_cache_settings' })->zone_state($ZID);
    is($with2->{phase2}, 1, 'phase 2 detected');
}

# ------------------------------------------------- permission errors + secrets
{
    my $http = MockHTTP->new(
        "GET $EP" => sub { cf_ok({ rules => [] }) },
        "PUT $EP" => sub { cf_err(403, 10000, "Authentication error for $FAKE_TOKEN") },
        'GET /client/v4/zones?per_page=50&page=1' => sub { cf_err(403, 9109, 'Unauthorized to access requested resource') },
    );
    my $cf = mk($http);
    my $r = $cf->apply($ZID, 'alpha.example');
    ok(!$r->{ok}, 'write 403 reported as failure');
    like($r->{error}, qr/Cache Rules > Edit/, 'tells which permission is missing for apply');
    unlike(encode_json($r), qr/\Q$FAKE_TOKEN\E/, 'token never appears in apply result');
    my $z = $cf->list_zones;
    like($z->{error}, qr/Zone > Zone > Read/, 'tells Zone Read is missing for the zone list');

    my $boom = MockHTTP->new('GET *' => sub { die "connect failed using Bearer $FAKE_TOKEN\n" });
    my $v = mk($boom)->verify_token;
    ok(!$v->{ok}, 'transport failure reported');
    unlike(encode_json($v), qr/\Q$FAKE_TOKEN\E/, 'token scrubbed from transport errors');

    my $inactive = MockHTTP->new('GET /client/v4/user/tokens/verify' => sub { cf_ok({ status => 'expired' }) });
    my $iv = mk($inactive)->verify_token;
    ok(!$iv->{ok}, 'non-active token rejected');
    like($iv->{error}, qr/expired/, 'status shown');

    my $badfmt = MockHTTP->new('GET /client/v4/user/tokens/verify' => sub { HTTP::Response->new(400, 'Bad', [], encode_json({ success => JSON::MaybeXS::false, errors => [ { code => 6003, message => 'Invalid request headers' } ], result => undef })) });
    like(mk($badfmt)->verify_token->{error}, qr/Invalid request headers/, 'invalid token format shown plainly');
}

# ---------------------------------------------------------------- test URL ---
{
    my @fetches;
    my @script = (
        { status => 200, 'CF-Cache-Status' => 'MISS', 'Cache-Control' => 'public, max-age=3600' },
        { status => 200, 'CF-Cache-Status' => 'HIT', Age => '5', 'Cache-Control' => 'public, max-age=3600' },
    );
    my $fetch = MockHTTP->new('GET *' => sub { my $s = shift @script; my $code = delete $s->{status}; push @fetches, 1; HTTP::Response->new($code, 'OK', [ %$s ], 'body') });
    my $cf = Comserv::Util::CloudflareCache->new(token => $FAKE_TOKEN, http => MockHTTP->new, fetch_http => $fetch, export_dir => $tmp,
        resolver => sub { ('104.16.1.1') }, sleep => sub {});
    my @zones = ('example.com');
    my $r = $cf->test_url('https://www.example.com/ENCY/herb', \@zones);
    ok($r->{ok}, 'test ok');
    is(scalar @fetches, 2, 'fetched exactly twice');
    is_deeply([ map { $_->{cf_cache} } @{ $r->{runs} } ], [ 'MISS', 'HIT' ], 'reports MISS then HIT');
    is($r->{runs}[1]{age}, '5', 'age reported');
    ok($r->{miss_then_hit}, 'flags expected MISS->HIT');
    is(scalar @{ $r->{warnings} }, 0, 'no warning without Set-Cookie');
    ok(!defined $fetch->{log}[0]{auth}, 'no Authorization header on the anonymous fetch');

    # Set-Cookie on a cacheable/HIT response -> WARNING
    my @s2 = (
        { status => 200, 'CF-Cache-Status' => 'MISS', 'Set-Cookie' => 'comserv_session_5000=SECRETVALUE; path=/' },
        { status => 200, 'CF-Cache-Status' => 'HIT', 'Set-Cookie' => 'comserv_session_5000=SECRETVALUE; path=/' },
    );
    my $f2 = MockHTTP->new('GET *' => sub { my $s = shift @s2; my $code = delete $s->{status}; HTTP::Response->new($code, 'OK', [ %$s ], 'b') });
    my $cf2 = Comserv::Util::CloudflareCache->new(token => $FAKE_TOKEN, http => MockHTTP->new, fetch_http => $f2, export_dir => $tmp, resolver => sub { ('104.16.1.1') }, sleep => sub {});
    my $r2 = $cf2->test_url('https://example.com/ENCY/x', \@zones);
    ok(scalar @{ $r2->{warnings} }, 'WARNING when a HIT carries Set-Cookie');
    like($r2->{warnings}[0], qr/Request 2/, 'warning names the offending request');
    ok($r2->{runs}[1]{set_cookie}, 'Set-Cookie flagged');
    unlike(encode_json($r2), qr/SECRETVALUE/, 'cookie value never reported (names only)');

    # SSRF guards
    my @bad = (
        [ 'file:///etc/passwd', 'file scheme' ],
        [ 'ftp://example.com/', 'ftp scheme' ],
        [ 'https://evil.test/ENCY/', 'host outside zones' ],
        [ 'https://notexample.com/', 'suffix trick' ],
        [ 'https://example.com.evil.test/', 'zone as prefix of other host' ],
        [ 'https://example.com:8443/', 'non-default port' ],
        [ 'https://user:pw@example.com/', 'credentials in URL' ],
        [ 'http://127.0.0.1/', 'loopback IP' ],
        [ '', 'empty' ],
    );
    for my $b (@bad) {
        my $t = $cf->test_url($b->[0], \@zones);
        ok(!$t->{ok}, "rejected: $b->[1]");
    }
    my $priv = Comserv::Util::CloudflareCache->new(token => $FAKE_TOKEN, http => MockHTTP->new, fetch_http => MockHTTP->new, export_dir => $tmp, resolver => sub { ('192.168.1.5') });
    my $pr = $priv->test_url('https://example.com/', \@zones);
    ok(!$pr->{ok} && $pr->{error} =~ /private/, 'zone host resolving to a private address is refused');
    my $nores = Comserv::Util::CloudflareCache->new(token => $FAKE_TOKEN, http => MockHTTP->new, fetch_http => MockHTTP->new, export_dir => $tmp, resolver => sub { () });
    ok(!$nores->test_url('https://example.com/', \@zones)->{ok}, 'unresolvable host refused');
}

# -------------------------------------------------------------- controller ---
{
    package FakeLog; sub new { bless {}, shift } sub log_with_details {}
    package FakeRes; sub new { bless { status => 200, redirect => undef }, shift }
    sub status { my $s = shift; $s->{status} = shift if @_; $s->{status} } sub redirect { my $s = shift; $s->{redirect} = shift if @_; $s->{redirect} }
    package FakeReq; sub new { my ($c, %a) = @_; bless { method => 'GET', params => {}, %a }, $c }
    sub method { $_[0]{method} } sub params { $_[0]{params} } sub parameters { $_[0]{params} }
    package FakeC;
    sub new { my ($c, %a) = @_; bless { session => {}, stash => {}, flash => {}, res => FakeRes->new, req => FakeReq->new, forwarded => 0, admin => 0, config => { home => '.' }, %a }, $c }
    sub session { $_[0]{session} } sub stash { my $s = shift; if (@_) { %{ $s->{stash} } = (%{ $s->{stash} }, @_ == 1 ? %{ $_[0] } : @_) } $s->{stash} }
    sub flash { $_[0]{flash} } sub response { $_[0]{res} } sub res { $_[0]{res} } sub req { $_[0]{req} } sub request { $_[0]{req} }
    sub uri_for { "http://x$_[1]" } sub config { $_[0]{config} }
    sub forward { $_[0]{forwarded}++; 1 }
    sub user_exists { $_[0]{admin} || $_[0]{plain_user} ? 1 : 0 }
    sub check_user_roles { $_[0]{admin} ? 1 : 0 }

    package FakeClient;
    sub new { bless { calls => [] }, shift }
    sub verify_token { push @{ $_[0]{calls} }, 'verify'; { ok => 1, token_status => 'active' } }
    sub list_zones { push @{ $_[0]{calls} }, 'zones'; { ok => 1, zones => [ { id => $ZID, name => 'alpha.example', status => 'active' }, { id => $ZID2, name => 'zeta.example', status => 'active' } ] } }
    sub apply { my ($s, $id, $name, %o) = @_; push @{ $s->{calls} }, "apply:$name:ency=" . ($o{ency} // 0); { ok => 1, export_path => '/x/e.json', our_rules => 2, kept_other_rules => 0 } }
    sub undo { push @{ $_[0]{calls} }, "undo:$_[2]"; { ok => 1, export_path => '/x/e.json', removed => 2, kept_other_rules => 0 } }
    sub build_rules { () }
}

{
    my $client = FakeClient->new;
    my $ctl = Comserv::Controller::Admin::CloudflareCache->new('Comserv', {});
    $ctl->{logging} = FakeLog->new;
    $ctl->client_factory(sub { ($client, undef) });

    # non-admin
    my $anon = FakeC->new(plain_user => 1);
    $ctl->index($anon);
    like($anon->{res}{redirect} // '', qr{/user/login}, 'non-admin page request redirected to login');
    ok(!exists $anon->{stash}{cf_zones}, 'non-admin gets no zone data');
    is(scalar @{ $client->{calls} }, 0, 'non-admin triggered no Cloudflare call');
    my $anonj = FakeC->new; $ctl->status($anonj, $ZID);
    is($anonj->{res}{status}, 403, 'non-admin JSON endpoint gets 403');
    my $anon_post = FakeC->new(plain_user => 1, req => FakeReq->new(method => 'POST', params => { zone_id => $ZID, csrf => 'x' }));
    $ctl->apply($anon_post);
    is(scalar(grep { /^apply/ } @{ $client->{calls} }), 0, 'non-admin POST apply does nothing');

    # admin index
    my $adm = FakeC->new(admin => 1);
    $ctl->index($adm);
    is($adm->{stash}{template}, 'admin/cloudflare_cache.tt', 'admin index renders template');
    is(scalar @{ $adm->{stash}{cf_zones} }, 2, 'zones listed live');
    ok(length $adm->{stash}{cf_csrf}, 'csrf token issued');
    require Data::Dumper; my $dump = Data::Dumper::Dumper($adm->{stash});
    unlike($dump, qr/\Q$FAKE_TOKEN\E/, 'token not in stash');

    # CSRF
    my $tok = $adm->{session}{cfcache_csrf};
    my $nocsrf = FakeC->new(admin => 1, session => { cfcache_csrf => $tok }, req => FakeReq->new(method => 'POST', params => { zone_id => $ZID }));
    $ctl->apply($nocsrf);
    like($nocsrf->{flash}{error_msg} // '', qr/security token/, 'POST without csrf rejected');
    my $get = FakeC->new(admin => 1, session => { cfcache_csrf => $tok }, req => FakeReq->new(method => 'GET', params => { zone_id => $ZID, csrf => $tok }));
    $ctl->apply($get);
    like($get->{flash}{error_msg} // '', qr/security token/, 'GET apply rejected even with token');
    is(scalar(grep { /^apply/ } @{ $client->{calls} }), 0, 'no apply without valid csrf');

    # valid apply
    my $ok = FakeC->new(admin => 1, session => { cfcache_csrf => $tok }, req => FakeReq->new(method => 'POST', params => { zone_id => $ZID, csrf => $tok, phase2 => '' }));
    $ctl->apply($ok);
    like($ok->{flash}{success_msg} // '', qr/alpha\.example: apply OK.*export saved/, 'valid POST applies and reports export path');
    is(scalar(grep { /^apply:alpha\.example/ } @{ $client->{calls} }), 1, 'apply called for the chosen zone');

    # unknown zone id cannot be touched
    my $unk = FakeC->new(admin => 1, session => { cfcache_csrf => $tok }, req => FakeReq->new(method => 'POST', params => { zone_id => 'c' x 32, csrf => $tok }));
    $ctl->undo($unk);
    like($unk->{flash}{error_msg} // '', qr/Unknown zone/, 'zone not in live list is refused');

    # apply all
    my $all = FakeC->new(admin => 1, session => { cfcache_csrf => $tok }, req => FakeReq->new(method => 'POST', params => { csrf => $tok }));
    $ctl->apply_all($all);
    is(scalar @{ $all->{flash}{cfcache_results} }, 2, 'apply_all reports every zone');
    is(scalar(grep { /^apply:/ } @{ $client->{calls} }), 3, 'apply_all applied to both zones (plus the earlier single apply)');
    my @after = grep { /^apply:/ } @{ $client->{calls} };
    is_deeply([ @after[1, 2] ], [ 'apply:alpha.example:ency=0', 'apply:zeta.example:ency=0' ], 'apply_all with no zone ticked: rule 1 only everywhere');
    like($all->{flash}{cfcache_results}[0], qr/rule 1 only/, 'results say rule 1 only');

    my $tick = FakeC->new(admin => 1, session => { cfcache_csrf => $tok }, req => FakeReq->new(method => 'POST', params => { csrf => $tok, ency_zones => $ZID2 }));
    $ctl->apply_all($tick);
    my @after2 = grep { /^apply:/ } @{ $client->{calls} };
    is_deeply([ @after2[3, 4] ], [ 'apply:alpha.example:ency=0', 'apply:zeta.example:ency=1' ], 'apply_all: ENCY rule only for the ticked zone, rule 1 for all');
    like($tick->{flash}{cfcache_results}[1], qr/rule 1 \+ ENCY/, 'results say which zone got ENCY');
    my $tick2 = FakeC->new(admin => 1, session => { cfcache_csrf => $tok }, req => FakeReq->new(method => 'POST', params => { csrf => $tok, ency_zones => [ $ZID, $ZID2 ] }));
    $ctl->apply_all($tick2);
    my @after3 = grep { /^apply:/ } @{ $client->{calls} };
    is_deeply([ @after3[5, 6] ], [ 'apply:alpha.example:ency=1', 'apply:zeta.example:ency=1' ], 'multiple ticked zones all get ENCY');

    # single-zone apply honours its own tick
    my $one = FakeC->new(admin => 1, session => { cfcache_csrf => $tok }, req => FakeReq->new(method => 'POST', params => { zone_id => $ZID, csrf => $tok, ency => '1' }));
    $ctl->apply($one);
    is((grep { /^apply:/ } @{ $client->{calls} })[7], 'apply:alpha.example:ency=1', 'single apply passes the ENCY tick');

    # missing credentials -> clear message, no crash
    my $nocred = Comserv::Controller::Admin::CloudflareCache->new('Comserv', {});
    $nocred->{logging} = FakeLog->new;
    $nocred->client_factory(sub { (undef, 'No Cloudflare API token configured') });
    my $c3 = FakeC->new(admin => 1);
    $nocred->index($c3);
    ok(!$c3->{stash}{cf_token}{ok}, 'index copes with missing credentials');
    like($c3->{stash}{cf_token}{error}, qr/No Cloudflare API token/, 'shows plain reason');
}

# template compiles
SKIP: {
    eval { require Template; 1 } or skip 'Template Toolkit not installed', 1;
    my $tt = Template->new({ INCLUDE_PATH => "$FindBin::Bin/../root", ABSOLUTE => 0, STRICT => 0 });
    my $out = '';
    my $c = FakeC->new(admin => 1);
    my $ok = $tt->process('admin/cloudflare_cache.tt', { c => $c, cf_token => { ok => 0, error => 'No token' }, cf_zones => [ { id => $ZID, name => 'alpha.example', status => 'active' } ],
        cf_csrf => 'abc', cf_tag => $TAG, cf_excluded => ['/shop'], cf_phase2 => ['/faq'], cf_rules => [], cf_known => [], cf_ency_hint => { $ZID => 1 } }, \$out);
    ok($ok, 'template compiles and renders') or diag $tt->error;
    like($out, qr/Zone &rarr; Cache Rules &rarr; Edit/, 'template tells which permission to add');
    like($out, qr/name="ency_zones" value="$ZID"[^>]* checked/, 'template pre-ticks the zone the app knows serves ENCY');
    like($out, qr/comserv_session<\/code> cookie/, 'template documents the cookie bypass in rule 1');
    like($out, qr/this site serves \/ENCY\//, 'template has the per-zone ENCY tick-box');
    my $out2 = ''; $tt->process('admin/cloudflare_cache.tt', { c => $c, cf_token => { ok => 0, error => 'No token' }, cf_zones => [], cf_csrf => 'abc', cf_tag => $TAG, cf_excluded => [], cf_phase2 => [], cf_rules => [], cf_known => [ { name => 'known.example', zone_id => 'z' } ], cf_ency_hint => {} }, \$out2);
    like($out2, qr/known\.example/, 'config domains shown as fallback labels when the live list fails');
    unlike($out2, qr/cfc-form-all/, 'no zone actions from the fallback list');
}

done_testing();
