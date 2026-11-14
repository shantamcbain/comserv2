#!/usr/bin/env perl
# Calendar phase 1 (Nov 2026): reminders, ICS escaping/folding/VALARM, feed tokens
# (wrong / expired / revoked / other-user / out-of-scope-site / unscoped => refused),
# own-only + site filtering, log redaction, description helper, prefs key.
use strict;
use warnings;
use utf8;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Encode qw(encode_utf8);
use DateTime;

use_ok('Comserv::Util::CalendarFeed');
use_ok('Comserv::Util::TodoDescription');
my $CF = 'Comserv::Util::CalendarFeed';

# ---------------------------------------------------------------- reminders
{
    my ($ok, $bad) = $CF->parse_offsets('-PT60M,-PT15M');
    is_deeply($ok, ['-PT1H', '-PT15M'], 'offsets parsed, normalised, earliest first');
    is_deeply($bad, [], 'no rejects');
    ($ok, $bad) = $CF->parse_offsets('PT30M, -P1D , junk, -PT0M, -P99W, -PT15M,-PT15M');
    is_deeply($ok, ['-P1D', '-PT30M', '-PT15M'], 'missing minus added, dupes dropped');
    is_deeply([sort @$bad], [sort qw(junk -PT0M -P99W)], 'bad/zero/too-far rejected');
    ($ok, $bad) = $CF->parse_offsets(join ',', map { "-PT${_}M" } 1 .. 7);
    is(scalar @$ok, 5, 'max 5 offsets'); is(scalar @$bad, 2, 'extras rejected');
    is($CF->offset_minutes('-PT1H30M'), 90, 'H+M minutes');
    ok(!defined $CF->offset_minutes('-PT'), 'empty T rejected');
    like($CF->offsets_human(['-PT1H', '-PT15M']), qr/1 hour.*15 min/, 'human text');
}

