#!/usr/bin/env perl
# Cache-safety for anonymous public GETs (Comserv::Util::PublicCache).
# Part 1: pure decision tests. Part 2: a tiny real Catalyst app with the same
# Session plugins and the same finalize hooks as lib/Comserv.pm, so the actual
# Set-Cookie behaviour is exercised offline (no DB, no Comserv app boot).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use_ok('Comserv::Util::PublicCache');

{
    package FakeReq;
    sub new { my ($c, %a) = @_; bless { method => 'GET', path => '', cookies => {}, qp => {}, hdr => undef, %a }, $c }
    sub method { $_[0]{method} } sub path { $_[0]{path} } sub cookies { $_[0]{cookies} }
    sub header { $_[0]{hdr} } sub query_parameters { $_[0]{qp} }
    package FakeHeaders; sub new { bless { h => {} }, shift }
    sub header { my ($s, $k, $v) = @_; $s->{h}{$k} = $v if @_ > 2; $s->{h}{$k} } sub remove_header { delete $_[0]{h}{ $_[1] } }
    package FakeRes; sub new { bless { status => 200, cookies => { comserv_session_5000 => { value => 'x' }, other => { value => 'y' } }, headers => FakeHeaders->new }, shift }
    sub status { $_[0]{status} } sub cookies { $_[0]{cookies} } sub headers { $_[0]{headers} }
    package FakeC;
    sub new { my ($c, %a) = @_; bless { stash => {}, error => [], res => FakeRes->new, %a }, $c }
    sub req { $_[0]{req} } sub res { $_[0]{res} } sub stash { $_[0]{stash} } sub error { $_[0]{error} }
}
sub ctx { my %r = @_; my $st = delete $r{status}; my $c = FakeC->new(req => FakeReq->new(%r)); $c->{res}{status} = $st if $st; $c }

my %yes = map { $_ => 1 } qw(ENCY/BotanicalNameView ENCY/herb_detail/12 marketplace marketplace/item/3 membership faq newsletters jobs workshop workshop/signup page page/about);
ok(Comserv::Util::PublicCache::is_public_anonymous_get(ctx(path => $_)), "anonymous GET /$_ is public") for sort keys %yes;

for my $p (qw(shop shop/cart Cart HelpDesk HelpDesk/new user/login admin admin/cloudflare_cache api/todo/open_log todo cgi-bin/x ENCY ENCY/add_herb ENCY/Reference/add ENCY/edit/3 ENCY/Author/add)) {
    ok(!Comserv::Util::PublicCache::is_public_anonymous_get(ctx(path => $p)), "/$p is NOT handled (unchanged behaviour)");
}
ok(!Comserv::Util::PublicCache::is_public_anonymous_get(ctx(path => 'ENCY/x', method => 'POST')), 'POST unchanged');
ok(Comserv::Util::PublicCache::is_public_anonymous_get(ctx(path => 'ENCY/x', method => 'HEAD')), 'HEAD handled');
ok(!Comserv::Util::PublicCache::is_public_anonymous_get(ctx(path => 'ENCY/x', cookies => { comserv_session_5000 => 1 })), 'request with session cookie (logged in or returning) unchanged');
ok(!Comserv::Util::PublicCache::is_public_anonymous_get(ctx(path => 'ENCY/x', cookies => { comserv_session => 1 })), 'plain comserv_session cookie unchanged');
ok(!Comserv::Util::PublicCache::is_public_anonymous_get(ctx(path => 'ENCY/x', hdr => 'a=b; comserv_session_3001=abc')), 'Cookie header with session unchanged');
ok(Comserv::Util::PublicCache::is_public_anonymous_get(ctx(path => 'ENCY/x', cookies => { theme => 'dark' })), 'unrelated cookie does not block');
ok(!Comserv::Util::PublicCache::is_public_anonymous_get(ctx(path => 'ENCY/x', qp => { _dvpt => 'tok' })), 'dev-preview request unchanged');
ok(!Comserv::Util::PublicCache::is_public_anonymous_get(ctx(path => 'ENCY/x', status => 302)), 'redirect unchanged');
ok(!Comserv::Util::PublicCache::is_public_anonymous_get(ctx(path => 'ENCY/x', status => 500)), 'error unchanged');
{ my $c = ctx(path => 'ENCY/x'); $c->{error} = ['boom']; ok(!Comserv::Util::PublicCache::is_public_anonymous_get($c), 'request with errors unchanged'); }
{ my $c = ctx(path => 'ENCY/x'); $c->{stash}{no_public_cache} = 1; ok(!Comserv::Util::PublicCache::is_public_anonymous_get($c), 'action can opt out'); }

