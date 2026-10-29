#!/usr/bin/env perl
# GET /api/db/read, GET /api/secrets/compare, _api_identity, LAN-bypass flag, and
# CloudflareManager "log length only" -- all against an in-memory SQLite DBIC schema
# and a fake $c. Every secret in this file is a FAKE value; no network, no real DB.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::MaybeXS qw(encode_json decode_json);
use Digest::SHA qw(sha256_hex);
use HTTP::Response;

BEGIN {
    for my $m (qw(DBD::SQLite SQL::Translator DBIx::Class::ResultClass::HashRefInflator Log::Log4perl::Appender::TestBuffer)) {
        eval "require $m; 1" or plan skip_all => "$m not installed";
    }
}

# Capture log4perl output (CloudflareManager) before anything initialises it.
use Log::Log4perl;
Log::Log4perl->init(\ <<'L4P');
log4perl.rootLogger=DEBUG, BUF
log4perl.appender.BUF=Log::Log4perl::Appender::TestBuffer
log4perl.appender.BUF.layout=Log::Log4perl::Layout::SimpleLayout
L4P
sub l4p_buffer { Log::Log4perl::Appender::TestBuffer->by_name('BUF')->buffer }

# ---- fake secret values -------------------------------------------------------
my $F_PASSWORD = 'FAKE-PASSWORD-HASH-pw9Zq81';
my $F_ENC      = 'FAKE-MAILBOX-ENC-mb7Yt42';
my $F_SECRET   = 'FAKE-APPSECRET-VALUE-as3Kd05';
my $F_PREF     = 'FAKE-PREF-SECRET-pf6Hn27';
my $F_DBTOK    = 'ZQ9xDBTOKENfakeAAAAAAAAAAAAAAAAAAAAQW7r';   # length 40
my $F_FILETOK  = 'RT4mFILETOKENfakeBBBBBBBBBBBBBBBBBBBBLK2v';
my @ALL_FAKES = ($F_PASSWORD, $F_ENC, $F_SECRET, $F_PREF, $F_DBTOK, $F_FILETOK);

# ---- log capture for Comserv::Util::Logging -------------------------------------
use Comserv::Util::Logging;
my @LOG;
{
    no warnings 'redefine';
    *Comserv::Util::Logging::log_with_details = sub { my ($s, $c, $lvl, $f, $l, $sub, $msg) = @_; push @LOG, "[$lvl] $sub: " . ($msg // ''); 1 };
}

# ---- in-memory SQLite schema ----------------------------------------------------
{
    package T::Schema;           use base 'DBIx::Class::Schema';
    package T::Result::User;     use base 'DBIx::Class::Core';
    __PACKAGE__->table('users');
    __PACKAGE__->add_columns(id => { data_type => 'integer', is_auto_increment => 1 }, username => { data_type => 'text', is_nullable => 1 }, password => { data_type => 'text', is_nullable => 1 }, email => { data_type => 'text', is_nullable => 1 }, roles => { data_type => 'text', is_nullable => 1 }, status => { data_type => 'text', is_nullable => 1 });
    __PACKAGE__->set_primary_key('id');
    package T::Result::ApiToken; use base 'DBIx::Class::Core';
    __PACKAGE__->table('api_tokens');
    __PACKAGE__->add_columns(id => { data_type => 'integer', is_auto_increment => 1 }, user_id => { data_type => 'text', is_nullable => 1 }, token_hash => { data_type => 'text', is_nullable => 1 }, token_name => { data_type => 'text', is_nullable => 1 }, is_active => { data_type => 'text', is_nullable => 1 }, created_at => { data_type => 'text', is_nullable => 1 }, expires_at => { data_type => 'text', is_nullable => 1 }, last_used_at => { data_type => 'text', is_nullable => 1 }, revoked_at => { data_type => 'text', is_nullable => 1 });
    __PACKAGE__->set_primary_key('id');
    __PACKAGE__->belongs_to(user => 'T::Result::User', 'user_id');
    package T::Result::AppSecret; use base 'DBIx::Class::Core';
    __PACKAGE__->table('app_secrets');
    __PACKAGE__->add_columns(id => { data_type => 'integer', is_auto_increment => 1 }, secret_key => { data_type => 'text', is_nullable => 1 }, secret_value => { data_type => 'text', is_nullable => 1 });
    __PACKAGE__->set_primary_key('id');
    package T::Result::Todo;     use base 'DBIx::Class::Core';
    __PACKAGE__->table('todo');
    __PACKAGE__->add_columns(id => { data_type => 'integer', is_auto_increment => 1 }, subject => { data_type => 'text', is_nullable => 1 }, status => { data_type => 'text', is_nullable => 1 }, priority => { data_type => 'text', is_nullable => 1 }, api_token_note => { data_type => 'text', is_nullable => 1 });
    __PACKAGE__->set_primary_key('id');
    package T::Result::UserMailbox; use base 'DBIx::Class::Core';
    __PACKAGE__->table('user_mailboxes');
    __PACKAGE__->add_columns(id => { data_type => 'integer', is_auto_increment => 1 }, email_address => { data_type => 'text', is_nullable => 1 }, login_username => { data_type => 'text', is_nullable => 1 }, password_enc => { data_type => 'text', is_nullable => 1 }, imap_host => { data_type => 'text', is_nullable => 1 });
    __PACKAGE__->set_primary_key('id');
    package T::Result::SiteConfig; use base 'DBIx::Class::Core';
    __PACKAGE__->table('site_config');
    __PACKAGE__->add_columns(id => { data_type => 'integer', is_auto_increment => 1 }, config_key => { data_type => 'text', is_nullable => 1 }, config_value => { data_type => 'text', is_nullable => 1 });
    __PACKAGE__->set_primary_key('id');
    package T::Result::Session;  use base 'DBIx::Class::Core';
    __PACKAGE__->table('sessions');
    __PACKAGE__->add_columns(id => { data_type => 'integer', is_auto_increment => 1 }, session_data => { data_type => 'text', is_nullable => 1 });
    __PACKAGE__->set_primary_key('id');
    package T::Result::Widget;   use base 'DBIx::Class::Core';
    __PACKAGE__->table('user_credentials');      # name pattern must be blocked
    __PACKAGE__->add_columns(id => { data_type => 'integer', is_auto_increment => 1 }, thing => { data_type => 'text', is_nullable => 1 });
    __PACKAGE__->set_primary_key('id');
}
T::Schema->register_class(User => 'T::Result::User');
T::Schema->register_class(ApiToken => 'T::Result::ApiToken');
T::Schema->register_class(AppSecret => 'T::Result::AppSecret');
T::Schema->register_class(Todo => 'T::Result::Todo');
T::Schema->register_class(UserMailbox => 'T::Result::UserMailbox');
T::Schema->register_class(SiteConfig => 'T::Result::SiteConfig');
T::Schema->register_class(Session => 'T::Result::Session');
T::Schema->register_class(Widget => 'T::Result::Widget');

my $schema = T::Schema->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1, sqlite_unicode => 1 });
$schema->deploy;
my $S = sub { $schema->resultset(shift) };

