#!/usr/bin/env perl
# Todo/write API auth: identity-first gate (_api_gate), LAN bypass flag, actor from the
# authenticated user, bot token minting/listing/revoking. In-memory SQLite + fake $c.
# Every token/password here is a FAKE value; no network, no real DB, no real secrets.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::MaybeXS qw(encode_json decode_json);
use Digest::SHA qw(sha256_hex);
use IO::File;

BEGIN {
    for my $m (qw(DBD::SQLite SQL::Translator)) {
        eval "require $m; 1" or plan skip_all => "$m not installed";
    }
}

use Comserv::Util::Logging;
use Comserv::Util::TodoLog;
my @LOG;
{
    no warnings 'redefine';
    *Comserv::Util::Logging::log_with_details = sub { my ($s, $c, $lvl, $f, $l, $sub, $msg) = @_; push @LOG, "[$lvl] $sub: " . ($msg // ''); 1 };
}
# TodoLog needs MySQL; record the arguments the controller passes instead.
my @TL;
{
    no warnings 'redefine';
    for my $m (qw(toggle_start close_log done_with_log work_status)) {
        no strict 'refs';
        *{"Comserv::Util::TodoLog::$m"} = sub { my ($class, $c, %a) = @_; push @TL, { method => $m, %a }; return { success => 1, log_id => 77, todo_status => 5, count => 0, duration_mins => 3 } };
    }
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
    __PACKAGE__->add_columns(id => { data_type => 'integer', is_auto_increment => 1 }, user_id => { data_type => 'integer', is_nullable => 1 }, token_hash => { data_type => 'text', is_nullable => 1 }, token_name => { data_type => 'text', is_nullable => 1 }, is_active => { data_type => 'text', is_nullable => 1 }, created_at => { data_type => 'text', is_nullable => 1 }, expires_at => { data_type => 'text', is_nullable => 1 }, last_used_at => { data_type => 'text', is_nullable => 1 }, revoked_at => { data_type => 'text', is_nullable => 1 });
    __PACKAGE__->set_primary_key('id');
    __PACKAGE__->belongs_to(user => 'T::Result::User', 'user_id');
    package T::Result::Project;  use base 'DBIx::Class::Core';
    __PACKAGE__->table('projects');
    __PACKAGE__->add_columns(id => { data_type => 'integer', is_auto_increment => 1 }, map { $_ => { data_type => 'text', is_nullable => 1 } } qw(name description sitename comments status project_code priority));
    __PACKAGE__->set_primary_key('id');
    package T::Result::Todo;     use base 'DBIx::Class::Core';
    __PACKAGE__->table('todo');
    my @cols = qw(subject description project_id start_date due_date priority status developer sitename date_time_posted
        username_of_poster accumulative_time last_mod_by last_mod_date comments parent_todo estimated_man_hours group_of_poster
        project_code share user_id reporter owner is_blocking blocked_by_todo_id parent_id sort_order todo_type billable
        company_code time_of_day scheduled_date scheduled_start scheduled_end plan_id point_rate role_category is_fixed is_recurring);
    __PACKAGE__->add_columns(record_id => { data_type => 'integer', is_auto_increment => 1 }, map { $_ => { data_type => 'text', is_nullable => 1 } } @cols);
    __PACKAGE__->set_primary_key('record_id');
    __PACKAGE__->belongs_to(project => 'T::Result::Project', { 'foreign.id' => 'self.project_id' }, { join_type => 'left' });
    sub id { $_[0]->get_column('record_id') }
}
T::Schema->register_class(User => 'T::Result::User');
T::Schema->register_class(ApiToken => 'T::Result::ApiToken');
T::Schema->register_class(Project => 'T::Result::Project');
T::Schema->register_class(Todo => 'T::Result::Todo');

my $schema = T::Schema->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1, sqlite_unicode => 1 });
$schema->deploy;
my $S = sub { $schema->resultset(shift) };

my $F_PW = 'FAKE-PASSWORD-HASH-zz91';
$S->('User')->populate([
    [qw(id username password email roles status)],
    [1, 'botdev',   $F_PW, 'b@x.test',  'developer',       'active'],
    [2, 'plainu',   $F_PW, 'p@x.test',  'user',            'active'],
    [3, 'editbot',  $F_PW, 'e@x.test',  'editor',          'active'],
    [4, 'sleeping', $F_PW, 's@x.test',  'developer',       'inactive'],
    [5, 'adminu',   $F_PW, 'a@x.test',  'admin,developer', 'active'],
    [6, 'mixedbot', $F_PW, 'm@x.test',  'developer,user',  'active'],
    [7, 'opsbot',   $F_PW, 'o@x.test',  'devops',          'active'],
    [8, 'norolebot',$F_PW, 'n@x.test',  '',                'active'],
    [9, 'Shanta',   $F_PW, 'sh@x.test', 'admin',           'active'],
]);
my %TOK = (good => 'tok-good-fake-0001', revoked => 'tok-revoked-fake-02', expired => 'tok-expired-fake-03',
           inactive => 'tok-inactive-fake-04', norole => 'tok-norole-fake-05', editor => 'tok-editor-fake-06',
           sleeping => 'tok-sleeping-fake-07', admin => 'tok-admin-fake-08');