{
    my $c = ctx(path => 'ENCY/x');
    ok(Comserv::Util::PublicCache::apply($c), 'apply acts on anonymous public GET');
    ok(!exists $c->res->cookies->{comserv_session_5000}, 'session cookie removed');
    ok(exists $c->res->cookies->{other}, 'only the session cookie is removed');
    is($c->res->headers->header('Cache-Control'), 'public, max-age=3600', 'Cache-Control public, max-age=3600');
    my $p = ctx(path => 'user/login');
    ok(!Comserv::Util::PublicCache::apply($p), 'apply does nothing on private path');
    ok(exists $p->res->cookies->{comserv_session_5000}, 'private path keeps its session cookie');
    ok(!defined $p->res->headers->header('Cache-Control'), 'private path gets no Cache-Control from us');
}

# ---- Part 2: real Catalyst behaviour with the same hooks ----
SKIP: {
    eval { require Catalyst; require Catalyst::Plugin::Session; require Catalyst::Plugin::Session::State::Cookie; require Catalyst::Plugin::Session::Store::Dummy; require Catalyst::Test; 1 }
        or skip 'Catalyst session plugins not available', 12;

    {
        package PCTest::Controller::Root;
        use base 'Catalyst::Controller';
        __PACKAGE__->config(namespace => '');
        # Like Root::auto/end in the real app: every request touches the session.
        sub auto :Private { my ($s, $c) = @_; $c->session->{touched} = 1; 1 }
        sub ency :Path('ENCY/herb') :Args(0) { $_[1]->res->body('ency page') }
        sub login :Path('user/login') :Args(0) { $_[1]->res->body('login page') }
        sub shop :Path('shop') :Args(0) { $_[1]->res->body('shop page') }
        sub who :Path('whoami') :Args(0) { my ($s, $c) = @_; $c->session->{user} = 'bob'; $c->res->body('set') }
        sub default :Path { $_[1]->res->body('default'); }
        sub end :Private { }

        package PCTest;
        use Catalyst qw(Session Session::State::Cookie Session::Store::Dummy);
        __PACKAGE__->config(name => 'PCTest', 'Plugin::Session' => { cookie_name => 'comserv_session_9999', expires => 3600 });
        __PACKAGE__->setup;
        # identical to the hooks in lib/Comserv.pm
        __PACKAGE__->meta->add_around_method_modifier('finalize_cookies', sub {
            my ($orig, $c, @args) = @_;
            eval { Comserv::Util::PublicCache::apply($c); 1 };
            return $c->$orig(@args);
        });
        __PACKAGE__->meta->add_around_method_modifier('finalize_session', sub {
            my ($orig, $c, @args) = @_;
            return if eval { Comserv::Util::PublicCache::is_public_anonymous_get($c) };
            return $c->$orig(@args);
        });
    }
    Catalyst::Test->import('PCTest');

    my $r = main::request('/ENCY/herb');
    is($r->code, 200, 'anonymous GET /ENCY/ page ok');
    is($r->header('Set-Cookie'), undef, 'anonymous GET /ENCY/: NO Set-Cookie');
    is($r->header('Cache-Control'), 'public, max-age=3600', 'anonymous GET /ENCY/: Cache-Control public, max-age=3600');

    my $l = main::request('/user/login');
    like($l->header('Set-Cookie') // '', qr/comserv_session_9999=/, 'private path /user/login still sets the session cookie (unchanged)');
    isnt(($l->header('Cache-Control') // ''), 'public, max-age=3600', 'private path gets no public Cache-Control');

    my $s = main::request('/shop');
    like($s->header('Set-Cookie') // '', qr/comserv_session_9999=/, '/shop (excluded) unchanged');

    # A visitor that already has a session cookie keeps normal behaviour on /ENCY/
    my $req = HTTP::Request->new(GET => '/ENCY/herb'); $req->header(Cookie => 'comserv_session_9999=0123456789abcdef0123456789abcdef01234567');
    my $with = main::request($req);
    isnt(($with->header('Cache-Control') // ''), 'public, max-age=3600', 'request carrying a session cookie is not marked public');
}

done_testing();