$S->('User')->populate([
    [qw(id username password email roles status)],
    [1, 'botdev',   $F_PASSWORD, 'b@x.test', 'developer',        'active'],
    [2, 'plainu',   $F_PASSWORD, 'p@x.test', 'user',             'active'],
    [3, 'editbot',  $F_PASSWORD, 'e@x.test', 'editor',           'active'],
    [4, 'sleeping', $F_PASSWORD, 's@x.test', 'developer',        'inactive'],
    [5, 'adminu',   $F_PASSWORD, 'a@x.test', 'admin,developer',  'active'],
]);
my %TOK = (good => 'tok-good-fake-0001', revoked => 'tok-revoked-fake-02', expired => 'tok-expired-fake-03',
           inactive => 'tok-inactive-fake-04', norole => 'tok-norole-fake-05', editor => 'tok-editor-fake-06',
           sleeping => 'tok-sleeping-fake-07', admin => 'tok-admin-fake-08');
my $now = '2026-10-25 05:00:00';
$S->('ApiToken')->populate([
    [qw(id user_id token_hash token_name is_active created_at expires_at revoked_at)],
    [1, 1, sha256_hex($TOK{good}),     'botdev-main', 1, $now, undef,                  undef],
    [2, 1, sha256_hex($TOK{revoked}),  'old',         1, $now, undef,                  $now],
    [3, 1, sha256_hex($TOK{expired}),  'exp',         1, $now, '2020-01-01 00:00:00',  undef],
    [4, 1, sha256_hex($TOK{inactive}), 'off',         0, $now, undef,                  undef],
    [5, 2, sha256_hex($TOK{norole}),   'plain',       1, $now, undef,                  undef],
    [6, 3, sha256_hex($TOK{editor}),   'editor',      1, $now, undef,                  undef],
    [7, 4, sha256_hex($TOK{sleeping}), 'sleep',       1, $now, undef,                  undef],
    [8, 5, sha256_hex($TOK{admin}),    'admin',       1, $now, '2099-01-01 00:00:00',  undef],
]);
$S->('AppSecret')->create({ secret_key => 'cloudflare_api_token', secret_value => $F_SECRET });
$S->('Todo')->populate([
    [qw(id subject status priority api_token_note)],
    map { [$_, "Todo number $_", $_ % 3 ? 'open' : 'done', $_ % 5, "note $_"] } 1 .. 7,
]);
$S->('Todo')->populate([ [qw(id subject status priority api_token_note)], map { [$_, "Bulk $_", 'open', 1, 'n'] } 8 .. 620 ]);
$S->('UserMailbox')->create({ email_address => 'a@x.test', login_username => 'a', password_enc => $F_ENC, imap_host => 'imap.x.test' });
$S->('SiteConfig')->populate([
    [qw(id config_key config_value)],
    [1, 'site_title', 'My Site'],
    [2, 'smtp_password_x', $F_PREF],
]);
$S->('Session')->create({ session_data => $F_PASSWORD });
$S->('Widget')->create({ thing => 'w' });