my $now = '2026-10-25 05:00:00';
$S->('ApiToken')->populate([
    [qw(id user_id token_hash token_name is_active created_at expires_at revoked_at)],
    [1, 1, sha256_hex($TOK{good}),     'botdev-main', 1, $now, undef,                 undef],
    [2, 1, sha256_hex($TOK{revoked}),  'old',         1, $now, undef,                 $now],
    [3, 1, sha256_hex($TOK{expired}),  'exp',         1, $now, '2020-01-01 00:00:00', undef],
    [4, 1, sha256_hex($TOK{inactive}), 'off',         0, $now, undef,                 undef],
    [5, 2, sha256_hex($TOK{norole}),   'plain',       1, $now, undef,                 undef],
    [6, 3, sha256_hex($TOK{editor}),   'editor',      1, $now, undef,                 undef],
    [7, 4, sha256_hex($TOK{sleeping}), 'sleep',       1, $now, undef,                 undef],
    [8, 5, sha256_hex($TOK{admin}),    'admin',       1, $now, '2099-01-01 00:00:00', undef],
]);
$S->('Project')->create({ id => 1, name => 'Project One', sitename => 'CSC', status => 'open' });
$S->('Todo')->create({ record_id => 10, subject => 'Todo ten', status => '2', priority => '3', project_id => 1, developer => 'x', sitename => 'CSC', last_mod_by => 'nobody' });

# ---- fake Catalyst context ------------------------------------------------------
{
    package FakeReq;
    sub new { my ($c, %a) = @_; my $s = bless { address => '203.0.113.9', method => 'GET', path => 'api/todo/open_log', headers => {}, q => {}, json => undef, %a }, $c; $s }
    sub address { $_[0]{address} } sub method { $_[0]{method} } sub path { $_[0]{path} }
    sub header { my ($s, $n) = @_; $s->{headers}{lc $n} }
    sub query_parameters { $_[0]{q} } sub params { $_[0]{q} }
    sub body { my $s = shift; return undef unless defined $s->{json}; my $fh = IO::File->new_tmpfile; print $fh $s->{json}; $fh->flush; seek($fh, 0, 0); return $fh }
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
        my $self = bless { session => $a{session} || {}, stash => { _app_time_tz => 'UTC', %{ $a{stash} || {} } }, schema => $a{schema} }, $c;
        $self->{req} = FakeReq->new(%{ $a{req} || {} });
        $self->{res} = FakeRes->new;
        return $self;
    }
    sub req { $_[0]{req} } sub request { $_[0]{req} } sub res { $_[0]{res} } sub session { $_[0]{session} } sub stash { $_[0]{stash} }
    sub sessionid { %{ $_[0]{session} } ? 'sid' : undef }
    sub model { FakeModel->new($_[0]{schema}) }
    sub detach { die { detach => 1 } }
}

require Comserv::Controller::Api;
my $ctrl = bless { logging => Comserv::Util::Logging->instance }, 'Comserv::Controller::Api';

