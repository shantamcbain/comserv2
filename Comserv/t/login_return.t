#!/usr/bin/env perl
# Login-return: after login the user goes back to the calling page, but ONLY to a same-site local path.
#   * Controller::User->_safe_return_path accepts "/path?q" and same-host absolute URLs (reduced to a path)
#   * rejects open-redirect tricks: //evil.com, /\evil.com, http://evil.com, javascript:, %2f%2fevil.com,
#     CR/LF (raw or encoded), https:evil.com, userinfo@host, login/logout/register loops
#   * do_login (with the PBKDF2 + lockout changes) redirects only to a safe path; a bad return_to -> "/"
#   * register -> complete_profile no longer redirects to an attacker supplied return_to
# In-memory SQLite + fake $c. All passwords are FAKE; no network, no real DB.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use URI;

BEGIN {
    for my $m (qw(DBD::SQLite SQL::Translator Crypt::PBKDF2)) {
        eval "require $m; 1" or plan skip_all => "$m not installed";
    }
}

use Comserv::Util::Logging;
use Comserv::Util::PasswordHash;
use Comserv::Util::LoginThrottle;
use Comserv::Model::Schema::Ency::Result::User;
use Comserv::Model::Schema::Ency::Result::SystemLog;
use Comserv::Controller::User;

{
    no warnings 'redefine';
    *Comserv::Util::Logging::log_with_details = sub { 1 };
}

{ package T::Schema; use base 'DBIx::Class::Schema'; }
T::Schema->register_class(User      => 'Comserv::Model::Schema::Ency::Result::User');
T::Schema->register_class(SystemLog => 'Comserv::Model::Schema::Ency::Result::SystemLog');
my $schema = T::Schema->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1, sqlite_unicode => 1 });
{ local $SIG{__WARN__} = sub { warn @_ unless $_[0] =~ /Ignoring relationship/ }; $schema->deploy; }
my $PW = 'fake-Return-pass-1';
$schema->resultset('User')->create({ username => 'retuser', password => Comserv::Util::PasswordHash->hash($PW),
                                     email => 'ret@x.test', roles => 'normal', status => 'active' });

{
    package FakeReq;
    sub new { my ($c, %a) = @_; bless { address => '198.51.100.1', method => 'POST', params => {}, referer => '', host => 'workstation.local:3001', %a }, $c }
    sub address { $_[0]{address} } sub method { $_[0]{method} }
    sub body_parameters { $_[0]{params} } sub params { $_[0]{params} }
    sub param { my ($s, $k) = @_; $s->{params}{$k} }
    sub uri { URI->new("http://$_[0]{host}/user/do_login") }
    sub referer { $_[0]{referer} }
    package FakeRes;
    sub new { bless { status => 200, headers => {} }, shift }
    sub status { $_[0]{status} = $_[1] if @_ > 1; $_[0]{status} }
    sub redirect { $_[0]{redirect} = $_[1] if @_ > 1; $_[0]{redirect} }
    sub header { $_[0]{headers}{$_[1]} = $_[2] if @_ > 2; $_[0]{headers}{$_[1]} }
    package FakeCtx;
    sub new { my ($c, %a) = @_; bless { stash => {}, session => {}, flash => {}, res => FakeRes->new, %a }, $c }
    sub req { $_[0]{req} } sub res { $_[0]{res} } sub response { $_[0]{res} } sub request { $_[0]{req} }
    sub stash { my $s = shift; if (@_ == 1 && !ref $_[0]) { return $s->{stash}{$_[0]} } %{ $s->{stash} } = (%{ $s->{stash} }, @_ == 1 ? %{ $_[0] } : @_) if @_; $s->{stash} }
    sub session { $_[0]{session} } sub flash { $_[0]{flash} } sub sessionid { 'fake-sid' }
    sub change_session_id { 1 } sub uri_for { "http://workstation.local:3001$_[1]" }
    sub view { 'TT' } sub forward { $_[0]{rendered} = $_[1]; 1 }
    sub model {
        my ($s, $name) = @_;
        return $s->{schema}->resultset('User') if $name eq 'DBEncy::User';
        return $s->{model} if $name eq 'DBEncy';
        die "unexpected model $name";
    }
    package FakeModel;
    sub new { bless { schema => $_[1] }, $_[0] }
    sub resultset {
        my ($s, $n) = @_;
        return $s->{schema}->resultset($n) if grep { $n eq $_ } qw(User SystemLog);
        return FakeEmptyRS->new;
    }
    package FakeEmptyRS;
    sub new { bless {}, shift } sub search { $_[0] } sub single { undef } sub count { 0 } sub all { () } sub first { undef }
}