# ---- fake Catalyst context ------------------------------------------------------
{
    package FakeReq;
    sub new { my ($c, %a) = @_; bless { address => '203.0.113.9', method => 'GET', path => 'api/db/read', headers => {}, q => {}, %a }, $c }
    sub address { $_[0]{address} } sub method { $_[0]{method} } sub path { $_[0]{path} }
    sub header { my ($s, $n) = @_; $s->{headers}{lc $n} }
    sub query_parameters { $_[0]{q} } sub params { $_[0]{q} }
    package FakeRes;
    sub new { bless { status => 200, headers => {} }, shift }
    sub status { $_[0]{status} = $_[1] if @_ > 1; $_[0]{status} }
    sub body { $_[0]{body} = $_[1] if @_ > 1; $_[0]{body} }
    sub content_type { 1 }
    sub header { $_[0]{headers}{$_[1]} = $_[2] if @_ > 2; $_[0]{headers}{$_[1]} }
    package FakeModel;
    sub new { bless { schema => $_[1] }, $_[0] }
    sub schema { $_[0]{schema} } sub resultset { $_[0]{schema}->resultset($_[1]) }
    package FakeC;
    sub new {
        my ($c, %a) = @_;
        my $self = bless { session => $a{session} || {}, stash => {}, schema => $a{schema} }, $c;
        $self->{req} = FakeReq->new(%{ $a{req} || {} });
        $self->{res} = FakeRes->new;
        $self->{no_session_id} = $a{no_session};
        return $self;
    }
    sub req { $_[0]{req} } sub res { $_[0]{res} } sub session { $_[0]{session} } sub stash { $_[0]{stash} }
    sub sessionid { %{ $_[0]{session} } ? 'sid' : undef }
    sub model { FakeModel->new($_[0]{schema}) }
    sub detach { die { detach => 1 } }
}

require Comserv::Controller::Api;
my $ctrl = bless { logging => Comserv::Util::Logging->instance }, 'Comserv::Controller::Api';