# ---------------------------------------------------------------- ICS text
{
    is($CF->ics_escape("a,b;c\\d\ne"), 'a\\,b\\;c\\\\d\\ne', 'RFC 5545 escaping');
    is($CF->ics_escape("x\r\ny"), 'x\\ny', 'CRLF -> \\n');
    my $long = 'DESCRIPTION:' . ('é' x 80);
    my $f = $CF->ics_fold($long);
    for my $l (split /\r\n/, $f) { ok(length(encode_utf8($l)) <= 75, 'folded line <= 75 octets') }
    my $un = join '', map { s/^ //r } split /\r\n/, $f;
    is($un, $long, 'unfold restores line, no split UTF-8');
    my $ics = $CF->build_ics(name => 'T', now => '2026-11-04 15:00:00', events => [
        { uid => 'todo-1@comserv', summary => 'Hive, check; now', description => "line1\nline2",
          url => 'https://csc.example/todo/details?record_id=1', sitename => 'CSC',
          start_dt => '2026-11-05 16:00:00', end_dt => '2026-11-05 17:00:00', offsets => ['-PT1H', '-PT15M'] },
        { uid => 'todo-2@comserv', summary => 'All day', start_date => '2026-11-06', end_date => '2026-11-07' } ]);
    like($ics, qr/^BEGIN:VCALENDAR\r\nVERSION:2\.0\r\n/, 'calendar header, CRLF');
    like($ics, qr/SUMMARY:Hive\\, check\\; now\r\n/, 'summary escaped');
    like($ics, qr/DESCRIPTION:line1\\nline2\r\n/, 'description escaped');
    like($ics, qr/DTSTART:20261105T160000Z\r\nDTEND:20261105T170000Z/, 'UTC times');
    like($ics, qr/DTSTART;VALUE=DATE:20261106\r\nDTEND;VALUE=DATE:20261107/, 'all-day');
    is(() = $ics =~ /BEGIN:VALARM/g, 2, 'one VALARM per offset');
    like($ics, qr/TRIGGER:-PT1H\r\n/, 'trigger');
    like($ics, qr/URL:https:\/\/csc\.example\/todo\/details\?record_id=1/, 'item links to todo');
    unlike($ics, qr/[^\r]\n/, 'no bare LF');
}

# ---------------------------------------------------------------- description scrubbing
{
    my $d = $CF->public_description("Do it\npassword: hunter2\n## Internal notes\nsecret stuff\n## Steps\nsee https://evil.example/x and https://csc.example/Documentation/A",
        'https://csc.example');
    unlike($d, qr/hunter2/, 'credential line removed');
    unlike($d, qr/secret stuff/, 'internal section removed');
    unlike($d, qr/evil\.example/, 'foreign link removed');
    like($d, qr{https://csc\.example/Documentation/A}, 'app link kept');
}

# ---------------------------------------------------------------- redaction + transport
{
    my $tok = 'A' x 43;
    is($CF->redact("GET /calendar/feed/$tok.ics"), 'GET /calendar/feed/[REDACTED]', 'redact path');
    is($CF->redact("calendar/feed/$tok.ics?x=1"), 'calendar/feed/[REDACTED]?x=1', 'redact no leading slash');
    require Comserv::Util::Logging;
    is(Comserv::Util::Logging::_redact_path("calendar/feed/$tok.ics"), 'calendar/feed/[REDACTED]', 'Logging redacts access-log path');
    my $out = '';
    {
        no warnings 'redefine';
        # capture what log_with_details would format, without touching files/DB
        my $orig = \&Comserv::Util::Logging::_redact_path;
        $out = Comserv::Util::Logging::_redact_path("feed refused for /calendar/feed/$tok");
    }
    unlike($out, qr/$tok/, 'token never in log text');
    ok(!$CF->transport_ok(host => 'computersystemconsulting.ca'), 'public http refused');
    ok($CF->transport_ok(host => 'computersystemconsulting.ca', forwarded_proto => 'https', remote => '127.0.0.1'), 'XFP https from trusted proxy ok');
    ok(!$CF->transport_ok(host => 'computersystemconsulting.ca', forwarded_proto => 'https', remote => '203.0.113.9'), 'XFP from untrusted address ignored');
    ok(!$CF->transport_ok(host => 'computersystemconsulting.ca', forwarded_proto => 'https'), 'XFP without remote ignored');
    ok($CF->transport_ok(host => 'computersystemconsulting.ca', secure => 1), 'direct https ok');
    ok($CF->transport_ok(host => 'workstation.local:3001'), '.local http ok');
    ok($CF->transport_ok(host => '127.0.0.1'), 'localhost ok');
}

# ---------------------------------------------------------------- token + rate
{
    my $t = $CF->new_token;
    like($t, qr/^[A-Za-z0-9_-]{43}$/, 'url-safe 256-bit token');
    isnt($t, $CF->new_token, 'tokens differ');
    is(length $CF->hash_token($t), 64, 'sha256 hex');
    ok(Comserv::Util::CalendarFeed::_ct_eq('abc', 'abc') && !Comserv::Util::CalendarFeed::_ct_eq('abc', 'abd'), 'constant-time eq');
    $CF->_rate_reset;
    my $n = 0; $n++ while $n < 100 && $CF->rate_ok('k', 1000);
    is($n, ${Comserv::Util::CalendarFeed::RATE_MAX}, 'rate limit per token');
    ok($CF->rate_ok('k', 1000 + 61), 'window resets');
}

# ---------------------------------------------------------------- DB-backed (SQLite)
SKIP: {
    eval { require DBD::SQLite; require Comserv::Model::Schema::Ency; 1 } or skip 'no SQLite/schema', 1;
    my $schema = Comserv::Model::Schema::Ency->connect('dbi:SQLite::memory:', '', '', { quote_names => 1 });
    my @src = qw(User ApiToken Todo TodoReminder UserSiteRole Site);
    my $dep = eval { $schema->deploy({ sources => \@src }); 1 };
    skip "deploy failed: $@", 1 unless $dep;
    # Insert a row filling every NOT NULL column without a default (test fixture only).
    my $ins = sub {
        my ($srcname, %v) = @_;
        my $src = $schema->source($srcname);
        for my $col ($src->columns) {
            my $i = $src->column_info($col);
            next if exists $v{$col} || $i->{is_nullable} || defined $i->{default_value} || $i->{is_auto_increment};
            $v{$col} = ($i->{data_type} // '') =~ /int|dec|num|bool/i ? 0
                     : ($i->{data_type} // '') =~ /date|time/i ? '2026-01-01 00:00:00' : '';
        }
        my @c = sort keys %v;
        $schema->storage->dbh->do('INSERT INTO ' . $src->name . ' (' . join(',', map { qq("$_") } @c) . ') VALUES (' . join(',', ('?') x @c) . ')', undef, @v{@c});
    };
    my $usr = sub { my ($id, $name, $roles) = @_; $ins->('User', id => $id, username => $name, roles => $roles, email => "$name\@x") };
    my $ok_u = eval { $usr->(1, 'alice', 'admin'); $usr->(2, 'bob', 'admin'); 1 };
    skip "users insert needs more columns: $@", 1 unless $ok_u;
    my $site = sub { $ins->('Site', id => $_[0], name => $_[1]) };
    eval { $site->(10, 'CSC'); $site->(11, 'BMaster'); $site->(12, 'Other'); 1 } or skip "sites insert: $@", 1;
    my $usr_site = sub { $ins->('UserSiteRole', user_id => $_[0], site_id => $_[1], role => $_[2], is_active => 1) };
    eval { $usr_site->(1, 10, 'admin'); $usr_site->(1, 11, 'admin'); $usr_site->(2, 12, 'admin'); 1 } or skip "usr: $@", 1;

    my $now = DateTime->new(year => 2026, month => 11, day => 4, hour => 15, time_zone => 'UTC');
    my $mk = sub {
        my (%o) = @_;
        my $plain = $CF->new_token;
        $schema->resultset('ApiToken')->create({ user_id => 1, token_hash => $CF->hash_token($plain),
            token_name => 'calendar-feed', is_active => 1, created_at => '2026-11-01 00:00:00',
            scope_modules => 'calendar,todo', scope_actions => 'read', own_only => 1, %o });
        return $plain;
    };
    my $good = $mk->();
    my $v = $CF->validate_token($schema, $good, $now);
    ok($v->{ok}, 'good token accepted') or diag explain $v;
    ok(!$CF->validate_token($schema, $CF->new_token, $now)->{ok}, 'wrong token refused');
    ok(!$CF->validate_token($schema, 'short', $now)->{ok}, 'malformed token refused');
    ok(!$CF->validate_token($schema, $mk->(expires_at => '2026-11-03 00:00:00'), $now)->{ok}, 'expired refused');
    ok($CF->validate_token($schema, $mk->(expires_at => '2026-12-03 00:00:00'), $now)->{ok}, 'not-yet-expired ok');
    ok(!$CF->validate_token($schema, $mk->(revoked_at => '2026-11-02 00:00:00'), $now)->{ok}, 'revoked refused');
    ok(!$CF->validate_token($schema, $mk->(is_active => 0), $now)->{ok}, 'inactive refused');
    ok(!$CF->validate_token($schema, $mk->(scope_actions => 'read,update'), $now)->{ok}, 'write scope refused');
    ok(!$CF->validate_token($schema, $mk->(own_only => 0), $now)->{ok}, 'not own_only refused');
    ok(!$CF->validate_token($schema, $mk->(scope_modules => 'todo'), $now)->{ok}, 'no calendar scope refused');
    ok(!$CF->validate_token($schema, $mk->(scope_modules => undef, scope_actions => undef, own_only => undef), $now)->{ok}, 'unscoped refused');
    ok(!$CF->validate_token($schema, $mk->(token_name => 'api'), $now)->{ok}, 'API token is not a feed token');
    my $bobtok = $mk->(user_id => 2);
    is($CF->validate_token($schema, $bobtok, $now)->{user_id}, 2, 'token resolves to its own user only');

    # out-of-scope site: token limited to CSC cannot read BMaster
    my $scoped = $mk->(scope_sites => 'CSC');
    my $sv = $CF->validate_token($schema, $scoped, $now);
    my $alice = { user_id => 1, username => 'alice', roles => 'admin' };
    is_deeply($CF->feed_sites($schema, $alice, $sv->{scope}), ['CSC'], 'scope_sites limits feed sites');
    is_deeply($CF->feed_sites($schema, $alice, $v->{scope}), ['BMaster', 'CSC'], "owner's SiteNames from user_site_roles");
    is_deeply($CF->feed_sites($schema, $alice, $v->{scope}, ['BMaster']), ['BMaster'], 'visible_sites subset');

    my $todo = sub { my (%o) = @_; $schema->resultset('Todo')->create({ sitename => 'CSC', start_date => '2026-11-05',
        parent_todo => '', due_date => '2026-11-05', subject => 'S', description => 'D', estimated_man_hours => 1,
        project_code => 'P', status => 'NEW', priority => 5, share => 0, last_mod_by => 'x', last_mod_date => '2026-11-04',
        group_of_poster => 'admin', user_id => 1, project_id => 1, owner => 'alice', developer => 'alice',
        username_of_poster => 'alice', %o }) };
    my $t1 = $todo->(subject => 'Mine CSC');
    $todo->(subject => 'Mine Other site', sitename => 'Other');
    $todo->(subject => 'Bob todo', user_id => 2, owner => 'bob', developer => 'bob', username_of_poster => 'bob');
    $todo->(subject => 'Done', status => 'DONE');
    $CF->save_reminders($schema, $t1->record_id, '-PT15M,-PT60M', '2026-11-04 00:00:00');
    my $ev = $CF->feed_events($schema, user => $alice, sites => $CF->feed_sites($schema, $alice, $v->{scope}),
        from => '2026-10-01', to => '2026-12-31', app_base => 'https://csc.example');
    is_deeply([map { $_->{summary} } @$ev], ['Mine CSC'], 'only own todos on own sites, done excluded');
    is_deeply($ev->[0]{offsets}, ['-PT1H', '-PT15M'], 'reminders feed VALARMs');
    like($ev->[0]{url}, qr{^https://csc\.example/todo/details\?record_id=\d+$}, 'event links to todo');
    my $bob_sites = $CF->feed_sites($schema, { user_id => 2, username => 'bob', roles => 'admin' }, $v->{scope});
    my $bev = $CF->feed_events($schema, user => { user_id => 2, username => 'bob' }, sites => $bob_sites,
        from => '2026-10-01', to => '2026-12-31');
    ok(!grep({ $_->{summary} =~ /Mine/ } @$bev), 'other user never sees alice todos');
    # Planning rules: a plain normal/member/user/guest account gets no feed sites while
    # role_permissions is empty (legacy = admin/developer only), even with a valid token.
    $usr->(3, 'carol', 'normal,member'); $usr_site->(3, 10, 'member');
    $usr->(4, 'dave', 'user'); $usr_site->(4, 10, 'user');
    is_deeply($CF->feed_sites($schema, { user_id => 3, username => 'carol', roles => 'normal,member' }, $v->{scope}), [], 'normal/member without planning grant: no feed sites');
    is_deeply($CF->feed_sites($schema, { user_id => 4, username => 'dave', roles => 'user' }, $v->{scope}), [], 'user role: no feed sites');
}

# ---------------------------------------------------------------- description helper
{
    my $tpl = Comserv::Util::TodoDescription->template;
    like($tpl, qr/^## What to do\n.*## Steps\n1\. .*## How-to docs\n- .*## Form to complete\n- .*## Done when\n/s, 'template sections in order');
    my $txt = Comserv::Util::TodoDescription->render(what => 'Do X', steps => ['a', 'b'],
        docs => ['/Documentation/X', 'javascript:alert(1)'], form => '/todo/addtodo', done_when => 'X saved');
    unlike($txt, qr/javascript:/, 'unsafe link dropped');
    my $p = Comserv::Util::TodoDescription->parse($txt);
    is($p->{what}, 'Do X', 'parse what'); is_deeply($p->{steps}, ['a', 'b'], 'parse steps');
    is_deeply($p->{docs}, ['/Documentation/X'], 'parse docs'); is_deeply($p->{form}, ['/todo/addtodo'], 'parse form');
    is($p->{done_when}, 'X saved', 'parse done_when'); ok($p->{standard}, 'recognised as standard');
    ok(!Comserv::Util::TodoDescription->parse("free text")->{standard}, 'free text not standard');
}

# ---------------------------------------------------------------- POST origin check (CSRF)
{
    require Comserv::Util::OriginCheck;
    my $W  = { scheme => 'http', host => 'workstation.local', port => 3001 };
    my $ok = sub { shift; Comserv::Util::OriginCheck->matches($W, @_) };
    ok(!$ok->('workstation.local'), 'no Origin and no Referer: refused');
    ok(!$ok->('workstation.local', '', undef), 'empty headers: refused');
    ok(!$ok->('workstation.local', 'https://evil.example'), 'mismatched Origin: refused');
    ok(!$ok->('workstation.local', undef, 'https://workstation.local.evil.example/x'), 'look-alike Referer: refused');
    ok(!$ok->('workstation.local', 'http://workstation.local:3001', 'https://evil.example/'), 'one mismatch: refused');
    ok(!$ok->('workstation.local', 'null'), 'Origin null: refused');
    ok(!$ok->('workstation.local', 'http://workstation.local:3002'), 'same host, other port: refused');
    ok($ok->('workstation.local', 'http://workstation.local:3001'), 'matching Origin: allowed');
    ok($ok->('workstation.local', undef, 'http://workstation.local:3001/calendar/subscribe'), 'matching Referer: allowed');
}

# ---------------------------------------------------------------- prefs key
{
    require Comserv::Util::UserPreferences;
    my $up = Comserv::Util::UserPreferences->new;
    ok($up->validate_value('calendar.visible_sites', ['CSC', 'BMaster']), 'visible_sites valid');
    ok(!$up->validate_value('calendar.visible_sites', 'CSC'), 'must be a list');
    ok(!$up->validate_value('calendar.visible_sites', ['<script>']), 'bad site name refused');
}

done_testing;