my $ctrl = do { local $SIG{__WARN__} = sub { warn @_ unless $_[0] =~ /uninitialized value \$app/ }; Comserv::Controller::User->new };
sub ctx {
    my (%a) = @_;
    return FakeCtx->new(schema => $schema, model => FakeModel->new($schema),
        req => FakeReq->new(%{ $a{req} || {} }), session => $a{session} || {});
}
sub safe { my ($u) = @_; $ctrl->_safe_return_path(ctx(), $u) }

# ---- 1. accepted values ---------------------------------------------------------
is(safe('/'),                    '/',                 'root accepted');
is(safe('/Documentation/x?a=1&b=2'), '/Documentation/x?a=1&b=2', 'local path + query accepted');
is(safe('/3d/store#frag'),       '/3d/store',         'fragment dropped');
is(safe('http://workstation.local:3001/Cart/checkout?x=1'), '/Cart/checkout?x=1', 'same-host absolute URL reduced to a path');
is(safe('http://workstation.local:3001'), '/',        'same-host URL with no path -> /');
is(safe('/user/profile'),        '/user/profile',     'other /user pages are fine');

# ---- 2. open-redirect attempts all rejected -------------------------------------
my @evil = (
    '//evil.com', '//evil.com/x', '///evil.com', '/\\evil.com', '\\\\evil.com', '\\evil.com',
    'http://evil.com', 'https://evil.com/', 'http://evil.com/workstation.local',
    'http://workstation.local.evil.com/x', 'http://workstation.local:' . '3001' . '@evil.com/', 'http://evil.com@workstation.local:3001/',
    'javascript:alert(1)', 'JaVaScRiPt:alert(1)', 'data:text/html,<script>alert(1)</script>', 'https:evil.com', 'http:evil.com', 'ftp://evil.com/',
    '%2f%2fevil.com', '%2F%2Fevil.com', '/%2fevil.com/x', '//%2fevil.com', '/%5cevil.com', '/%5Cevil.com',
    "/ok\r\nSet-Cookie: x=1", "/ok\nLocation: http://evil.com", "\n//evil.com", "//evil.com\r\n", "/ok\r\n",
    '/ok%0d%0aSet-Cookie:x=1', '/ok%0aX:y', '/ok%00', "/ok\0", "/\t/evil.com", "/ok\x7f",
    '/path"onmouseover="x', "/path'x", '/path<script>', '',
);
for my $e (@evil) {
    my $label = $e; $label =~ s/([^\x20-\x7e])/sprintf('\\x%02x', ord $1)/ge;
    is(safe($e), '', "rejected: [$label]");
}
is(safe(undef), '', 'undef rejected');

# ---- 3. login/logout/register loops are not return targets ----------------------
for my $loop (qw(/user/login /user/login?x=1 /user/do_login /user/logout /user/register /user/do_create_account
                 /user/verify_email /user/complete_profile /login /logout /do_login /User/Login /user/login/
                 /%75ser/login /user/%6cogin)) {
    is(safe($loop), '', "loop page rejected: $loop");
}
is(safe('http://workstation.local:3001/user/login'), '', 'same-host absolute login URL rejected');
is(safe('/user/loginhelp'), '/user/loginhelp', 'a different page that merely starts with "login" is not a loop');

