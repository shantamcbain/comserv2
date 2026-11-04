#!/usr/bin/env perl
# Fine-grained, data-driven access (Comserv::Util::AccessCheck + role_permissions):
# admin passes; role with row passes; no row 403; wrong site 403; own_only; token
# scope intersection; secretary example from data only. In-memory SQLite + fake $c.
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
use Comserv::Util::AccessCheck;
my @LOG;
{
    no warnings 'redefine';
    *Comserv::Util::Logging::log_with_details = sub { my ($s, $c, $lvl, $f, $l, $sub, $msg) = @_; push @LOG, "[$lvl] $sub: " . ($msg // ''); 1 };
}

{
    package R::Schema;           use base 'DBIx::Class::Schema';
    package R::Result::User;     use base 'DBIx::Class::Core';
    __PACKAGE__->table('users');
    __PACKAGE__->add_columns(id => { data_type => 'integer', is_auto_increment => 1 }, map { $_ => { data_type => 'text', is_nullable => 1 } } qw(username password email roles status));
    __PACKAGE__->set_primary_key('id');
    package R::Result::ApiToken; use base 'DBIx::Class::Core';
    __PACKAGE__->table('api_tokens');
    __PACKAGE__->add_columns(id => { data_type => 'integer', is_auto_increment => 1 }, map { $_ => { data_type => 'text', is_nullable => 1 } }
        qw(user_id token_hash token_name is_active created_at expires_at last_used_at revoked_at scope_sites scope_modules scope_actions own_only));
    __PACKAGE__->set_primary_key('id');
    __PACKAGE__->belongs_to(user => 'R::Result::User', 'user_id');
    package R::Result::Site;     use base 'DBIx::Class::Core';
    __PACKAGE__->table('sites');
    __PACKAGE__->add_columns(id => { data_type => 'integer', is_auto_increment => 1 }, name => { data_type => 'text' });
    __PACKAGE__->set_primary_key('id');
    package R::Result::UserSiteRole; use base 'DBIx::Class::Core';
    __PACKAGE__->table('user_site_roles');
    __PACKAGE__->add_columns(id => { data_type => 'integer', is_auto_increment => 1 }, user_id => { data_type => 'integer' }, site_id => { data_type => 'integer', is_nullable => 1 },
        role => { data_type => 'text' }, is_active => { data_type => 'integer', default_value => 1 }, expires_at => { data_type => 'text', is_nullable => 1 });
    __PACKAGE__->set_primary_key('id');
    package R::Result::UserModuleAccess; use base 'DBIx::Class::Core';
    __PACKAGE__->table('user_module_access');
    __PACKAGE__->add_columns(id => { data_type => 'integer', is_auto_increment => 1 }, map { $_ => { data_type => 'text', is_nullable => 1 } } qw(username sitename module_name granted));
    __PACKAGE__->set_primary_key('id');
    package R::Result::RolePermission; use base 'DBIx::Class::Core';
    __PACKAGE__->table('role_permissions');
    __PACKAGE__->add_columns(id => { data_type => 'integer', is_auto_increment => 1 }, role => { data_type => 'text' }, module => { data_type => 'text' },
        action => { data_type => 'text' }, own_only => { data_type => 'integer', default_value => 0 }, sitename => { data_type => 'text', is_nullable => 1 }, requires_grant => { data_type => 'text', is_nullable => 1 }, created_by => { data_type => 'text', is_nullable => 1 });
    __PACKAGE__->set_primary_key('id');
    package R::Result::Project;  use base 'DBIx::Class::Core';
    __PACKAGE__->table('projects');
    __PACKAGE__->add_columns(id => { data_type => 'integer', is_auto_increment => 1 }, map { $_ => { data_type => 'text', is_nullable => 1 } } qw(name description sitename comments status project_code priority username_of_poster developer_name));
    __PACKAGE__->set_primary_key('id');
    package R::Result::Todo;     use base 'DBIx::Class::Core';
    __PACKAGE__->table('todo');
    my @cols = qw(subject description project_id start_date due_date priority status developer sitename date_time_posted
        username_of_poster accumulative_time last_mod_by last_mod_date comments parent_todo estimated_man_hours group_of_poster
        project_code share user_id reporter owner is_blocking blocked_by_todo_id parent_id sort_order todo_type billable
        company_code time_of_day scheduled_date scheduled_start scheduled_end plan_id point_rate role_category is_fixed is_recurring
        recurrence_rule creator_timezone);
    __PACKAGE__->add_columns(record_id => { data_type => 'integer', is_auto_increment => 1 }, map { $_ => { data_type => 'text', is_nullable => 1 } } @cols);
    __PACKAGE__->set_primary_key('record_id');
    __PACKAGE__->belongs_to(project => 'R::Result::Project', { 'foreign.id' => 'self.project_id' }, { join_type => 'left' });
    sub id { $_[0]->get_column('record_id') }
}
R::Schema->register_class($_ => "R::Result::$_") for qw(User ApiToken Site UserSiteRole UserModuleAccess RolePermission Project Todo);
my $schema = R::Schema->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1 });
$schema->deploy;
my $S = sub { $schema->resultset(shift) };

