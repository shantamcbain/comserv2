use strict;
use warnings;
use Test::More;
use lib 'lib';
use Comserv::Util::AI::ServerFallback;
use HTTP::Request;
use HTTP::Response;
use LWP::UserAgent;

# Test candidate_bases default ordering (PORT-major)
{
    my @b = Comserv::Util::AI::ServerFallback->candidate_bases();
    is(scalar(@b), 9, 'default has 9 bases');
    is($b[0], 'http://127.0.0.1:4006', 'first is 127.0.0.1:4006');
    is($b[1], 'http://workstation.local:4006', 'second is workstation.local:4006');
    is($b[2], 'http://172.30.131.126:4006', 'third is 172.30.131.126:4006');
    is($b[3], 'http://127.0.0.1:3001', '4th is 127.0.0.1:3001');
    is($b[8], 'http://172.30.131.126:5000', 'last is 172.30.131.126:5000');
}

# Test COMSERV_FALLBACK_BASES override
{
    local $ENV{COMSERV_FALLBACK_BASES} = ' http://x:1 , http://y:2/ , , http://x:1 ';
    my @b = Comserv::Util::AI::ServerFallback->candidate_bases();
    is_deeply(\@b, ['http://x:1', 'http://y:2'], 'env override trims, strips /, dedups, drops empty');
}

# Test bases= opt override
{
    my @b = Comserv::Util::AI::ServerFallback->candidate_bases( bases => ['http://a:9/', ' http://b:8 '] );
    is_deeply(\@b, ['http://a:9', 'http://b:8'], 'bases opt normalizes');
}

# should_try_next truth table
{
    ok( Comserv::Util::AI::ServerFallback->should_try_next(0), '0 -> try' );
    ok( Comserv::Util::AI::ServerFallback->should_try_next(404), '404 -> try' );
    ok( Comserv::Util::AI::ServerFallback->should_try_next(500, 1), '500 internal -> try' );
    ok( ! Comserv::Util::AI::ServerFallback->should_try_next(500, 0), '500 non-internal -> stop' );
    ok( Comserv::Util::AI::ServerFallback->should_try_next(502), '502 -> try' );
    ok( Comserv::Util::AI::ServerFallback->should_try_next(503), '503 -> try' );
    ok( Comserv::Util::AI::ServerFallback->should_try_next(504), '504 -> try' );
    ok( ! Comserv::Util::AI::ServerFallback->should_try_next(200), '200 -> stop' );
    ok( ! Comserv::Util::AI::ServerFallback->should_try_next(201), '201 -> stop' );
    ok( ! Comserv::Util::AI::ServerFallback->should_try_next(400), '400 -> stop' );
    ok( ! Comserv::Util::AI::ServerFallback->should_try_next(401), '401 -> stop' );
    ok( ! Comserv::Util::AI::ServerFallback->should_try_next(403), '403 -> stop' );
    ok( ! Comserv::Util::AI::ServerFallback->should_try_next(409), '409 -> stop' );
    ok( ! Comserv::Util::AI::ServerFallback->should_try_next(413), '413 -> stop' );
    ok( ! Comserv::Util::AI::ServerFallback->should_try_next(422), '422 -> stop' );
    ok( ! Comserv::Util::AI::ServerFallback->should_try_next(999), 'unlisted? stop per impl' );
}

# fake ua package for request tests
{
    package FakeUA;
    sub new { bless { responses => [] }, shift }
    sub push_response {
        my ($self, $code, $content, $internal) = @_;
        push @{$self->{responses}}, { code => $code, content => $content, internal => $internal };
    }
    sub request {
        my ($self, $req) = @_;
        my $next = shift @{$self->{responses}} || { code => 599, content => 'no more' };
        my $res = HTTP::Response->new($next->{code}, 'OK');
        $res->content($next->{content} // '');
        if ($next->{internal}) {
            $res->header('Client-Warning' => 'Internal response');
        }
        return $res;
    }
}

# request() fallback case: 500 internal, then 503, then 200
{
    my $ua = FakeUA->new();
    $ua->push_response(500, 'err1', 1);
    $ua->push_response(503, 'err2');
    $ua->push_response(200, '{"ok":1}');
    my $r = Comserv::Util::AI::ServerFallback->request(
        ua => $ua,
        method => 'POST',
        path => '/ai/eval/ingest',
        headers => { 'Content-Type' => 'application/json' },
        content => '{}',
    );
    ok($r->{ok}, 'ok=1 on third');
    is($r->{code}, 200, 'code 200');
    like($r->{base}, qr/:4006$/, 'base is first? no, the third one that succeeded');
    # actually since default first three 4006*, the third base is 172...:4006
    is(scalar(@{$r->{tried}}), 3, 'tried 3 entries');
    is($r->{tried}[0]{code}, 500, 'first tried 500');
    is($r->{tried}[1]{code}, 503, 'second 503');
    is($r->{tried}[2]{code}, 200, 'third 200');
}

# request stops on 401 (real answer)
{
    my $ua = FakeUA->new();
    $ua->push_response(401, 'forbidden');
    my $r = Comserv::Util::AI::ServerFallback->request(
        ua => $ua,
        method => 'GET',
        path => '/ai/usage_live',
    );
    ok(!$r->{ok}, 'ok=0 on 401');
    is($r->{code}, 401, 'code 401');
    is(scalar(@{$r->{tried}}), 1, 'tried only 1 entry, stopped');
    like($r->{base}, qr/127.0.0.1:4006/, 'base set to the failing one');
}

# source_record
{
    my $rec = Comserv::Util::AI::ServerFallback->source_record({
        base => 'http://h:1', url => 'http://h:1/p', code => 200, tried => []
    });
    ok(defined $rec->{at_utc}, 'has at_utc');
    like($rec->{at_utc}, qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/, 'ISO8601 UTC');
    is($rec->{base}, 'http://h:1');
}

done_testing();