# ---- 4. do_login redirects (PBKDF2 + lockout still in force) --------------------
sub do_login {
    my (%a) = @_;
    my $c = ctx(req => { params => { username => 'retuser', password => ($a{pass} // $PW), (defined $a{return_to} ? (return_to => $a{return_to}) : ()) } },
                session => $a{session});
    $c->{stash}{login_throttle} = Comserv::Util::LoginThrottle->new(store => Comserv::Util::LoginThrottle::MemoryStore->new);
    $ctrl->do_login($c);
    return $c;
}
my $c = do_login(return_to => '/Cart/checkout?x=1');
ok($c->session->{user_id}, 'login with PBKDF2 hash succeeds');
is($c->res->redirect, 'http://workstation.local:3001/Cart/checkout?x=1', 'login returns to the calling page');

for my $bad ('//evil.com', '/\\evil.com', 'http://evil.com', 'javascript:alert(1)', '%2f%2fevil.com', "/ok\r\nX: y", 'https:evil.com') {
    $c = do_login(return_to => $bad);
    my $loc = $c->res->redirect // '';
    unlike($loc, qr/evil/i, 'evil return_to not followed');
    is($loc, 'http://workstation.local:3001/', 'evil return_to falls back to home page');
}

$c = do_login(session => { referer => '/Documentation/x' });
is($c->res->redirect, 'http://workstation.local:3001/Documentation/x', 'session referer used when no return_to');
$c = do_login(session => { referer => '//evil.com' });
is($c->res->redirect, 'http://workstation.local:3001/', 'evil session referer ignored');
$c = do_login(return_to => '/user/login');
is($c->res->redirect, 'http://workstation.local:3001/', 'return_to pointing back at login -> home');
$c = do_login(pass => 'fake-wrong', return_to => '/Cart/checkout');
ok(!$c->session->{user_id}, 'wrong password still rejected');
unlike($c->res->redirect // '', qr/checkout/, 'failed login does not redirect to return_to');

# ---- 5. login page: stored return path is safe ----------------------------------
sub login_page {
    my (%a) = @_;
    my $c = ctx(req => { method => 'GET', params => $a{params} || {}, referer => $a{referer} // '' }, session => $a{session} || {});
    $ctrl->login($c);
    return $c;
}
$c = login_page(params => { return_to => '/Cart/checkout?x=1' });
is($c->stash->{return_to}, '/Cart/checkout?x=1', 'login page keeps a safe return_to');
$c = login_page(params => { return_to => '//evil.com' });
is($c->stash->{return_to}, '/', 'login page drops //evil.com');
$c = login_page(params => { destination => 'http://evil.com' }, referer => 'http://evil.com/x');
is($c->stash->{return_to}, '/', 'login page drops external destination/referer');
$c = login_page(referer => 'http://workstation.local:3001/3d/store?id=4');
is($c->stash->{return_to}, '/3d/store?id=4', 'same-host Referer becomes a local path');
$c = login_page(session => { login_return_path => '/Admin/stuff' });
is($c->stash->{return_to}, '/Admin/stuff', 'path remembered by a protected page is used');
ok(!exists $c->session->{login_return_path}, 'remembered path is one-shot');
$c = login_page(session => { referer => 'http://evil.com' });
is($c->stash->{return_to}, '/', 'poisoned session referer sanitised');

# ---- 6. register -> complete_profile redirect target is validated ---------------
$c = ctx(req => { method => 'GET', params => { return_to => 'http://evil.com/phish' } });
eval { $ctrl->register($c) };
ok(!$c->session->{return_to}, 'register does not store an external return_to');
$c = ctx(req => { method => 'GET', params => { return_to => '/workshop/add' } });
eval { $ctrl->register($c) };
is($c->session->{return_to}, '/workshop/add', 'register stores a local return_to');
{
    my $src = do { local (@ARGV, $/) = ("$FindBin::Bin/../lib/Comserv/Controller/User.pm"); <> };
    like($src, qr/_safe_return_path\(\$c, \$c->session->\{return_to\}\)/, 'complete_profile re-validates session return_to before redirecting');
    unlike($src, qr/return_to =~ m\{\^https\?:\/\/\}/, 'admin actions no longer redirect to an arbitrary http(s) return_to');
}

done_testing;