my $F_PW = 'FAKE-PASSWORD-HASH-rp01';
$S->('User')->populate([
    [qw(id username password email roles status)],
    [1, 'adminu',           $F_PW, 'a@x.test', 'admin',     'active'],
    [2, 'shanta_secretary', $F_PW, 's@x.test', 'user',      'active'],
    [3, 'otheru',           $F_PW, 'o@x.test', 'user',      'active'],
    [4, 'editbot',          $F_PW, 'e@x.test', 'editor',    'active'],
    [5, 'devbot',           $F_PW, 'd@x.test', 'developer', 'active'],
    [6, 'opsbot',           $F_PW, 'o2@x.test','devops',    'active'],
    [7, 'siteadm',          $F_PW, 'sa@x.test','user',      'active'],
    [8, 'normu',            $F_PW, 'n@x.test', 'normal',    'active'],
]);
$S->('Site')->populate([[qw(id name)], [1, 'CSC'], [2, 'Shanta']]);
$S->('UserSiteRole')->populate([
    [qw(id user_id site_id role is_active)],
    [1, 2, 2, 'secretary', 1],
    [2, 3, 2, 'viewer',    1],
    [3, 4, 2, 'editor',    1],
    [4, 7, 2, 'admin',     1],
]);
my %TOK = (sec => 'tok-sec-fake-0001', sec_narrow => 'tok-secn-fake-0002', sec_wide => 'tok-secw-fake-0003', dev_scoped => 'tok-devs-fake-0004', edit => 'tok-edit-fake-0005');
my $now = '2026-10-31 05:00:00';
$S->('ApiToken')->populate([
    [qw(id user_id token_hash token_name is_active created_at scope_sites scope_modules scope_actions own_only)],
    [1, 2, sha256_hex($TOK{sec}),        'sec',     1, $now, undef,          undef,  undef,       undef],
    [2, 2, sha256_hex($TOK{sec_narrow}), 'secn',    1, $now, 'Shanta',       'todo', 'read',      undef],
    [3, 2, sha256_hex($TOK{sec_wide}),   'secw',    1, $now, 'Shanta,CSC',   '*',    '*',         undef],
    [4, 5, sha256_hex($TOK{dev_scoped}), 'devs',    1, $now, 'Shanta',       'todo', 'read,update', 1],
    [5, 4, sha256_hex($TOK{edit}),       'edit',    1, $now, undef,          undef,  undef,       undef],
]);
$S->('Project')->create({ id => 1, name => 'Shanta project', sitename => 'Shanta', status => 'open' });
$S->('Project')->create({ id => 2, name => 'CSC project', sitename => 'CSC', status => 'open' });
$S->('Todo')->create({ record_id => 10, subject => 'Mine', status => 2, priority => 3, project_id => 1, sitename => 'Shanta', user_id => 2, username_of_poster => 'shanta_secretary' });
$S->('Todo')->create({ record_id => 11, subject => 'Not mine', status => 2, priority => 3, project_id => 1, sitename => 'Shanta', user_id => 1, username_of_poster => 'adminu', developer => 'adminu' });
$S->('Todo')->create({ record_id => 12, subject => 'CSC todo', status => 2, priority => 3, project_id => 2, sitename => 'CSC', user_id => 2 });
# ---- fake Catalyst context ------------------------------------------------------
{
    package FakeReq;
    sub new { my ($c, %a) = @_; my $s = bless { address => '203.0.113.9', method => 'GET', path => 'api/todo/open_log', headers => {}, q => {}, json => undef, %a }, $c; $s }
    sub address { $_[0]{address} } sub method { $_[0]{method} } sub path { $_[0]{path} }
    sub header { my ($s, $n) = @_; $s->{headers}{lc $n} }
    sub query_parameters { $_[0]{q} } sub params { $_[0]{q} } sub parameters { $_[0]{q} } sub param { $_[0]{q}{$_[1]} }
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
    sub response { $_[0]{res} }
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
my $AC = 'Comserv::Util::AccessCheck';
my %U = (admin => { user_id => 1, username => 'adminu', roles => ['admin'] },
         sec   => { user_id => 2, username => 'shanta_secretary', roles => ['user'] },
         other => { user_id => 3, username => 'otheru', roles => ['user'] },
         edit  => { user_id => 4, username => 'editbot', roles => ['editor'] });
my $T = sub { $S->('Todo')->find(shift) };
sub chk { my (%a) = @_; return $AC->check($schema, %a) }

# ---- legacy mode: table empty -> old role list, nothing changes ----
ok(!$AC->rbac_active($schema), 'empty role_permissions -> legacy mode');
ok(chk(user => $U{edit}, module => 'todo', action => 'update', sitename => 'Shanta')->{ok}, 'legacy: editor passes');
is(chk(user => $U{sec}, module => 'todo', action => 'read', sitename => 'Shanta')->{status}, 403, 'legacy: plain user 403');
ok(chk(user => $U{sec}, module => 'todo', action => 'update', sitename => 'Shanta', legacy_roles => ['*'])->{ok}, "legacy ['*'] = any logged-in user (old session-only AJAX actions)");

# ---- starter rows keep today's legacy access (Code Guard item 2) ----
{
    # Routes and their legacy role lists, as wired in Api.pm / Todo.pm.
    my @routes = (
        [todo => read   => undef], [todo => create => undef], [todo => update => undef],   # API (default list)
        [project => read => undef], [project => create => undef], [project => update => undef],
        [todo => delete => [qw(admin developer editor)]],                                  # web delete
        [todo => update => [qw(admin developer editor devops)]],                           # web quick_close/open_log/close_log
    );
    my @who = ({ user_id => 4, username => 'editbot', roles => ['editor'] }, { user_id => 6, username => 'opsbot', roles => ['devops'] },
               { user_id => 5, username => 'devbot', roles => ['developer'] }, { user_id => 1, username => 'adminu', roles => ['admin'] },
               { user_id => 3, username => 'otheru', roles => ['user'] });
    my $matrix = sub { my %m; for my $u (@who) { for my $rt (@routes) { for my $site (qw(Shanta CSC)) {
        $m{"$u->{username} $rt->[0]/$rt->[1] " . join(',', @{ $rt->[2] || ['default'] }) . " \@$site"} =
            chk(user => $u, module => $rt->[0], action => $rt->[1], sitename => $site, ($rt->[2] ? (legacy_roles => $rt->[2]) : ()))->{ok} ? 1 : 0 } } } \%m };
    my $before = $matrix->();
    ok(!$AC->rbac_active($schema), 'matrix taken in legacy mode');
    $S->('RolePermission')->create($_) for $AC->starter_rows;
    ok($AC->rbac_active($schema), 'starter rows switch on rbac');
    my $after = $matrix->();
    my @lost = grep { $before->{$_} && !$after->{$_} } sort keys %$before;
    # devops is not a role (Shanta, Oct 31): only the devops account loses access.
    my @lost_real = grep { !/^opsbot / } @lost;
    is_deeply(\@lost_real, [], 'after starter rows no real-role user (editor/developer/admin) loses access') or diag explain \@lost_real;
    ok(scalar(grep { /^opsbot / } @lost), 'devops account loses its legacy access (devops is not a role)');
    my @gained = grep { !$before->{$_} && $after->{$_} } sort keys %$before;
    is_deeply(\@gained, [], 'and nobody gains access on these routes') or diag explain \@gained;
    ok(chk(user => $who[0], module => 'todo', action => 'read', sitename => 'Shanta', legacy_roles => [qw(admin developer)])->{ok},
       'known widening: editor gets web /todo read via the todo/read starter row');
    $S->('RolePermission')->delete;
}

# ---- Shanta's role rules (Oct 31): matrix after starter rows ----
{
    ok(!(grep { $_->{role} =~ /^(devops|guest|user|helpdesk|admin|developer)$/ } $AC->starter_rows), 'no starter rows for devops/guest/user/helpdesk/admin/developer');
    $S->('Site')->populate([[qw(id name)], [10, 'none'], [11, 'SB ']]);
    $S->('User')->populate([[qw(id username password email roles status)],
        [20, 'membu',  $F_PW, 'm@x.test',  'member',   'active'],
        [21, 'normsub',$F_PW, 'ns@x.test', 'normal',   'active'],
        [22, 'helpu',  $F_PW, 'h@x.test',  'helpdesk', 'active'],
        [23, 'guestu', $F_PW, 'g@x.test',  'guest',    'active'],
        [24, 'noneu',  $F_PW, 'nn@x.test', 'helpdesk', 'active'],
        [25, 'sbed',   $F_PW, 'sb@x.test', 'helpdesk', 'active']]);
    $S->('UserSiteRole')->populate([[qw(id user_id site_id role is_active)],
        [20, 24, 10, 'editor', 1],     # editor on site 'none' only
        [21, 25, 11, 'editor', 1]]);   # editor on stored 'SB ' (trailing space)
    $S->('UserModuleAccess')->create({ username => 'normsub', sitename => 'Shanta', module_name => 'planning', granted => 1 });
    $S->('Todo')->create({ record_id => 30, subject => 'normsub own', sitename => 'Shanta', user_id => 21, username_of_poster => 'normsub' });
    $S->('RolePermission')->create($_) for $AC->starter_rows;
    my %u = (edit => { user_id => 4, username => 'editbot', roles => ['editor'] },
             memb => { user_id => 20, username => 'membu', roles => ['member'] },
             norm => { user_id => 8, username => 'normu', roles => ['normal'] },
             nsub => { user_id => 21, username => 'normsub', roles => ['normal'] },
             help => { user_id => 22, username => 'helpu', roles => ['helpdesk'] },
             gst  => { user_id => 23, username => 'guestu', roles => ['guest'] },
             usr  => { user_id => 3, username => 'otheru', roles => ['user'] },
             none => { user_id => 24, username => 'noneu', roles => ['helpdesk'] },
             sb   => { user_id => 25, username => 'sbed', roles => ['helpdesk'] });
    my $ok = sub { my ($w, $m, $a, $site, $rec) = @_; chk(user => $u{$w}, module => $m, action => $a, sitename => $site, ($rec ? (record => $rec) : ()))->{ok} ? 1 : 0 };
    for my $a (qw(read create update delete)) { is($ok->('edit', 'todo', $a, 'CSC', $T->(11)), 1, "editor keeps todo/$a") }
    for my $a (qw(read create update)) { is($ok->('edit', 'project', $a, 'CSC'), 1, "editor keeps project/$a") }
    is($ok->('edit', 'project', 'delete', 'CSC'), 0, 'editor: no project/delete (none before either)');
    for my $m (qw(todo project calendar)) { for my $a (qw(read create update)) { is($ok->('help', $m, $a, 'Shanta'), 0, "helpdesk: no $m/$a") } }
    for my $w (qw(memb norm)) { for my $m (qw(todo calendar)) { is($ok->($w, $m, 'create', 'Shanta'), 0, "$w not subscribed: $m/create 403") } }
    is($ok->('nsub', 'todo', 'create', 'Shanta'), 1, 'normal subscribed to planning: todo create ok');
    is($ok->('nsub', 'calendar', 'read', 'Shanta', $T->(30)), 1, 'normal subscribed: calendar read own ok');
    is($ok->('nsub', 'todo', 'update', 'Shanta', $T->(30)), 1, 'normal subscribed: update own todo ok');
    is($ok->('nsub', 'todo', 'update', 'Shanta', $T->(11)), 0, "normal subscribed: someone else's todo 403 (own_only)");
    is($ok->('nsub', 'todo', 'delete', 'Shanta', $T->(30)), 0, 'normal subscribed: no delete');
    is($ok->('nsub', 'todo', 'create', 'CSC'), 0, 'subscription is per site (Shanta only)');
    for my $w (qw(gst usr)) { for my $m (qw(todo calendar project)) { for my $a (qw(read create update)) { is($ok->($w, $m, $a, 'Shanta'), 0, "$w: no $m/$a") } } }
    is($ok->('none', 'todo', 'update', 'Shanta', $T->(11)), 0, "editor role on site 'none' grants nothing elsewhere");
    is($ok->('none', 'todo', 'read', 'none'), 0, "nothing granted on site 'none' itself");
    is($ok->('nsub', 'todo', 'read', ' none '), 0, "'none' matched trimmed/any case");
    is($ok->('sb', 'todo', 'update', 'SB', $T->(11)), 1, "site role on stored 'SB ' matches request site 'SB' (trimmed)");
    is($ok->('sb', 'todo', 'update', 'CSC', $T->(11)), 0, "and only on SB");
    ok(chk(user => { user_id => 5, username => 'devbot', roles => ['developer'] }, module => 'todo', action => 'delete', sitename => 'Shanta')->{ok}, 'developer passes without rows');
    # Code Guard follow-ups (round 5)
    $S->('Site')->create({ id => 12, name => 'SB' });
    my $amb = chk(user => $u{sb}, module => 'todo', action => 'update', sitename => 'SB', record => $T->(11));
    is($amb->{code}, 'site_ambiguous', "'SB' and 'SB ' both exist -> 403 site_ambiguous");
    is($amb->{status}, 403, 'ambiguous site is 403');
    $S->('Site')->find(12)->delete;
    $S->('RolePermission')->create({ role => $_, module => 'todo', action => 'read', own_only => 0 }) for qw(devops guest user anonymous);
    is($ok->('gst', 'todo', 'read', 'Shanta'), 0, 'a guest row in role_permissions is ignored');
    is($ok->('usr', 'todo', 'read', 'Shanta'), 0, 'a user row is ignored');
    is(chk(user => { user_id => 6, username => 'opsbot', roles => ['devops'] }, module => 'todo', action => 'read', sitename => 'Shanta')->{ok} ? 1 : 0, 0, 'a devops row is ignored');
    {
        package FakeMsaRow; sub new { bless { e => $_[1] }, $_[0] } sub is_expired { die "boom\n" if $_[0]{e} eq 'die'; $_[0]{e} }
        package FakeMsaRs;  sub new { bless { rows => $_[1] }, $_[0] } sub search { $_[0] } sub all { @{ $_[0]{rows} } }
    }
    no warnings 'redefine';
    my $orig = \&Comserv::Util::AccessCheck::_rs;
    for my $case ([0, 1, 'active grant'], [1, 0, 'expired grant'], ['die', 0, 'is_expired error = expired (fail closed)']) {
        local *Comserv::Util::AccessCheck::_rs = sub { $_[1] eq 'MembershipServiceAccess' ? FakeMsaRs->new([FakeMsaRow->new($case->[0])]) : $orig->(@_) };
        is($AC->has_module_grant($schema, { user_id => 20, username => 'membu' }, 'Shanta', 'planning'), $case->[1], "membership: $case->[2]");
    }
    $S->('RolePermission')->delete;
}

# ---- admin page: first row needs confirmation; starter button (item 2) ----
{
    no warnings 'once';
    *FakeRes::redirect = sub { $_[0]{location} = $_[1] };
    *FakeC::flash = sub { $_[0]{flash} ||= {} };
    *FakeC::uri_for = sub { $_[1] };
    require Comserv::Controller::Admin::RolePermissions;
    my $rp = bless { logging => Comserv::Util::Logging->instance }, 'Comserv::Controller::Admin::RolePermissions';
    my $web = sub { my ($m, %q) = @_;
        my $c = FakeC->new(schema => $schema, session => { user_id => 1, username => 'adminu', roleperm_csrf => 'csrf-fake-1' },
                           req => { method => 'POST', q => { csrf => 'csrf-fake-1', %q } });
        eval { $rp->$m($c); 1 } or do { die $@ unless ref $@ eq 'HASH' && $@->{detach} };
        return $c };
    my $c1 = $web->('save', role => 'secretary', module => 'todo', action => 'read', sitename => 'Shanta');
    like($c1->flash->{error_msg} // '', qr/FIRST permission row/, 'first single row refused without confirmation');
    is($S->('RolePermission')->count, 0, '... nothing saved');
    my $c0 = $web->('save', csrf => 'wrong', role => 'x', module => 'todo', action => 'read', confirm_first => 1);
    like($c0->flash->{error_msg} // '', qr/expired or invalid/, 'bad CSRF refused');
    my $c2 = $web->('starter');
    like($c2->flash->{status_msg} // '', qr/Starter rows added: \d+/, 'starter button adds rows');
    is($S->('RolePermission')->count, scalar(my @x = $AC->starter_rows), '... exactly the starter set');
    $web->('starter');
    is($S->('RolePermission')->count, scalar(@x), 'starter is idempotent');
    $S->('RolePermission')->delete;
    my $c3 = $web->('save', role => 'secretary', module => 'todo', action => 'read', sitename => 'Shanta', confirm_first => 1);
    ok(!$c3->flash->{error_msg}, 'first row saved with confirmation') or diag $c3->flash->{error_msg};
    $S->('RolePermission')->delete;
}

# ---- site admin is admin on its own site only (Code Guard item 3) ----
{
    my $sa = { user_id => 7, username => 'siteadm', roles => ['user', 'admin'] };   # session roles merged at login
    is(chk(user => $sa, module => 'todo', action => 'delete', sitename => 'Shanta')->{mode}, 'site_admin', 'site admin passes on its own site');
    is(chk(user => $sa, module => 'todo', action => 'read', sitename => 'CSC')->{status}, 403, 'site admin with merged session admin: refused on another site (legacy mode)');
    ok(!$AC->is_global_admin($schema, 7), 'is_global_admin uses users.roles: site admin is not global');
    ok($AC->is_global_admin($schema, 1), 'global admin from users.roles');
    require Comserv::Controller::Admin::RolePermissions;
    my $rp = bless { logging => Comserv::Util::Logging->instance }, 'Comserv::Controller::Admin::RolePermissions';
    ok(!$rp->_is_admin(FakeC->new(schema => $schema, session => { user_id => 7, username => 'siteadm', roles => ['admin'], is_admin => 1 }, stash => { is_admin => 1 })),
       '/admin/role_permissions refuses a site admin even with session admin');
    ok($rp->_is_admin(FakeC->new(schema => $schema, session => { user_id => 1, username => 'adminu', roles => ['user'] })), '/admin/role_permissions accepts users.roles admin');
}

# ---- secretary role purely from data ----
for my $a (qw(read create update)) {
    for my $m (qw(todo calendar)) {
        $S->('RolePermission')->create({ role => 'secretary', module => $m, action => $a, own_only => 1, sitename => 'Shanta' });
    }
}
ok($AC->rbac_active($schema), 'rows present -> rbac mode');

my $r = chk(user => $U{admin}, module => 'todo', action => 'delete', sitename => 'Nowhere', record => $T->(10));
ok($r->{ok}, 'admin passes anything'); is($r->{mode}, 'admin', '... mode admin');
ok(chk(user => { user_id => 5, username => 'devbot', roles => ['developer'] }, module => 'x', action => 'read', sitename => 'CSC')->{ok}, 'developer passes');

$r = chk(user => $U{sec}, module => 'todo', action => 'update', sitename => 'Shanta', record => $T->(10));
ok($r->{ok}, 'secretary: update own todo on Shanta'); is($r->{role}, 'secretary', '... via secretary role');
ok(chk(user => $U{sec}, module => 'calendar', action => 'read', sitename => 'Shanta', record => $T->(10))->{ok}, 'secretary: calendar read own');
ok(chk(user => $U{sec}, module => 'todo', action => 'create', sitename => 'Shanta')->{ok}, 'secretary: create (no record = own)');
$r = chk(user => $U{sec}, module => 'todo', action => 'update', sitename => 'Shanta', record => $T->(11));
is($r->{status}, 403, 'own_only blocks others\' records'); is($r->{code}, 'own_only', '... code own_only');
$r = chk(user => $U{sec}, module => 'todo', action => 'delete', sitename => 'Shanta', record => $T->(10));
is($r->{code}, 'no_permission', 'secretary: no delete row -> 403');
$r = chk(user => $U{sec}, module => 'inventory', action => 'read', sitename => 'Shanta');
is($r->{status}, 403, 'secretary: other module -> 403');
$r = chk(user => $U{sec}, module => 'todo', action => 'read', sitename => 'CSC', record => $T->(12));
is($r->{status}, 403, 'wrong site (no user_site_roles row) -> 403');
like($r->{code}, qr/^(no_site_role|no_permission)$/, '... no role/permission there');
$r = chk(user => $U{other}, module => 'todo', action => 'read', sitename => 'Shanta');
is($r->{code}, 'no_permission', 'role without a row (viewer) -> 403');
$r = chk(user => $U{edit}, module => 'todo', action => 'update', sitename => 'Shanta');
is($r->{status}, 403, 'rbac on: editor without rows loses access (documented risk)');

# NULL sitename row = any site; own_only=0 row frees ownership
$S->('RolePermission')->create({ role => 'viewer', module => 'todo', action => 'read', own_only => 0, sitename => undef });
ok(chk(user => $U{other}, module => 'todo', action => 'read', sitename => 'Shanta', record => $T->(11))->{ok}, 'NULL sitename row applies on any site; own_only=0 reads others');

# user_module_access off switch
$S->('UserModuleAccess')->create({ username => 'otheru', sitename => 'Shanta', module_name => 'todo', granted => 0 });
is(chk(user => $U{other}, module => 'todo', action => 'read', sitename => 'Shanta')->{code}, 'module_off', 'user_module_access granted=0 still switches the module off');

# expired / inactive site role
$S->('UserSiteRole')->find(2)->update({ expires_at => '2020-01-01 00:00:00' });
$S->('UserModuleAccess')->delete;
is(chk(user => $U{other}, module => 'todo', action => 'read', sitename => 'Shanta')->{status}, 403, 'expired site role ignored (AppTime clock)');
$S->('UserSiteRole')->find(2)->update({ expires_at => undef });

# ---- token scope ----
my $tok = sub { $S->('ApiToken')->find(shift) };
ok(chk(user => $U{sec}, module => 'todo', action => 'read', sitename => 'Shanta', record => $T->(10), token => $tok->(2))->{ok}, 'narrow token: inside scope ok');
is(chk(user => $U{sec}, module => 'todo', action => 'update', sitename => 'Shanta', record => $T->(10), token => $tok->(2))->{code}, 'token_scope', 'narrow token: action outside scope 403 even though user may');
is(chk(user => $U{sec}, module => 'calendar', action => 'read', sitename => 'Shanta', token => $tok->(2))->{code}, 'token_scope', 'narrow token: module outside scope 403');
is(chk(user => $U{sec}, module => 'todo', action => 'delete', sitename => 'Shanta', record => $T->(10), token => $tok->(3))->{status}, 403, 'wide token cannot exceed the user (no delete row)');
is(chk(user => $U{sec}, module => 'todo', action => 'read', sitename => 'CSC', token => $tok->(3))->{status}, 403, 'wide token cannot add a site the user has no role on');
my $dev = { user_id => 5, username => 'devbot', roles => ['developer'] };
ok(chk(user => $dev, module => 'todo', action => 'update', sitename => 'Shanta', record => $S->('Todo')->create({ subject => 'dev own', sitename => 'Shanta', user_id => 5 }), token => $tok->(4))->{ok}, 'scoped developer token: own record ok');
is(chk(user => $dev, module => 'todo', action => 'update', sitename => 'Shanta', record => $T->(11), token => $tok->(4))->{code}, 'own_only', 'token own_only narrows even a developer');
is(chk(user => $dev, module => 'todo', action => 'update', sitename => 'CSC', token => $tok->(4))->{code}, 'token_scope', 'scoped developer token: other site 403');

# ---- through the controller ----
my %new = (subject => 'Sec todo', start_date => '2026-11-02', due_date => '2026-11-03', priority => 3, status => 2, project_id => 1,
           user_id => 1, username_of_poster => 'adminu');
my ($st, $j) = api('api_todo_create', token => $TOK{sec}, path => 'api/todo/create', body => \%new);
is($st, 200, 'API: secretary token creates todo on Shanta') or diag explain $j;
my $row = $S->('Todo')->find($j->{todo_id} // 0);
is($row && $row->user_id, 2, 'API: body user_id ignored');
is($row && $row->username_of_poster, 'shanta_secretary', 'API: body username_of_poster ignored');
is($row && $row->group_of_poster, 'secretary', 'API: group_of_poster = site role');
($st, $j) = api('api_todo_create', token => $TOK{sec}, path => 'api/todo/create', body => { %new, subject => 'CSC try', project_id => 2 });
is($st, 403, 'API: create on a site with no role -> 403 (_sitename_for_write)');
($st) = api('api_todo_create', token => $TOK{sec}, path => 'api/todo/create', body => { %new, subject => 'CSC try2', sitename => 'CSC' });
is($st, 403, 'API: explicit sitename without role -> 403');
is($S->('Todo')->search({ subject => { -like => 'CSC try%' } })->count, 0, '... nothing created');
($st) = api('api_todo_update', token => $TOK{sec}, path => 'api/todo/update', body => { record_id => 10, subject => 'Mine edited' });
is($st, 200, 'API: update own todo ok');
($st) = api('api_todo_update', token => $TOK{sec}, path => 'api/todo/update', body => { record_id => 11, subject => 'hijack' });
is($st, 403, 'API: update someone else\'s todo -> 403');
is($T->(11)->subject, 'Not mine', '... unchanged');
($st) = api('api_todo_update', token => $TOK{sec}, path => 'api/todo/update', body => { record_id => 10, sitename => 'CSC' });
is($st, 403, 'API: moving own todo to a site with no role -> 403');
($st) = api('api_todo_update', token => $TOK{sec_narrow}, path => 'api/todo/update', body => { record_id => 10, subject => 'x' });
is($st, 403, 'API: read-only scoped token cannot update');
($st) = api('api_todo_update', session => { username => 'shanta_secretary', user_id => 2, roles => ['user', 'secretary'] }, path => 'api/todo/update', body => { record_id => 10, subject => 'via session' });
is($st, 200, 'API: secretary session updates own todo');
($st) = api('api_todo_update', session => { username => 'adminu', user_id => 1, roles => ['admin'] }, path => 'api/todo/update', body => { record_id => 12, subject => 'admin edit' });
is($st, 200, 'API: admin session still passes (no lockout)');
ok(scalar(grep { /Access refused \(own_only\) user=shanta_secretary/ } @LOG), 'refusals are logged');

# ---- bot token scope fields ----
my $c = mk(session => { username => 'adminu', user_id => 1, roles => ['admin'] }, path => 'api/admin/bot_token',
           body => { username => 'editbot', scope_sites => 'Shanta', scope_modules => 'todo,calendar', scope_actions => 'read,update', own_only => 1 });
($st, $j) = call($ctrl, 'api_admin_bot_token', $c);
is($st, 200, 'bot_token: scoped mint ok') or diag explain $j;
is($j->{scope_actions}, 'read,update', 'bot_token: scope echoed');
my $minted = $S->('ApiToken')->find($j->{token_id});
is($minted->scope_modules, 'todo,calendar', 'bot_token: scope stored');
is($minted->own_only, 1, 'bot_token: own_only stored');
($st, $j) = call($ctrl, 'api_admin_bot_token', mk(session => { username => 'adminu', user_id => 1, roles => ['admin'] }, path => 'api/admin/bot_token',
           body => { username => 'editbot', scope_actions => 'read,destroy' }));
is($st, 400, 'bot_token: bad action refused');
($st, $j) = call($ctrl, 'api_admin_bot_tokens', mk(session => { username => 'adminu', user_id => 1, roles => ['admin'] }, method => 'GET', path => 'api/admin/bot_tokens'));
is($st, 200, 'bot_tokens: list ok');
my ($lt) = grep { $_->{id} == $minted->id } @{ $j->{tokens} || [] };
is($lt && $lt->{scope_sites}, 'Shanta', 'bot_tokens: shows scope');
ok(!grep({ exists $_->{token} || exists $_->{token_hash} } @{ $j->{tokens} || [] }), 'bot_tokens: never the token or its hash');

# ---- replacement routes for the removed Todo.pm api_* (Code Guard item 1) ----
sub apix {
    my ($m, $arg, %a) = @_;
    my $c = mk(%a);
    eval { $ctrl->$m($c, $arg); 1 } or do { die $@ unless ref $@ eq 'HASH' && $@->{detach} };
    my $b = $c->res->body; my $jj = (defined $b && length $b) ? (eval { decode_json($b) } || {}) : {};
    return ($c->res->status, $jj);
}
($st, $j) = apix('api_todo_update_by_id', 10, token => $TOK{sec}, method => 'PUT', path => 'api/todo/update/10', body => { priority => 2, subject => 'ignored' });
is($st, 200, 'PUT /api/todo/update/<id>: secretary own todo ok') or diag explain $j;
is($j->{todo}{priority}, 2, '... legacy response shape (todo.priority)');
ok(exists $j->{todo}{username_of_poster} && exists $j->{todo}{developer}, '... legacy keys kept');
($st) = apix('api_todo_update_by_id', 11, token => $TOK{sec}, method => 'PUT', path => 'api/todo/update/11', body => { priority => 1 });
is($st, 403, 'PUT /api/todo/update/<id>: others\' todo 403');
($st) = apix('api_todo_update_by_id', 11, address => '192.168.1.9', method => 'PUT', path => 'api/todo/update/11', body => { priority => 1 });
is($st, 200, 'PUT /api/todo/update/<id>: LAN bypass unchanged (Hermes skills)');
is($T->(11)->last_mod_by, 'system', '... LAN actor system as before');
($st, $j) = apix('api_todo_get', 10, token => $TOK{sec}, method => 'GET', path => 'api/todo/10');
is($st, 200, 'GET /api/todo/<id>: own ok'); is($j->{todo}{id}, 10, '... shape');
($st) = apix('api_todo_get', 12, token => $TOK{sec}, method => 'GET', path => 'api/todo/12');
is($st, 403, 'GET /api/todo/<id>: CSC todo (no site role) 403');
($st, $j) = apix('api_project_get', 1, token => $TOK{edit}, method => 'GET', path => 'api/project/1');
is($st, 403, 'GET /api/project/<id>: editor without project rows 403 (rbac on)');
($st, $j) = apix('api_project_get', 1, session => { username => 'adminu', user_id => 1, roles => ['admin'] }, method => 'GET', path => 'api/project/1');
is($st, 200, 'GET /api/project/<id>: admin ok'); is($j->{project}{name}, 'Shanta project', '... shape');

# ---- work log / work_status / rank through AccessCheck ----
for my $m (qw(api_todo_open_log api_todo_close_log api_todo_done_with_log)) {
    (my $path = $m) =~ s/^api_todo_/api\/todo\//;
    ($st) = api($m, token => $TOK{sec}, path => $path, body => { record_id => 11 });
    is($st, 403, "$m: others' todo 403 (stored record checked)");
    ($st) = api($m, token => $TOK{sec}, path => $path, body => { record_id => 12 });
    is($st, 403, "$m: other site's todo 403");
}
($st) = api('api_todo_work_status', token => $TOK{sec}, method => 'GET', path => 'api/todo/work_status', q => { record_id => 11 });
is($st, 403, 'work_status: others\' todo 403');
($st) = api('api_todo_work_status', token => $TOK{sec}, method => 'GET', path => 'api/todo/work_status', stash => { SiteName => 'Shanta' });
is($st, 403, 'work_status list: own_only caller needs record_id');
($st) = api('api_todo_rank', token => $TOK{sec}, path => 'api/todo/rank', body => { sitename => 'Shanta', model => 'm' });
is($st, 403, 'rank: own_only role refused');
($st) = api('api_todo_rank', token => $TOK{sec}, path => 'api/todo/rank', body => { sitename => 'CSC', model => 'm' });
is($st, 403, 'rank: other site refused');

# ---- web /todo own_only filter (Code Guard item 4) ----
{
    require Comserv::Controller::Todo;
    my $tc = bless { logging => Comserv::Util::Logging->instance }, 'Comserv::Controller::Todo';
    my $wc = FakeC->new(schema => $schema, session => { user_id => 2, username => 'shanta_secretary', roles => ['user', 'secretary'], SiteName => 'Shanta' },
                        stash => { SiteName => 'Shanta' });
    my $acc = $AC->check_session($wc, module => 'todo', action => 'read', legacy_roles => [qw(admin developer)]);
    ok($acc->{ok} && $acc->{own_only}, 'web read for secretary: ok with own_only');
    $wc->stash->{todo_access} = $acc;
    my @all = $S->('Todo')->search({ sitename => 'Shanta' })->all;
    my $f = $tc->_apply_user_filter($wc, \@all);
    ok(@all > @$f && @$f > 0, 'day/week/month filter drops others\' todos');
    ok(!grep({ !$AC->owns('todo', $_, { user_id => 2, username => 'shanta_secretary' }) } @$f), '... only own left');
    my @q = $S->('Todo')->search({ -and => [ { sitename => 'Shanta' }, $AC->own_where('todo', $tc->_own_only_user($wc)) ] })->all;
    is_deeply([sort map { $_->id } @q], [sort map { $_->id } @$f], '/todo list query (own_where) = same rule as owns()');
    my $ac2 = FakeC->new(schema => $schema, session => { user_id => 1, username => 'adminu', roles => ['admin'] }, stash => { SiteName => 'Shanta' });
    $ac2->stash->{todo_access} = $AC->check_session($ac2, module => 'todo', action => 'read');
    is(scalar @{ $tc->_apply_user_filter($ac2, \@all) }, scalar @all, 'admin list not filtered');
    # web JSON guard
    my $gc = FakeC->new(schema => $schema, session => { user_id => 2, username => 'shanta_secretary', roles => ['user'] }, stash => { SiteName => 'Shanta' });
    ok(!$tc->_web_todo_guard($gc, 11, 'update', [qw(admin developer editor devops)]), 'web open/close/done guard: others\' todo refused');
    is($gc->res->status, 403, '... 403');
    ok($tc->_web_todo_guard(FakeC->new(schema => $schema, session => { user_id => 2, username => 'shanta_secretary', roles => ['user'] }, stash => { SiteName => 'Shanta' }), 10, 'update', []), 'web guard: own todo ok');
}

# ---- api_tokens scope columns missing (before Schema Compare) ----
{
    package M::Schema; use base 'DBIx::Class::Schema';
    package main;
    require Comserv::Model::Schema::Ency::Result::ApiToken;
    M::Schema->register_class(ApiToken => 'Comserv::Model::Schema::Ency::Result::ApiToken');
    my $ms = M::Schema->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1, PrintError => 0 });
    # test fixture only (in-memory): the OLD api_tokens shape without scope columns
    $ms->storage->dbh->do('CREATE TABLE api_tokens (id INTEGER PRIMARY KEY, user_id INT, token_hash TEXT, token_name TEXT, is_active INT, created_at TEXT, expires_at TEXT, last_used_at TEXT, revoked_at TEXT)');
    $ms->storage->dbh->do(q{INSERT INTO api_tokens (id, user_id, token_hash, is_active, created_at) VALUES (1, 2, 'h-fake', 1, '2026-10-31 00:00:00')});
    my $tr = eval { $ms->resultset('ApiToken')->find({ token_hash => 'h-fake' }) };
    ok($tr, 'old table: token lookup still works (default columns)') or diag $@;
    my @w;
    my $sc = $AC->token_scope($ms, 1, sub { push @w, @_ });
    ok(!defined $sc, 'old table: scope unreadable -> unscoped');
    like($w[0] // '', qr/Schema Compare/, '... with a WARN');
    is_deeply($AC->token_scope($schema, 2), { scope_sites => 'Shanta', scope_modules => 'todo', scope_actions => 'read', own_only => undef }, 'new table: scope read');
}

# ---- round 3: single-record GETs need a session or token (no LAN) ----
($st) = apix('api_todo_get', 10, address => '192.168.1.9', method => 'GET', path => 'api/todo/10');
is($st, 401, 'GET /api/todo/<id>: tokenless LAN refused (401)');
($st) = apix('api_project_get', 1, address => '127.0.0.1', method => 'GET', path => 'api/project/1');
is($st, 401, 'GET /api/project/<id>: tokenless localhost refused (401)');
($st) = apix('api_todo_get', 10, address => '192.168.1.9', token => $TOK{sec}, method => 'GET', path => 'api/todo/10');
is($st, 200, 'GET /api/todo/<id>: LAN with token ok');
{
    no warnings 'redefine', 'once';
    local *Comserv::Util::TodoLog::work_status = sub { return { success => 1, count => 0 } };
    ($st) = api('api_todo_work_status', address => '192.168.1.9', method => 'GET', path => 'api/todo/work_status', q => { record_id => 10 });
    is($st, 200, 'work_status (pre-existing): tokenless LAN read kept for Hermes callers');
}

# ---- round 3: rank apply=1 refuses the whole apply if any stored todo fails ----
{
    $S->('RolePermission')->create({ role => 'editor', module => 'todo', action => $_, own_only => 0, sitename => 'Shanta' }) for qw(read update);
    package FakeRank;
    sub new { bless {}, shift } sub branch_context { {} } sub _sitename { 'Shanta' }
    sub gather_todos { return ([ { record_id => 10 }, { record_id => 12 } ], { 10 => 1, 12 => 1 }) }
    sub build_prompt { ('s', 'u') } sub run_batch { die "AI must not be called\n" }
    package main;
    no warnings 'redefine', 'once';
    my $orig = \&FakeC::model;
    local *FakeC::model = sub { $_[1] && $_[1] eq 'AI2::TodoRank' ? FakeRank->new : $orig->(@_) };
    ($st, $j) = api('api_todo_rank', token => $TOK{edit}, path => 'api/todo/rank', body => { apply => 1, model => 'm', sitename => 'Shanta' });
    is($st, 403, 'rank apply: a CSC todo in scope -> whole apply refused');
    is_deeply($j->{denied_record_ids}, ['12'], '... reports the refused record_ids');
    local *FakeRank::gather_todos = sub { return ([ { record_id => 10 } ], { 10 => 1 }) };
    local *FakeRank::parse_result = sub { { proposals => {} } };
    local *FakeRank::apply_proposals = sub { { changed => [] } };
    local *FakeRank::run_batch = sub { { success => 1 } };
    ($st) = api('api_todo_rank', token => $TOK{edit}, path => 'api/todo/rank', body => { apply => 1, model => 'm', sitename => 'Shanta' });
    is($st, 200, 'rank apply: all stored todos allowed -> runs');
}

# ---- round 3: web todo actions check the stored record ----
{
    no warnings 'redefine', 'once';
    *FakeRes::redirect = sub { $_[0]{location} = $_[1] };
    *FakeC::flash = sub { $_[0]{flash} ||= {} };
    *FakeC::uri_for = sub { $_[1] };
    require Comserv::Controller::Todo;
    my $tc = bless { logging => Comserv::Util::Logging->instance }, 'Comserv::Controller::Todo';
    my $sec = sub { FakeC->new(schema => $schema, session => { user_id => 2, username => 'shanta_secretary', roles => ['user', 'secretary'], SiteName => 'Shanta' },
                               stash => { SiteName => 'Shanta' }, req => { method => 'POST', @_ }) };
    my $run = sub { my ($m, $c, @a) = @_; eval { $tc->$m($c, @a); 1 } or do { die $@ unless ref $@ eq 'HASH' && $@->{detach} }; $c };
    for my $m (qw(update_time update_recurring_time update_status update_priority update_time_and_date update_display_date)) {
        my $c = $run->($m, $sec->(q => { record_id => 11, time_of_day => '09:00', status => 3, priority => 1, start_date => '2026-11-01', display_date => '2026-11-01' }));
        is($c->res->status, 403, "web $m: others' todo -> JSON 403");
        like($c->res->body // '', qr/"success":0/, "... JSON body");
    }
    for my $m (qw(quick_priority next_step)) {
        my $c = $run->($m, $sec->(json => encode_json({ record_id => 12, priority => 1 })));
        is($c->res->status, 403, "web $m: other site's todo -> 403");
    }
    my $c = $run->('reschedule', $sec->());
    is($c->res->status, 403, 'web reschedule: own_only/non-admin refused');
    for my $m (qw(edit modify)) {
        $c = $run->($m, $sec->(), 11);
        is($c->res->{location}, '/todo/details?record_id=11', "web $m: others' todo redirected");
        ok($c->flash->{error_msg}, '... with a message');
    }
    $c = $run->('details', $sec->(q => { record_id => 12 }));
    is($c->res->{location}, '/todo', 'web details: CSC todo (stored site) redirected');
    $c = $run->('create', $sec->(q => { subject => 'x', start_date => '2026-11-01', due_date => '2026-11-02', priority => 3, status => 1, sitename => 'CSC' }));
    is($c->res->{location}, '/todo', 'web create on a site with no role -> refused');
    is($S->('Todo')->search({ subject => 'x' })->count, 0, '... nothing created');
    my $csc = FakeC->new(schema => $schema, session => { user_id => 2, username => 'shanta_secretary', roles => ['user'], SiteName => 'CSC' }, stash => { SiteName => 'CSC' });
    $c = $run->('addtodo', $csc);
    is($c->res->{location}, '/todo', 'web addtodo on a site with no role -> refused');
    my $adm = FakeC->new(schema => $schema, session => { user_id => 1, username => 'adminu', roles => ['admin'] }, stash => { SiteName => 'Shanta' });
    ok($tc->_web_todo_guard($adm, 11, 'update', ['*']), 'admin passes the web guard');
}

# ---- round 3: token scope read fails CLOSED except "column missing" ----
{
    package FailSchema; sub new { bless {}, shift } sub resultset { bless {}, 'FailRS' }
    package FailRS; sub search { die "DBI Exception: MySQL server has gone away\n" }
    package main;
    my @w;
    my $sc = $AC->token_scope(FailSchema->new, 1, sub { push @w, @_ });
    ok($sc && $sc->{_scope_error}, 'other DB error -> scope error marker');
    like($w[0] // '', qr/fail closed/, '... WARN says fail closed');
    is(chk(user => $U{admin}, module => 'todo', action => 'read', sitename => 'Shanta', token => $sc)->{code}, 'token_scope_error', '... token refused (403), even for admin');
}

# ---- round 4: menu / admin index links, triage_stale, debug ----
SKIP: {
    eval { require Template; 1 } or skip 'Template not installed', 5;
    my $tt = Template->new(INCLUDE_PATH => "$FindBin::Bin/../root");
    my $render = sub {
        my ($file, $global) = @_;
        my $stash = { is_global_admin => $global, is_admin => 1, dbi => bless({}, 'StubDBI') };
        my $c = { stash => $stash, session => { username => 'adminu', roles => ['admin'], SiteName => 'CSC' } };
        { no strict 'refs'; *{'StubDBI::query'} = sub { [] }; *{'StubC::uri_for'} = sub { $_[1] };
          *{'StubC::stash'} = sub { $_[0]{stash} }; *{'StubC::session'} = sub { $_[0]{session} }; }
        bless $c, 'StubC';
        my $out = '';
        $tt->process($file, { c => $c, is_admin => 1, SiteName => 'CSC' }, \$out) or return 'ERR: ' . $tt->error;
        return $out;
    };
    my $on  = $render->('Navigation/admintopmenu.tt', 1);
    my $off = $render->('Navigation/admintopmenu.tt', 0);
    unlike($on, qr/^ERR/, 'admintopmenu renders') or diag $on;
    my $n = () = $on =~ m{href="/admin/role_permissions"}g;
    is($n, 3, 'global admin: Role Permissions in Admin, Site Management and User Management submenus');
    unlike($off, qr{/admin/role_permissions}, 'site admin (not global): no Role Permissions link');
    my $src = do { local (@ARGV, $/) = "$FindBin::Bin/../root/admin/index.tt"; <> };
    like($src, qr{IF c\.stash\.is_global_admin %\]\s*<a href="\[% c\.uri_for\('/admin/users'\) %\]" class="admin-link">.*?/admin/role_permissions}s,
        'admin index: Role Permissions card link next to User Administration, global admins only');
    my $root = do { local (@ARGV, $/) = "$FindBin::Bin/../lib/Comserv/Controller/Root.pm"; <> };
    like($root, qr/is_global_admin\}\s*=\s*eval \{\s*require Comserv::Util::AccessCheck;\s*Comserv::Util::AccessCheck->is_global_admin/s, 'Root sets is_global_admin from stored roles');
}
{
    require Comserv::Controller::Todo;
    my $tc = bless { logging => Comserv::Util::Logging->instance }, 'Comserv::Controller::Todo';
    my $mk2 = sub { FakeC->new(schema => $schema, session => { @_ }, req => { method => 'POST' }) };
    my $c = $mk2->(user_id => 7, username => 'siteadm', roles => ['admin']);
    eval { $tc->triage_stale($c); 1 };
    is($c->res->status, 403, 'triage_stale: site admin with session admin refused (stored roles)');
    local $ENV{CATALYST_ENV} = 'production';
    $c = $mk2->(user_id => 1, username => 'adminu', roles => ['admin']);
    $tc->debug($c);
    is($c->res->status, 404, 'todo/debug: 404 outside development');
    $ENV{CATALYST_ENV} = 'development';
    $c = $mk2->(user_id => 7, username => 'siteadm', roles => ['admin']);
    $tc->debug($c);
    is($c->res->status, 404, 'todo/debug: 404 for non-global admin even in development');
    $c = $mk2->(user_id => 1, username => 'adminu', roles => ['user']);
    $tc->debug($c);
    is($c->res->status, 200, 'todo/debug: global admin in development ok');
}

# ---- recurrence validator + normalise_scope unit checks ----
is_deeply([Comserv::Controller::Api::_api_validate_recurrence({ recurrence_rule => 'RRULE:FREQ=DAILY;INTERVAL=2' })], [], 'RRULE: prefix accepted');
is(scalar(Comserv::Controller::Api::_api_validate_recurrence({ creator_timezone => '../etc/passwd' })), 1, 'tz path-like refused');
is(($AC->normalise_scope(' Shanta , CSC ', 'scope_sites'))[0], 'Shanta,CSC', 'normalise_scope trims');
is(($AC->owns('project', { username_of_poster => 'Bob' }, { username => 'bob' })), 1, 'project ownership by poster');

done_testing();