sub mk {
    my (%a) = @_;
    my $hdr = $a{token} ? { authorization => "Bearer $a{token}" } : {};
    return FakeC->new(schema => $schema, session => $a{session}, stash => $a{stash},
        req => { address => $a{address} || '203.0.113.9', method => $a{method} || 'POST',
                 headers => { %$hdr, %{ $a{headers} || {} } }, q => $a{q} || {},
                 path => $a{path} || 'api/todo/open_log',
                 json => (ref $a{body} ? encode_json($a{body}) : $a{body}) });
}
sub call {
    my ($obj, $m, $c) = @_;
    eval { $obj->$m($c); 1 } or do { die $@ unless ref $@ eq 'HASH' && $@->{detach} };
    my $body = $c->res->body;
    my $j = {};
    if (defined $body && length $body) { $j = eval { decode_json($body) } || {} }
    return ($c->res->status, $j, $body // '');
}
sub api { my ($m, %a) = @_; return call($ctrl, $m, mk(%a)) }
sub last_tl { return $TL[-1] }
sub logs_like { my ($re) = @_; return scalar grep { /$re/ } @LOG }

my %BAD = (revoked => 403, expired => 403, inactive => 403, norole => 403, sleeping => 403);
my %ROUTES = (
    api_todo_open_log => { path => 'api/todo/open_log', body => { record_id => 10, actor => 'Shanta' } },
    api_todo_close_log => { path => 'api/todo/close_log', body => { record_id => 10, actor => 'Shanta', notes => 'did a thing' } },
    api_todo_done_with_log => { path => 'api/todo/done_with_log', body => { record_id => 10, actor => 'Shanta' } },
);
delete $ENV{COMSERV_API_LAN_BYPASS_WRITES};

# =============================================================================
# 1. token user is the actor, even if the body says Shanta; via recorded
# =============================================================================
for my $m (sort keys %ROUTES) {
    my $r = $ROUTES{$m};
    @TL = ();
    my ($st, $j) = api($m, token => $TOK{good}, path => $r->{path}, body => $r->{body});
    is($st, 200, "$m: valid developer token -> 200");
    my $t = last_tl();
    is($t->{username}, 'botdev', "$m: actor is the TOKEN user, not body actor 'Shanta'");
    like($t->{note}, qr/via: token:botdev-main/, "$m: via recorded in the log note");
    like($t->{note}, qr/on behalf of: Shanta/, "$m: body actor kept only as 'on behalf of' text");
}
{
    @TL = ();
    api('api_todo_open_log', token => $TOK{good}, body => { record_id => 10, actor => 'botdev' });
    unlike(last_tl()->{note}, qr/on behalf of/, 'same name in body -> no on-behalf note');
    @TL = ();
    api('api_todo_open_log', token => $TOK{good}, body => { record_id => 10, actor => "ev\nil'; DROP" });
    unlike(last_tl()->{note}, qr/[\n']/, 'body actor is sanitised inside the note');
}

# =============================================================================
# 2. session user works
# =============================================================================
{
    @TL = ();
    my ($st) = api('api_todo_open_log', session => { username => 'sessed', user_id => 3, roles => ['editor'] }, body => { record_id => 10, actor => 'Shanta' });
    is($st, 200, 'session editor -> 200');
    is(last_tl()->{username}, 'sessed', 'session user is the actor');
    like(last_tl()->{note}, qr/via: session/, 'via: session');
    ($st) = api('api_todo_open_log', session => { username => 'sessed', user_id => 3, roles => ['user'] }, body => { record_id => 10 });
    is($st, 403, 'session without an allowed role and no LAN address -> 403');
}

# =============================================================================
# 3. revoked / expired / inactive / no-role tokens are refused; never fall to LAN bypass
# =============================================================================
for my $t (sort keys %BAD) {
    @TL = ();
    my ($st) = api('api_todo_open_log', token => $TOK{$t}, body => { record_id => 10 });
    is($st, $BAD{$t}, "$t token -> $BAD{$t}");
    is(scalar @TL, 0, "$t token: nothing written");
    ($st) = api('api_todo_open_log', token => $TOK{$t}, address => '127.0.0.1', body => { record_id => 10 });
    is($st, $BAD{$t}, "$t token from 127.0.0.1 is STILL refused (no LAN fallback)");
}
{
    my ($st) = api('api_todo_open_log', token => 'not-a-real-token', address => '192.168.1.20', body => { record_id => 10 });
    is($st, 401, 'unknown token from the LAN -> 401, no bypass');
    ($st) = api('api_todo_work_status', method => 'GET', token => $TOK{revoked}, address => '192.168.1.20', path => 'api/todo/work_status');
    is($st, 403, 'work_status: revoked token from the LAN -> 403');
    ($st) = api('api_todo_open_log', body => { record_id => 10 });
    is($st, 401, 'no credentials, non-LAN -> 401');
    ($st) = api('api_todo_open_log', token => $TOK{editor}, body => { record_id => 10 });
    is($st, 200, 'editor token allowed');
}

# =============================================================================
# 4. LAN bypass flag: warn keeps today's behaviour and logs; off refuses non-GET
# =============================================================================
{
    @LOG = (); @TL = ();
    my ($st) = api('api_todo_open_log', address => '127.0.0.1', body => { record_id => 10, actor => 'hermes-agent' });
    is($st, 200, 'warn mode (default): localhost caller still works');
    is(last_tl()->{username}, 'hermes-agent', 'warn mode: legacy body actor used for LAN callers');
    like(last_tl()->{note}, qr/^via: lan$/, 'warn mode: via: lan recorded');
    ok(logs_like(qr/\[warn\] _api_local_ok: LAN bypass used \(mode=warn\) POST \/api\/todo\/open_log from 127\.0\.0\.1/), 'warn mode: LAN write logged as a warning');
    @TL = ();
    ($st) = api('api_todo_open_log', address => '192.168.1.50', body => { record_id => 10 });
    is($st, 200, 'warn mode: 192.168.1.x works');
    is(last_tl()->{username}, 'api', 'warn mode: default actor api');
    ($st) = api('api_todo_work_status', method => 'GET', address => '127.0.0.1', path => 'api/todo/work_status');
    is($st, 200, 'warn mode: work_status GET from localhost');

    local $ENV{COMSERV_API_LAN_BYPASS_WRITES} = 'off';
    @LOG = (); @TL = ();
    for my $m (sort keys %ROUTES) {
        ($st) = api($m, address => '127.0.0.1', path => $ROUTES{$m}{path}, body => $ROUTES{$m}{body});
        is($st, 403, "off mode: $m from 127.0.0.1 refused");
    }
    is(scalar @TL, 0, 'off mode: nothing written');
    ok(logs_like(qr/LAN bypass REFUSED \(mode=off\)/), 'off mode: refusal logged');
    ($st) = api('api_todo_open_log', address => '127.0.0.1', token => $TOK{good}, body => { record_id => 10 });
    is($st, 200, 'off mode: a valid token from localhost still works');
    ($st) = api('api_todo_work_status', method => 'GET', address => '127.0.0.1', path => 'api/todo/work_status');
    is($st, 200, 'off mode: GET reads from localhost unchanged');
    ($st) = api('api_todo_rank', address => '127.0.0.1', path => 'api/todo/rank', body => { apply => 1, model => 'm' });
    is($st, 403, 'off mode: rank (POST) from localhost refused');
    my ($st2, $j2, $raw) = api('api_todo_open_log', address => '127.0.0.1', body => { record_id => 10 });
    like($j2->{error}, qr/COMSERV_API_LAN_BYPASS_WRITES=off/, 'off mode: message says how to authenticate');
}

# =============================================================================
# 5. spoofed X-Forwarded-For
# =============================================================================
{
    # Peer 203.0.113.9 sends XFF 127.0.0.1: the PSGI layer must NOT rewrite REMOTE_ADDR, so the
    # app sees the real peer; the helper then must not treat it as local.
    my ($st) = api('api_todo_open_log', address => '203.0.113.9', headers => { 'x-forwarded-for' => '127.0.0.1' }, body => { record_id => 10 });
    is($st, 401, 'untrusted peer + forged XFF 127.0.0.1 is not local');
    ($st) = api('api_todo_open_log', address => '172.30.1.5', headers => { 'x-forwarded-for' => '127.0.0.1' }, body => { record_id => 10 });
    is($st, 401, 'ZeroTier-style 172.30.x peer + forged XFF is not local');

    # The psgi trust decision itself (extracted from script/comserv_server.psgi).
    my $psgi = "$FindBin::Bin/../script/comserv_server.psgi";
    my $src = do { local (@ARGV, $/) = ($psgi); <> } // '';
    if ($src =~ /(sub _comserv_trusted_cidrs \{.*?\n\}\nmy \$_trusted_cidrs = _comserv_trusted_cidrs\(\);\n\nsub _comserv_peer_trusted \{.*?\n\}\n)/s) {
        my $code = $1;
        eval "package PsgiTrust; use strict; use warnings; no warnings 'redefine'; $code; 1" or die $@;
        ok(PsgiTrust::_comserv_peer_trusted('127.0.0.1'), 'psgi: loopback peer is a trusted proxy');
        ok(PsgiTrust::_comserv_peer_trusted('::1'), 'psgi: ::1 trusted');
        ok(PsgiTrust::_comserv_peer_trusted('172.18.0.2'), 'psgi: docker bridge peer trusted');
        ok(!PsgiTrust::_comserv_peer_trusted('203.0.113.9'), 'psgi: public peer NOT trusted (XFF ignored)');
        ok(!PsgiTrust::_comserv_peer_trusted('192.168.1.77'), 'psgi: LAN peer NOT trusted');
        ok(!PsgiTrust::_comserv_peer_trusted('172.30.5.5'), 'psgi: ZeroTier 172.30.x NOT trusted');
        ok(!PsgiTrust::_comserv_peer_trusted('10.0.0.5'), 'psgi: 10.x NOT trusted');
        ok(!PsgiTrust::_comserv_peer_trusted(undef), 'psgi: undef peer not trusted');
    } else {
        fail('could not extract the trusted-proxy helpers from comserv_server.psgi');
    }
}

# =============================================================================
# 6. todo/update, project/update, todo/create, rank
# =============================================================================
{
    my ($st, $j) = api('api_todo_update', token => $TOK{good}, path => 'api/todo/update', body => { record_id => 10, status => '3', actor => 'Shanta' });
    is($st, 200, 'todo/update: token ok');
    is($S->('Todo')->find(10)->last_mod_by, 'botdev', 'todo/update: last_mod_by is the token user, not body actor');
    ok(logs_like(qr/Todo updated via API: ID=10.* by botdev \(via: token:botdev-main; on behalf of: Shanta\)/), 'todo/update: log has actor, via, on-behalf');

    ($st) = api('api_todo_update', token => $TOK{revoked}, path => 'api/todo/update', body => { record_id => 10, status => '4' });
    is($st, 403, 'todo/update: revoked token 403');
    is($S->('Todo')->find(10)->status, '3', '... and nothing changed');

    ($st) = api('api_todo_update', address => '127.0.0.1', session => { username => 'sessed', user_id => 3, roles => ['editor'] }, path => 'api/todo/update', body => { record_id => 10, priority => '1' });
    is($st, 200, 'todo/update: session user ok');
    is($S->('Todo')->find(10)->last_mod_by, 'sessed', '... recorded as the session user');

    ($st) = api('api_todo_update', address => '127.0.0.1', path => 'api/todo/update', body => { record_id => 10, priority => '2' });
    is($st, 200, 'todo/update: warn mode LAN caller still ok');
    is($S->('Todo')->find(10)->last_mod_by, 'system', '... legacy last_mod_by (system) unchanged');
    {
        local $ENV{COMSERV_API_LAN_BYPASS_WRITES} = 'off';
        ($st) = api('api_todo_update', address => '127.0.0.1', path => 'api/todo/update', body => { record_id => 10, priority => '5' });
        is($st, 403, 'todo/update: off mode LAN refused');
        is($S->('Todo')->find(10)->priority, '2', '... nothing changed');
    }
    ($st) = api('api_todo_update', path => 'api/todo/update', body => { record_id => 10, priority => '5' });
    is($st, 401, 'todo/update: non-LAN, no credentials -> 401');

    ($st) = api('api_project_update', token => $TOK{good}, path => 'api/project/update', body => { project_id => 1, name => 'Renamed', actor => 'Shanta' });
    is($st, 200, 'project/update: token ok');
    is($S->('Project')->find(1)->name, 'Renamed', '... applied');
    ok(logs_like(qr/Project updated via API: ID=1.* by botdev \(via: token:botdev-main; on behalf of: Shanta\)/), 'project/update: log has actor and via');
    ($st) = api('api_project_update', token => $TOK{inactive}, path => 'api/project/update', body => { project_id => 1, name => 'Hacked' });
    is($st, 403, 'project/update: inactive token 403');
    is($S->('Project')->find(1)->name, 'Renamed', '... unchanged');

    my %new = (subject => 'Created by bot', start_date => '2026-10-26', due_date => '2026-10-27', priority => 3, status => 2, project_id => 1, actor => 'Shanta', developer => 'Shanta');
    ($st, $j) = api('api_todo_create', token => $TOK{good}, path => 'api/todo/create', body => \%new);
    is($st, 200, 'todo/create: token ok') or diag explain $j;
    my $row = $S->('Todo')->find($j->{todo_id});
    is($row->username_of_poster, 'botdev', 'todo/create: poster is the token user');
    is($row->last_mod_by, 'botdev', 'todo/create: last_mod_by is the token user');
    is($row->user_id, 1, 'todo/create: user_id is the token user (not body assigned user)');
    ($st) = api('api_todo_create', token => $TOK{expired}, path => 'api/todo/create', body => { %new, subject => 'nope' });
    is($st, 403, 'todo/create: expired token 403');
    is($S->('Todo')->search({ subject => 'nope' })->count, 0, '... nothing created');
    {
        local $ENV{COMSERV_API_LAN_BYPASS_WRITES} = 'off';
        ($st) = api('api_todo_create', address => '192.168.1.9', path => 'api/todo/create', body => { %new, subject => 'lan-off' });
        is($st, 403, 'todo/create: off mode LAN refused');
        is($S->('Todo')->search({ subject => 'lan-off' })->count, 0, '... nothing created');
    }
    ($st) = api('api_todo_create', address => '192.168.1.9', session => { user_id => 1 }, path => 'api/todo/create', body => { %new, subject => 'lan-warn', assigned_to => 'botdev' });
    is($st, 200, 'todo/create: warn mode LAN caller still ok');
    is($S->('Todo')->search({ subject => 'lan-warn' })->first->username_of_poster, 'system', '... legacy poster (system) unchanged');

    ($st, $j) = api('api_todo_rank', token => $TOK{good}, path => 'api/todo/rank', body => { apply => 1 });
    is($st, 400, 'rank: valid token passes the gate (400 = missing model)');
    ok(logs_like(qr/todo\/rank apply=1 requested by botdev \(via: token:botdev-main\)/), 'rank apply=1 logs who asked');
    ($st) = api('api_todo_rank', token => $TOK{revoked}, path => 'api/todo/rank', body => { apply => 1, model => 'm' });
    is($st, 403, 'rank: revoked token 403');
    ($st) = api('api_todo_rank', path => 'api/todo/rank', body => { apply => 1, model => 'm' });
    is($st, 401, 'rank: no credentials 401');
}

# =============================================================================
# 7. Controller::Todo api_todo_update (/api/todo/update/<id>)
# =============================================================================
SKIP: {
    my $ok = eval { require Comserv::Controller::Todo; 1 };
    skip "Comserv::Controller::Todo did not load: " . substr("$@", 0, 80), 12 unless $ok;
    my $todo_ctrl = bless { logging => Comserv::Util::Logging->instance }, 'Comserv::Controller::Todo';
    # this action also takes $todo_id, so it is called directly
    my $tcall = sub {
        my (%a) = @_;
        my $c = mk(path => 'api/todo/update/10', method => 'PUT', %a);
        eval { $todo_ctrl->api_todo_update($c, 10); 1 } or do { die $@ unless ref $@ eq 'HASH' && $@->{detach} };
        my $b = $c->res->body; return ($c->res->status, ($b ? eval { decode_json($b) } || {} : {}));
    };
    $S->('Todo')->find(10)->update({ last_mod_by => 'start', status => '2' });
    my ($st) = $tcall->(token => $TOK{good}, body => { status => '3', actor => 'Shanta' });
    is($st, 200, 'Todo.pm update: token ok');
    is($S->('Todo')->find(10)->last_mod_by, 'botdev', 'Todo.pm update: last_mod_by is the token user');
    ($st) = $tcall->(token => $TOK{revoked}, body => { status => '4' });
    is($st, 403, 'Todo.pm update: revoked token 403');
    ($st) = $tcall->(token => $TOK{revoked}, address => '127.0.0.1', body => { status => '4' });
    is($st, 403, 'Todo.pm update: revoked token from localhost still 403');
    is($S->('Todo')->find(10)->status, '3', '... unchanged');
    ($st) = $tcall->(address => '127.0.0.1', body => { status => '2' });
    is($st, 200, 'Todo.pm update: warn mode localhost ok');
    is($S->('Todo')->find(10)->last_mod_by, 'system', '... legacy system actor');
    for my $addr ('10.1.2.3', '172.17.0.5', '192.168.50.7') {
        ($st) = $tcall->(address => $addr, body => { status => '1' });
        is($st, 401, "Todo.pm update: $addr is no longer an automatic LAN bypass");
    }
    local $ENV{COMSERV_API_LAN_BYPASS_WRITES} = 'off';
    ($st) = $tcall->(address => '127.0.0.1', body => { status => '1' });
    is($st, 403, 'Todo.pm update: off mode localhost refused');
    ($st) = $tcall->(address => '127.0.0.1', token => $TOK{good}, body => { status => '1' });
    is($st, 200, 'Todo.pm update: off mode + valid token ok');
}

# =============================================================================
# 8. bot token minting
# =============================================================================
my $ADMIN = { username => 'adminu', user_id => 5, roles => ['admin'] };
my %ADMINC = (session => $ADMIN, stash => { is_admin => 1 }, path => 'api/admin/bot_token');
sub mint { my ($body, %o) = @_; return api('api_admin_bot_token', %ADMINC, %o, body => $body) }
{
    my ($st, $j);
    ($st) = api('api_admin_bot_token', path => 'api/admin/bot_token', body => { username => 'opsbot' });
    is($st, 401, 'mint: anonymous -> 401');
    ($st) = api('api_admin_bot_token', path => 'api/admin/bot_token', address => '127.0.0.1', body => { username => 'opsbot' });
    is($st, 401, 'mint: LAN caller without a session -> 401');
    ($st) = api('api_admin_bot_token', path => 'api/admin/bot_token', token => $TOK{admin}, body => { username => 'opsbot' });
    is($st, 401, 'mint: an ADMIN user\'s Bearer token is not accepted (session only)');
    ($st) = api('api_admin_bot_token', path => 'api/admin/bot_token', session => { username => 'botdev', user_id => 1, roles => ['developer'] }, stash => {}, body => { username => 'opsbot' });
    is($st, 403, 'mint: non-admin session -> 403');
    is($S->('ApiToken')->count, 8, '... no token created by any of the above');

    for my $case ([adminu => 'admin account'], [Shanta => 'admin account'], [plainu => 'plain user role'], [mixedbot => 'developer+user'],
                  [sleeping => 'inactive'], [norolebot => 'no role'], [nobody_here => 'unknown user']) {
        ($st, $j) = mint({ username => $case->[0] });
        is($st, 403, "mint: $case->[1] ($case->[0]) refused with 403");
        ok($j->{error}, "... clear message: $j->{error}");
    }
    like((mint({ username => 'adminu' }))[1]{error}, qr/admin account/, 'admin-target message is explicit');
    is($S->('ApiToken')->count, 8, '... still no token created');

    ($st) = mint({ });                              is($st, 400, 'mint: missing username 400');
    ($st) = mint({ username => 'opsbot', expires_in_days => 366 }); is($st, 400, 'mint: 366 days refused');
    ($st) = mint({ username => 'opsbot', expires_in_days => 0 });   is($st, 400, 'mint: 0 days refused');
    ($st) = mint({ username => 'opsbot', expires_in_days => 'x' }); is($st, 400, 'mint: junk days refused');
    ($st) = api('api_admin_bot_token', %ADMINC, method => 'GET');   is($st, 405, 'mint: GET refused');

    @LOG = ();
    ($st, $j) = mint({ username => 'opsbot', token_name => 'opsbot main' });
    is($st, 200, 'mint: valid bot user gets a token');
    my $plain = $j->{token};
    ok(defined $plain && length($plain) >= 32, 'plaintext token returned once (32+ chars)');
    like($plain, qr/^cbt_[A-Za-z0-9_-]{43}$/, 'token format: prefix + 256 bits url-safe');
    is($j->{username}, 'opsbot', '... for the bot user');
    ok($j->{expires_at}, '... with an expiry');
    my $row = $S->('ApiToken')->find($j->{token_id});
    is($row->user_id, 7, 'token row owned by the BOT user, not the minting admin');
    is($row->token_hash, sha256_hex($plain), 'only the sha256 is stored');
    is($row->token_name, 'opsbot main', 'token name stored');
    my $leak = 0;
    for my $v (values %{ { $row->get_columns } }) { $leak++ if defined $v && index($v, $plain) >= 0 }
    is($leak, 0, 'no column of the stored row contains the plaintext');
    is(scalar(grep { index($_, $plain) >= 0 } @LOG), 0, 'plaintext token is NOT in the logs');
    is(scalar(grep { index($_, sha256_hex($plain)) >= 0 } @LOG), 0, 'token hash is not in the logs either');
    ok(logs_like(qr/\[info\] api_admin_bot_token: Bot API token minted: token_id=$j->{token_id} for user=opsbot by admin=adminu, expires_in_days=90/), 'who minted for whom is logged (default 90 days)');

    my $id = Comserv::Controller::Api::_api_identity(mk(token => $plain));
    is($id && $id->{username}, 'opsbot', 'the minted token authenticates as the bot user');
    like($id->{via}, qr/^token:opsbot_main$/, '... via names the token');
    @TL = ();
    api('api_todo_open_log', token => $plain, body => { record_id => 10, actor => 'Shanta' });
    is(last_tl()->{username}, 'opsbot', '... and is recorded as the actor on todo routes');

    ($st, $j) = mint({ username => 'editbot', expires_in_days => 365 });
    is($st, 200, 'mint: editor bot, 365 days ok');
    is($j->{expires_at} =~ /^(\d{4})-/ ? 1 : 0, 1, '... expiry present');
    my ($st2, $j2) = mint({ username => 'botdev' });
    isnt($j2->{token}, $j->{token}, 'tokens differ per call');
}

# =============================================================================
# 9. list + revoke
# =============================================================================
{
    my ($st, $j, $raw) = api('api_admin_bot_tokens', %ADMINC, method => 'GET', path => 'api/admin/bot_tokens');
    is($st, 200, 'list: admin session ok');
    ok($j->{count} >= 8, 'list: tokens returned');
    my ($first) = @{ $j->{tokens} };
    ok(!exists $first->{token} && !exists $first->{token_hash}, 'list: no token or hash field');
    ok(exists $first->{$_}, "list: has $_") for qw(id username token_name created_at expires_at revoked_at last_used_at);
    unlike($raw, qr/cbt_/, 'list: no plaintext tokens anywhere in the response');
    unlike($raw, qr/[0-9a-f]{64}/, 'list: no sha256 hashes in the response');
    is(scalar(grep { $_->{username} eq 'adminu' } @{ $j->{tokens} }), 0, 'list: the admin account\'s own tokens are not listed');
    my ($st2) = api('api_admin_bot_tokens', method => 'GET', path => 'api/admin/bot_tokens', token => $TOK{admin});
    is($st2, 401, 'list: Bearer token not accepted');
    ($st2) = api('api_admin_bot_tokens', method => 'GET', path => 'api/admin/bot_tokens', address => '127.0.0.1');
    is($st2, 401, 'list: LAN not accepted');
    my $j2; ($st2, $j2) = api('api_admin_bot_tokens', %ADMINC, method => 'GET', path => 'api/admin/bot_tokens', q => { username => 'opsbot' });
    ok($j2->{count} >= 1 && !grep({ $_->{username} ne 'opsbot' } @{ $j2->{tokens} }), 'list: username filter');
}
{
    # revoke: admin may revoke a bot account's token; audit-logged; not another admin's token
    my ($st, $j) = mint({ username => 'botdev', token_name => 'to revoke' });
    my ($plain, $tid) = ($j->{token}, $j->{token_id});
    ok(Comserv::Controller::Api::_api_identity(mk(token => $plain)), 'precondition: token works');
    @LOG = ();
    my $c = mk(%ADMINC, method => 'DELETE', path => "api/api_revoke_token/$tid");
    eval { $ctrl->api_revoke_token($c, $tid); 1 } or do { die $@ unless ref $@ eq 'HASH' && $@->{detach} };
    is($c->res->status, 200, 'revoke: admin revokes a bot user\'s token');
    ok(!Comserv::Controller::Api::_api_identity(mk(token => $plain)), '... and it no longer authenticates');
    my $r = $S->('ApiToken')->find($tid);
    ok($r->revoked_at && !$r->is_active, '... row marked revoked/inactive');
    ok(logs_like(qr/\[info\] api_revoke_token: API token revoked: by=adminu, owner=botdev, token_id=$tid/), 'revoke is audit-logged with revoker and owner');

    # another admin's token (id 8, adminu is the owner here; use Shanta as the caller)
    @LOG = ();
    my $c2 = mk(session => { username => 'Shanta', user_id => 9, roles => ['admin'] }, stash => { is_admin => 1 }, method => 'DELETE', path => 'api/api_revoke_token/8');
    eval { $ctrl->api_revoke_token($c2, 8); 1 } or do { die $@ unless ref $@ eq 'HASH' && $@->{detach} };
    is($c2->res->status, 404, 'revoke: an admin cannot revoke ANOTHER admin\'s token');
    ok($S->('ApiToken')->find(8)->is_active, '... still active');
    ok(logs_like(qr/\[warn\] api_revoke_token: Refused: admin=Shanta tried to revoke token_id=8/), '... refusal logged');

    # own token still works as before
    my ($st3, $j3) = mint({ username => 'botdev' });
    my $c3 = mk(session => { username => 'botdev', user_id => 1, roles => ['developer'] }, stash => {}, method => 'DELETE', path => 'api/api_revoke_token/1');
    eval { $ctrl->api_revoke_token($c3, 1); 1 } or do { die $@ unless ref $@ eq 'HASH' && $@->{detach} };
    is($c3->res->status, 403, 'revoke: non-admin session refused');
    my $c4 = mk(token => $TOK{admin}, method => 'DELETE', path => 'api/api_revoke_token/1');
    eval { $ctrl->api_revoke_token($c4, 1); 1 } or do { die $@ unless ref $@ eq 'HASH' && $@->{detach} };
    is($c4->res->status, 401, 'revoke: Bearer token alone refused');
    my $c5 = mk(%ADMINC, method => 'DELETE', path => 'api/api_revoke_token/8');   # own token
    eval { $ctrl->api_revoke_token($c5, 8); 1 } or do { die $@ unless ref $@ eq 'HASH' && $@->{detach} };
    is($c5->res->status, 200, 'revoke: admin can still revoke their own token');
    my $c6 = mk(%ADMINC, method => 'DELETE', path => 'api/api_revoke_token/99999');
    eval { $ctrl->api_revoke_token($c6, 99999); 1 } or do { die $@ unless ref $@ eq 'HASH' && $@->{detach} };
    is($c6->res->status, 404, 'revoke: unknown id 404');
}

done_testing();