sub mk {
    my (%a) = @_;
    my $hdr = $a{token} ? { authorization => "Bearer $a{token}" } : {};
    return FakeC->new(schema => $schema, session => $a{session},
        req => { address => $a{address} || '203.0.113.9', method => $a{method} || 'GET',
                 headers => { %$hdr, %{ $a{headers} || {} } }, q => $a{q} || {}, path => $a{path} || 'api/db/read' });
}
sub call {
    my ($m, $c) = @_;
    eval { $ctrl->$m($c); 1 } or do { die $@ unless ref $@ eq 'HASH' && $@->{detach} };
    my $body = $c->res->body;
    return ($c->res->status, ($body ? decode_json($body) : {}), $body // '');
}
sub dbread { my (%a) = @_; my $c = mk(%a); return call('api_db_read', $c) }
sub good { my (%q) = @_; return (token => $TOK{good}, q => { %q }) }

# =============================================================================
# A. identity
# =============================================================================
{
    my $c = mk(token => $TOK{good});
    my $id = Comserv::Controller::Api::_api_identity($c);
    is($id->{username}, 'botdev', 'valid developer token -> identity');
    like($id->{via}, qr/^token:botdev-main$/, 'via names the token');
    is($id->{user_id}, 1, 'user_id');
    ok(scalar(grep { $_ eq 'developer' } @{ $id->{roles} }), 'roles returned');

    $id = Comserv::Controller::Api::_api_identity(mk(session => { username => 'sess', user_id => 9, roles => ['editor'] }));
    is($id->{via}, 'session', 'session editor ok');
    $id = Comserv::Controller::Api::_api_identity(mk(session => { username => 'sess', user_id => 9, roles => 'user' }));
    ok(!defined $id, 'session without allowed role -> undef');
    $c = mk(session => { username => 'sess', user_id => 9, roles => ['user'] });
    Comserv::Controller::Api::_api_identity($c);
    is($c->stash->{api_identity_error}{status}, 403, '... 403');

    $c = mk();
    ok(!defined Comserv::Controller::Api::_api_identity($c), 'no credentials -> undef');
    is($c->stash->{api_identity_error}{status}, 401, '... 401');

    for my $case ([revoked => 403], [expired => 403], [inactive => 403], [norole => 403], [sleeping => 403]) {
        $c = mk(token => $TOK{ $case->[0] });
        ok(!defined Comserv::Controller::Api::_api_identity($c), "$case->[0] token refused");
        is($c->stash->{api_identity_error}{status}, $case->[1], "... status $case->[1]");
    }
    $c = mk(token => 'not-a-real-token-at-all');
    Comserv::Controller::Api::_api_identity($c);
    is($c->stash->{api_identity_error}{status}, 401, 'unknown token -> 401');

    $c = mk(token => $TOK{editor});
    is(Comserv::Controller::Api::_api_identity($c)->{username}, 'editbot', 'editor token allowed by default');
    $c = mk(token => $TOK{editor});
    ok(!defined Comserv::Controller::Api::_api_identity($c, allowed_roles => [qw(admin developer devops)]), 'editor refused when role list excludes editor');

    # LAN-only caller is NOT accepted by the identity helper
    $c = mk(address => '127.0.0.1');
    ok(!defined Comserv::Controller::Api::_api_identity($c), '127.0.0.1 without credentials -> undef');
    $c = mk(address => '192.168.1.50', headers => { 'x-forwarded-for' => '127.0.0.1' });
    ok(!defined Comserv::Controller::Api::_api_identity($c), '192.168.1.x (+XFF) without credentials -> undef');
}

# =============================================================================
# B. endpoint: auth
# =============================================================================
{
    my ($st, $j) = dbread(q => { table => 'todo' });
    is($st, 401, 'unauthenticated -> 401');
    ($st) = dbread(address => '127.0.0.1', q => { table => 'todo' });
    is($st, 401, 'localhost only -> 401');
    ($st) = dbread(address => '192.168.1.20', q => { table => 'todo' });
    is($st, 401, 'LAN only -> 401');
    ($st) = dbread(address => '192.168.1.20', headers => { 'x-forwarded-for' => '127.0.0.1' }, q => { table => 'todo' });
    is($st, 401, 'LAN + forged XFF -> 401');
    for my $t (qw(revoked expired inactive norole sleeping)) {
        ($st) = dbread(token => $TOK{$t}, q => { table => 'todo' });
        is($st, 403, "$t token -> 403");
    }
    ($st, $j) = dbread(method => 'POST', token => $TOK{good}, q => { table => 'todo' });
    is($st, 405, 'POST refused');
    ($st, $j) = dbread(session => { username => 's', user_id => 3, roles => ['developer'] }, q => { table => 'todo', limit => 2 });
    is($st, 200, 'session developer ok');
    is($j->{count}, 2, '... rows');
}

# =============================================================================
# C. reading, filters, pagination
# =============================================================================
{
    my ($st, $j) = dbread(good(table => 'todo', limit => 3, order => 'id'));
    is($st, 200, 'allowed table 200');
    is($j->{count}, 3, '3 rows');
    is($j->{rows}[0]{subject}, 'Todo number 1', 'row data');
    is($j->{has_more}, JSON::MaybeXS::true, 'has_more true');
    ok(!exists $j->{total_count}, 'no total_count unless asked');

    ($st, $j) = dbread(good(table => 'todo', total => 1, limit => 2));
    is($j->{total_count}, 620, 'total_count when asked');

    ($st, $j) = dbread(good(table => 'todo', filter => 'status:done', order => 'id:desc', limit => 100));
    is($st, 200, 'eq filter');
    ok((grep { $_->{status} ne 'done' } @{ $j->{rows} }) == 0, '... only done rows');
    is($j->{rows}[0]{id}, 6, '... order desc');

    ($st, $j) = dbread(good(table => 'todo', filter => 'subject__like:Todo number %,status:open', columns => 'id,subject'));
    is($st, 200, 'like + eq filter with comma split');
    is(join(',', @{ $j->{columns} }), 'id,subject', 'columns honoured');
    ok(!exists $j->{rows}[0]{status}, 'unrequested column absent');

    ($st, $j) = dbread(good(table => 'todo', filter => 'id__in:1|2|3', order => 'id'));
    is(join(',', map { $_->{id} } @{ $j->{rows} }), '1,2,3', 'in operator');
    ($st, $j) = dbread(good(table => 'todo', filter => 'id__gt:5,id__lt:8', order => 'id'));
    is(join(',', map { $_->{id} } @{ $j->{rows} }), '6,7', 'gt/lt');
    ($st, $j) = dbread(good(table => 'todo', filter => 'id__ge:6', limit => 2, offset => 1, order => 'id'));
    is(join(',', map { $_->{id} } @{ $j->{rows} }), '7,8', 'offset pagination');

    ($st, $j) = dbread(good(table => 'todo'));
    is($j->{limit}, 100, 'default limit 100'); is($j->{count}, 100, '100 rows');
    ($st, $j) = dbread(good(table => 'todo', limit => 99999));
    is($st, 200, 'huge limit not an error'); is($j->{limit}, 500, 'limit clamped to 500'); is($j->{count}, 500, '500 rows');
    is($j->{has_more}, JSON::MaybeXS::true, 'has_more at clamp');

    ($st, $j) = dbread(good(table => 'todo', limit => -5));  is($st, 400, 'negative limit rejected');
    ($st, $j) = dbread(good(table => 'todo', limit => 0));   is($st, 400, 'zero limit rejected');
    ($st, $j) = dbread(good(table => 'todo', limit => '1 OR 1=1')); is($st, 400, 'limit injection rejected');
    ($st, $j) = dbread(good(table => 'todo', offset => -1)); is($st, 400, 'negative offset rejected');
    ($st, $j) = dbread(good(table => 'todo', offset => 'x;drop')); is($st, 400, 'offset injection rejected');

    ($st, $j) = dbread(good());
    is($st, 200, 'no table lists tables');
    my %t = map { $_ => 1 } @{ $j->{tables} };
    ok($t{todo} && $t{users} && $t{user_mailboxes}, 'readable tables listed');
    ok(!$t{app_secrets} && !$t{api_tokens} && !$t{sessions} && !$t{user_credentials}, 'blocked tables not listed');
}

# =============================================================================
# D. blocked / unknown tables
# =============================================================================
{
    for my $t (qw(app_secrets api_tokens sessions user_credentials)) {
        my ($st, $j, $raw) = dbread(good(table => $t));
        is($st, 403, "$t blocked");
        unlike($raw, qr/\Q$_\E/, "... no secret in body ($t)") for @ALL_FAKES;
    }
    my ($st) = dbread(good(table => 'no_such_table')); is($st, 404, 'unknown table 404');
    ($st) = dbread(good(table => 'users; drop table todo')); is($st, 400, 'table injection 400');
    ($st) = dbread(good(table => "todo' OR '1'='1")); is($st, 400, 'table quote injection 400');
    ($st) = dbread(good(table => 'todo--')); is($st, 400, 'table comment injection 400');
    ($st) = dbread(good(table => '../etc/passwd')); is($st, 400, 'table path 400');
    ($st) = dbread(good(table => 'APP_SECRETS')); ok($st == 404 || $st == 403, 'case variant not readable');
    ($st) = dbread(token => $TOK{good}, q => { table => ['todo', 'app_secrets'] }); is($st, 400, 'repeated table param rejected');
    is($S->('Todo')->count, 620, 'todo table intact after injection attempts');
    ok($S->('User')->count == 5, 'users table intact');
}

# =============================================================================
# E. injection through filter / order / columns
# =============================================================================
{
    my ($st, $j) = dbread(good(table => 'users', filter => "username:' OR 1=1"));
    is($st, 200, "value with ' OR 1=1 is just a value"); is($j->{count}, 0, '... matches nothing');
    ($st, $j) = dbread(good(table => 'users', filter => "username:x'; DROP TABLE users;--"));
    is($j->{count}, 0, 'DROP in value is harmless'); is($S->('User')->count, 5, '... users intact');
    ($st) = dbread(good(table => 'users', filter => 'user"name:x'));       is($st, 400, 'quote in filter column rejected');
    ($st) = dbread(good(table => 'users', filter => "username'--:x"));     is($st, 400, 'quote/comment in filter column rejected');
    ($st) = dbread(good(table => 'users', filter => 'nosuch:x'));          is($st, 400, 'unknown filter column rejected');
    ($st) = dbread(good(table => 'users', filter => 'username__bogus:x')); is($st, 400, 'unknown operator rejected');
    ($st) = dbread(good(table => 'users', filter => 'username'));          is($st, 400, 'malformed filter rejected');
    ($st) = dbread(good(table => 'users', filter => 'id__in:' . join('|', 1 .. 80))); is($st, 400, 'too many in values rejected');
    ($st) = dbread(good(table => 'users', filter => 'username:' . ('a' x 600))); is($st, 400, 'overlong value rejected');
    ($st) = dbread(good(table => 'users', filter => join(',', map { "id:$_" } 1 .. 20))); is($st, 400, 'too many filters rejected');
    ($st) = dbread(good(table => 'todo', order => 'id; DROP TABLE todo')); is($st, 400, 'order injection rejected');
    ($st) = dbread(good(table => 'todo', order => '(SELECT 1)'));          is($st, 400, 'order subselect rejected');
    ($st) = dbread(good(table => 'todo', order => 'nosuch'));              is($st, 400, 'order unknown column rejected');
    ($st) = dbread(good(table => 'todo', order => 'id:sideways'));         is($st, 400, 'order bad direction rejected');
    ($st) = dbread(good(table => 'todo', columns => 'id,(SELECT password FROM users)')); is($st, 400, 'columns subselect rejected');
    ($st) = dbread(good(table => 'todo', columns => 'nosuch'));            is($st, 400, 'unknown column rejected');
    is($S->('Todo')->count, 620, 'todo intact');
}

# =============================================================================
# F. masked columns
# =============================================================================
{
    my ($st, $j, $raw) = dbread(good(table => 'users', order => 'id'));
    is($st, 200, 'users readable');
    is($j->{rows}[0]{password}, '***masked***', 'users.password masked');
    is($j->{rows}[0]{username}, 'botdev', 'other columns shown');
    ok(scalar(grep { $_ eq 'password' } @{ $j->{masked_columns} }), 'masked_columns lists it');
    unlike($raw, qr/\Q$F_PASSWORD\E/, 'password value absent from body');

    ($st, $j, $raw) = dbread(good(table => 'users', columns => 'password'));
    is($st, 200, 'only masked column requested'); is($j->{rows}[0]{password}, '***masked***', '... masked');
    unlike($raw, qr/\Q$F_PASSWORD\E/, '... value absent');

    ($st) = dbread(good(table => 'users', filter => "password:$F_PASSWORD")); is($st, 403, 'filter on masked column refused');
    ($st) = dbread(good(table => 'users', filter => 'password__like:FAKE%')); is($st, 403, 'like on masked column refused');
    ($st) = dbread(good(table => 'users', order => 'password'));             is($st, 403, 'order by masked column refused');

    ($st, $j, $raw) = dbread(good(table => 'user_mailboxes'));
    is($st, 200, 'user_mailboxes readable'); is($j->{rows}[0]{password_enc}, '***masked***', 'password_enc masked');
    is($j->{rows}[0]{imap_host}, 'imap.x.test', 'imap_host shown'); unlike($raw, qr/\Q$F_ENC\E/, 'enc value absent');
    ($st) = dbread(good(table => 'user_mailboxes', filter => 'password_enc:x')); is($st, 403, 'filter on password_enc refused');

    ($st, $j, $raw) = dbread(good(table => 'todo', columns => 'id,api_token_note', limit => 1));
    is($j->{rows}[0]{api_token_note}, '***masked***', 'column named *token* masked in any table');

    ($st, $j, $raw) = dbread(good(table => 'site_config', order => 'id'));
    is($j->{rows}[0]{config_value}, 'My Site', 'key/value row with ordinary key shown');
    is($j->{rows}[1]{config_value}, '***masked***', 'key/value row with secret-looking key masked');
    unlike($raw, qr/\Q$F_PREF\E/, '... value absent');
    ($st) = dbread(good(table => 'site_config', filter => 'config_value:x')); is($st, 403, 'filter on key/value column refused');
    ($st, $j, $raw) = dbread(good(table => 'site_config', columns => 'config_value', order => 'id'));
    is($j->{rows}[1]{config_value}, '***masked***', 'masking holds when key column not requested');
    ok(!exists $j->{rows}[0]{config_key}, '... key column not leaked');

    require Comserv::Util::ApiDbRead;
    ok(Comserv::Util::ApiDbRead->is_masked_column('x', $_), "$_ masked") for qw(password user_password passwd db_pass hash token_hash api_key api_key_encrypted private_key cookie session_id secret client_secret password_enc foo_enc foo_salt auth_token);
    ok(!Comserv::Util::ApiDbRead->is_masked_column('x', $_), "$_ not masked") for qw(username email tokens_used max_tokens prompt_tokens passenger_count status description);
}

# =============================================================================
# G. logging: one line per call, names only
# =============================================================================
{
    @LOG = ();
    my ($st) = dbread(good(table => 'todo', filter => "subject:LOGVALUE-123,status:open", columns => 'id,subject', limit => 5));
    my @l = grep { /api_db_read user=/ && /rows=/ } @LOG;
    is(scalar(@l), 1, 'exactly one api_db_read log line');
    like($l[0], qr/user=botdev via=token:botdev-main table=todo columns_req=2 filter_cols=\[subject,status\] rows=0/, 'log line content');
    unlike(join("\n", @LOG), qr/LOGVALUE-123/, 'filter values not logged');
    unlike(join("\n", @LOG), qr/\Q$TOK{good}\E/, 'token not logged');
}

# =============================================================================
# H. secrets/compare
# =============================================================================
{
    my $home = tempdir(CLEANUP => 1);
    my $secd = tempdir(CLEANUP => 1);
    local $ENV{CATALYST_HOME}       = $home;
    local $ENV{COMSERV_SECRETS_DIR} = $secd;
    local $ENV{CLOUDFLARE_API_TOKEN}; delete $ENV{CLOUDFLARE_API_TOKEN};
    local $ENV{CF_API_TOKEN};         delete $ENV{CF_API_TOKEN};
    local $ENV{CLOUDFLARE_API_KEY};   delete $ENV{CLOUDFLARE_API_KEY};
    local $ENV{CF_API_KEY};           delete $ENV{CF_API_KEY};
    my $write_file = sub {
        open my $fh, '>', "$secd/cloudflare.json" or die $!; print $fh encode_json({ cloudflare => { api_token => $_[0] } }); close $fh;
    };
    my $cmp = sub { call('api_secrets_compare', mk(token => $TOK{good}, path => 'api/secrets/compare', q => { name => 'cloudflare' })) };
    my $secret_tok = sub { $S->('AppSecret')->search({ secret_key => 'cloudflare_api_token' }) };
    my $no_leaks = sub {
        my ($raw, $what) = @_;
        for my $f (@ALL_FAKES) {
            unlike($raw, qr/\Q$f\E/, "$what: value absent");
            unlike($raw, qr/\Q@{[ substr($f, 0, 6) ]}\E/, "$what: prefix absent") if $f =~ /^(ZQ9x|RT4m)/;
            unlike($raw, qr/\Q@{[ substr($f, -4) ]}\E/, "$what: suffix absent") if $f =~ /^(ZQ9x|RT4m)/;
        }
    };

    # 1. DB value differs from file value (DB row currently holds the secret fake)
    $secret_tok->()->update({ secret_value => $F_DBTOK });
    $write_file->($F_FILETOK);
    my ($st, $j, $raw) = $cmp->();
    is($st, 200, 'compare 200');
    is_deeply([ sort grep { $_ ne 'success' } keys %$j ], [qw(length name same_as_file source)], 'only name/source/length/same_as_file (+success)');
    is($j->{source}, 'db', 'db wins'); is($j->{length}, length($F_DBTOK), 'length of db token');
    is($j->{same_as_file}, JSON::MaybeXS::false, 'db differs from file');
    $no_leaks->($raw, 'db!=file');

    # 2. same
    $secret_tok->()->update({ secret_value => $F_FILETOK });
    ($st, $j, $raw) = $cmp->();
    is($j->{same_as_file}, JSON::MaybeXS::true, 'db same as file'); $no_leaks->($raw, 'db==file');

    # 3. file only
    $secret_tok->()->delete;
    ($st, $j, $raw) = $cmp->();
    is($j->{source}, 'file', 'file source'); is($j->{length}, length($F_FILETOK), 'file length');
    is($j->{same_as_file}, JSON::MaybeXS::true, 'file same as file'); $no_leaks->($raw, 'file only');

    # 4. db only
    unlink "$secd/cloudflare.json";
    $S->('AppSecret')->create({ secret_key => 'cloudflare_api_token', secret_value => $F_DBTOK });
    ($st, $j, $raw) = $cmp->();
    is($j->{source}, 'db', 'db only source'); ok(!defined $j->{same_as_file}, 'same_as_file null without file'); $no_leaks->($raw, 'db only');

    # 5. env only, none
    $secret_tok->()->delete;
    { local $ENV{CLOUDFLARE_API_TOKEN} = $F_DBTOK;
      ($st, $j, $raw) = $cmp->();
      is($j->{source}, 'env', 'env source'); is($j->{length}, length($F_DBTOK), 'env length'); ok(!defined $j->{same_as_file}, 'null'); $no_leaks->($raw, 'env'); }
    ($st, $j, $raw) = $cmp->();
    is($j->{source}, 'none', 'none'); is($j->{length}, 0, 'length 0'); ok(!defined $j->{same_as_file}, 'null');

    # placeholder in file does not count as a value
    $write_file->('<replace-with-cloudflare-api-token>');
    ($st, $j) = $cmp->();
    is($j->{source}, 'none', 'placeholder file value ignored');

    # auth / name checks
    ($st) = call('api_secrets_compare', mk(path => 'api/secrets/compare', q => { name => 'cloudflare' })); is($st, 401, 'compare unauthenticated -> 401');
    ($st) = call('api_secrets_compare', mk(address => '127.0.0.1', path => 'api/secrets/compare', q => { name => 'cloudflare' })); is($st, 401, 'compare LAN only -> 401');
    my ($st2) = call('api_secrets_compare', mk(token => $TOK{editor}, path => 'api/secrets/compare', q => { name => 'cloudflare' }));
    is($st2, 403, 'compare refuses editor role');
    ($st2) = call('api_secrets_compare', mk(token => $TOK{revoked}, path => 'api/secrets/compare', q => { name => 'cloudflare' }));
    is($st2, 403, 'compare refuses revoked token');
    ($st2) = call('api_secrets_compare', mk(token => $TOK{good}, path => 'api/secrets/compare', q => { name => 'app_secrets' }));
    is($st2, 400, 'compare refuses names outside the allowlist');
    ($st2) = call('api_secrets_compare', mk(token => $TOK{good}, path => 'api/secrets/compare', q => {}));
    is($st2, 400, 'compare needs a name');
    ($st2) = call('api_secrets_compare', mk(token => $TOK{admin}, path => 'api/secrets/compare', q => { name => 'cloudflare' }));
    is($st2, 200, 'admin token ok');
    ($st2) = call('api_secrets_compare', mk(session => { username => 'd', user_id => 3, roles => ['devops'] }, path => 'api/secrets/compare', q => { name => 'cloudflare' }));
    is($st2, 200, 'devops session ok');

    # nothing secret anywhere in logs
    my $logs = join("\n", @LOG) . "\n" . l4p_buffer();
    for my $f (@ALL_FAKES) {
        unlike($logs, qr/\Q$f\E/, 'log capture: no fake secret value');
    }
    unlike($logs, qr/\Q$TOK{good}\E/, 'log capture: no api token');
}

# =============================================================================
# I. _api_local_ok / COMSERV_API_LAN_BYPASS_WRITES
# =============================================================================
{
    local $ENV{COMSERV_API_LAN_BYPASS_WRITES};
    delete $ENV{COMSERV_API_LAN_BYPASS_WRITES};
    is(Comserv::Controller::Api::_api_lan_bypass_mode(), 'warn', 'default mode warn');
    for my $v (['off', 'off'], [' OFF ', 'off'], ['warn', 'warn'], ['bogus', 'warn'], ['', 'warn']) {
        local $ENV{COMSERV_API_LAN_BYPASS_WRITES} = $v->[0];
        is(Comserv::Controller::Api::_api_lan_bypass_mode(), $v->[1], "mode '$v->[0]' -> $v->[1]");
    }

    @LOG = ();
    my $post = sub { mk(address => '192.168.1.44', method => 'POST', path => 'api/todo/open_log', headers => { 'x-forwarded-for' => '10.0.0.1' }) };
    ok(Comserv::Controller::Api::_api_local_ok($post->()), 'warn mode: POST from LAN still allowed');
    my @w = grep { /LAN bypass used/ } @LOG;
    is(scalar(@w), 1, 'warn mode logs one line');
    like($w[0], qr{POST /api/todo/open_log from 192\.168\.1\.44 \(x-forwarded-for: yes\)}, 'log has route, address, XFF flag');
    @LOG = ();
    ok(Comserv::Controller::Api::_api_local_ok(mk(address => '127.0.0.1', method => 'GET', path => 'api/todos')), 'GET from localhost allowed');
    is(scalar(grep { /LAN bypass/ } @LOG), 0, 'GET not logged');
    ok(!Comserv::Controller::Api::_api_local_ok(mk(address => '203.0.113.9', method => 'POST')), 'non-LAN refused');

    local $ENV{COMSERV_API_LAN_BYPASS_WRITES} = 'off';
    @LOG = ();
    ok(!Comserv::Controller::Api::_api_local_ok($post->()), 'off mode: POST from LAN refused');
    ok(scalar(grep { /LAN bypass REFUSED/ } @LOG), '... and logged');
    ok(Comserv::Controller::Api::_api_local_ok(mk(address => '127.0.0.1', method => 'GET')), 'off mode: GET from localhost still allowed');
    ok(!Comserv::Controller::Api::_api_local_ok(mk(address => '::1', method => 'DELETE')), 'off mode: DELETE refused');
}

# =============================================================================
# J. CloudflareManager logs token LENGTH only
# =============================================================================
{
    require Comserv::Util::CloudflareManager;
    my $tok = "ZQ9xLOGTESTfakeCCCCCCCCCCCCCCCCCCCCCCQW7r";
    my $key = "KY5wAPIKEYfakeDDDDDDDDDDDDDDDDDDDDDDDDZP3t";
    my $bad = "BD8nCTRL\x01\x02fakeEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEJM1q";
    {
        package FakeUA; sub new { bless {}, shift } sub request { HTTP::Response->new(200, 'OK', ['Content-Type' => 'application/json'], '{"success":true,"result":[]}') }
    }
    for my $case ([token => $tok], [key => $key], [ctrl => $bad]) {
        my ($name, $val) = @$case;
        my %cf = $name eq 'key' ? (api_key => $val, email => 'ops@example.test') : (api_token => $val);
        my $mgr = Comserv::Util::CloudflareManager->new(config => { cloudflare => { %cf, application_id => 'app-1' } }, ua => FakeUA->new);
        $mgr->_get_api_credentials;
        eval { $mgr->_api_request('GET', '/zones') };
        eval { $mgr->get_zone_id('example.test') };
    }
    my $buf = l4p_buffer();
    for my $v ($tok, $key, "BD8nCTRLfakeEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEJM1q") {
        (my $clean = $v) =~ s/[^\x20-\x7E]//g;
        unlike($buf, qr/\Q$v\E/, 'cloudflare log: full value absent');
        unlike($buf, qr/\Q$clean\E/, 'cloudflare log: cleaned value absent');
        unlike($buf, qr/\Q@{[ substr($clean, 0, 4) ]}\E/, 'cloudflare log: first 4 chars absent');
        unlike($buf, qr/\Q@{[ substr($clean, -4) ]}\E/, 'cloudflare log: last 4 chars absent');
    }
    like($buf, qr/Token Length: \d+/, 'cloudflare log: token length is logged');
    like($buf, qr/Token length: 41/, 'cloudflare log: request path logs length');
}

done_testing;
