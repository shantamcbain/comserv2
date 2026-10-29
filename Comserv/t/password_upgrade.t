#!/usr/bin/env perl
# Password hashing + failed-login throttle:
#   * legacy SHA-256 hashes still log in and are upgraded to PBKDF2 once; wrong passwords never upgrade
#   * new / changed passwords are PBKDF2 (no path writes SHA-256)
#   * lockout: 5 failures per IP+account / 15 min (block, expires), other IPs unaffected, success clears,
#     per-account (all IPs) = soft delay only, per-IP spray block, registration 5/h, admin never permanently locked
#   * logs / throttle rows never contain passwords or hashes
# In-memory SQLite + fake $c + fake clock. Every password here is FAKE; no network, no real DB.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Digest::SHA qw(sha256_hex);

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
use Comserv::Util::ClientIP;
use Comserv::Controller::User;

# The real work factor is 100,000 iterations (~0.4 s per hash in pure Perl). The bulk of this file
# runs dozens of logins, so it uses a low work factor; sections 11-12 switch back to the real one.
my $REAL_ITER = $Comserv::Util::PasswordHash::ITERATIONS;
$Comserv::Util::PasswordHash::ITERATIONS = 1_000;

my @LOG;
{
    no warnings 'redefine';
    *Comserv::Util::Logging::log_with_details = sub { my ($s, $c, $lvl, $f, $l, $sub, $msg) = @_; push @LOG, "[$lvl] $sub: " . ($msg // ''); 1 };
}

{
    package T::Schema; use base 'DBIx::Class::Schema';
}
T::Schema->register_class(User      => 'Comserv::Model::Schema::Ency::Result::User');
T::Schema->register_class(SystemLog => 'Comserv::Model::Schema::Ency::Result::SystemLog');
my $schema = T::Schema->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1, sqlite_unicode => 1 });
{ local $SIG{__WARN__} = sub { warn @_ unless $_[0] =~ /Ignoring relationship/ }; $schema->deploy; }

# ---- fake users (legacy SHA-256 hashes of FAKE passwords) -----------------------
my %PW = (alice => 'fake-Alice-pass-1', adminu => 'fake-Admin-pass-2', newbie => 'fake-Newbie-pass-3', unic => "fake-p\x{e9}ss-4");
my $legacy = sub { sha256_hex($_[0]) };
$schema->resultset('User')->populate([
    [qw(username password email roles status)],
    ['alice',  $legacy->($PW{alice}),  'alice@x.test',  'normal', 'active'],
    ['adminu', $legacy->($PW{adminu}), 'admin@x.test',  'admin',  'active'],
    ['unic',   $legacy->($PW{unic}),   'unic@x.test',   'normal', 'active'],
]);

# ---- 1. PasswordHash unit tests -------------------------------------------------
my $PH = 'Comserv::Util::PasswordHash';
my $h  = $PH->hash($PW{newbie});
like($h, qr/^\{X-PBKDF2\}/, 'hash() produces PBKDF2 format');
ok($PH->verify($h, $PW{newbie}), 'PBKDF2 verifies right password');
ok(!$PH->verify($h, 'wrong'), 'PBKDF2 rejects wrong password');
ok($PH->verify($legacy->('x-fake-pw'), 'x-fake-pw'), 'legacy SHA-256 verifies');
ok(!$PH->verify($legacy->('x-fake-pw'), 'x-fake-pw2'), 'legacy rejects wrong password');
ok(!$PH->verify($legacy->('x-fake-pw'), ''), 'empty password rejected');
ok(!$PH->verify('', 'x'), 'empty stored hash rejected');
ok(!$PH->verify(undef, 'x'), 'undef stored hash rejected');
ok(!$PH->verify('plaintext-not-a-hash', 'plaintext-not-a-hash'), 'unknown stored format never matches');
ok($PH->needs_upgrade($legacy->('a')), 'legacy needs upgrade');
ok(!$PH->needs_upgrade($h), 'PBKDF2 does not need upgrade');
ok(!$PH->needs_upgrade('garbage'), 'garbage is not upgraded');
isnt($PH->hash($PW{newbie}), $h, 'salted: two hashes of one password differ');
ok($PH->verify($legacy->($PW{unic}), $PW{unic}), 'legacy hash of a latin-1 character password still verifies');

# ---- 2. Result::User->check_password -------------------------------------------
my $alice = $schema->resultset('User')->find({ username => 'alice' });
ok($alice->check_password($PW{alice}), 'Result::User accepts legacy hash');
ok(!$alice->check_password('nope'), 'Result::User rejects wrong password');
ok(!$alice->check_password(''), 'Result::User rejects empty password');
is($alice->password, $legacy->($PW{alice}), 'check_password never writes');

# ---- fake Catalyst context ------------------------------------------------------
{
    package FakeReq;
    sub new { my ($c, %a) = @_; bless { address => '198.51.100.1', method => 'POST', params => {}, %a }, $c }
    sub address { $_[0]{address} } sub method { $_[0]{method} }
    sub body_parameters { $_[0]{params} } sub params { $_[0]{params} }
    sub param { my ($s, $k) = @_; $s->{params}{$k} }
    sub uri { 'http://test.invalid/user/do_login' }
    sub referer { '' }
    sub header { my ($s, $k) = @_; $s->{headers}{lc $k} }
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
    sub change_session_id { 1 } sub uri_for { "http://test.invalid$_[1]" }
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
        return FakeEmptyRS->new;      # Site / UserSiteRole etc.: nothing
    }
    package FakeEmptyRS;
    sub new { bless {}, shift } sub search { $_[0] } sub single { undef } sub count { 0 } sub all { () } sub first { undef }
}

my $ctrl = do { local $SIG{__WARN__} = sub { warn @_ unless $_[0] =~ /uninitialized value \$app/ }; Comserv::Controller::User->new };
my $T = 1_800_000_000;                     # fake clock
my @SLEPT;
my $store = Comserv::Util::LoginThrottle::MemoryStore->new;
my $thr   = Comserv::Util::LoginThrottle->new(store => $store, clock => sub { $T }, sleeper => sub { push @SLEPT, $_[0] });

sub login {
    my (%a) = @_;
    my $c = FakeCtx->new(
        schema => $schema, model => FakeModel->new($schema),
        req    => FakeReq->new(address => $a{ip} || '198.51.100.1', params => { username => $a{user}, password => $a{pass} }),
    );
    $c->{stash}{login_throttle} = $a{throttle} || $thr;
    @LOG = () unless $a{keep_log};
    $ctrl->do_login($c);
    my $ok = ($c->session->{user_id} && $c->res->status != 429) ? 1 : 0;
    return { ok => $ok, status => $c->res->status, c => $c, retry => $c->res->header('Retry-After') };
}
sub stored { $schema->resultset('User')->find({ username => $_[0] })->password }

# ---- 3. login path: legacy accepted once and upgraded ---------------------------
my $r = login(user => 'alice', pass => 'fake-WRONG');
ok(!$r->{ok}, 'wrong password rejected');
is(stored('alice'), $legacy->($PW{alice}), 'wrong password does NOT upgrade / change the stored hash');

$r = login(user => 'alice', pass => $PW{alice});
ok($r->{ok}, 'legacy SHA-256 user logs in');
like(stored('alice'), qr/^\{X-PBKDF2\}/, 'hash upgraded to PBKDF2 at login');
unlike(stored('alice'), qr/^[0-9a-f]{64}$/, 'stored value is no longer a bare SHA-256');
my $first = stored('alice');
$r = login(user => 'alice', pass => $PW{alice});
ok($r->{ok}, 'upgraded account still logs in');
is(stored('alice'), $first, 'PBKDF2 hash is not re-written on later logins');
$r = login(user => 'alice', pass => 'fake-WRONG');
ok(!$r->{ok}, 'wrong password still rejected after upgrade');
is(stored('alice'), $first, 'hash unchanged after failure');

$r = login(user => 'unic', pass => $PW{unic});
ok($r->{ok}, 'latin-1 character password logs in through the controller');

# ---- 4. every password writer uses PBKDF2 ---------------------------------------
like($ctrl->hash_password('fake-new-password-9'), qr/^\{X-PBKDF2\}/, 'Controller::User->hash_password is PBKDF2');
{
    my $src = do { local (@ARGV, $/) = ("$FindBin::Bin/../lib/Comserv/Controller/User.pm"); <> };
    my @bad = $src =~ /(password\s*=>\s*sha256_hex\([^)]*\)|\$hashed_password\s*=\s*sha256_hex)/g;
    is(scalar(@bad), 0, 'Controller::User never writes a SHA-256 password hash');
    my $hy  = do { local (@ARGV, $/) = ("$FindBin::Bin/../lib/Comserv/Model/HybridDB.pm"); <> };
    unlike($hy, qr/sha256_hex\(\$password\)/, 'HybridDB no longer compares SHA-256 directly');
}

# ---- 5. lockout: per IP + account ------------------------------------------------
$T += 10_000;                              # fresh window
my $A = '203.0.113.10'; my $B = '203.0.113.20';
login(user => 'adminu', pass => 'fake-bad-' . $_, ip => $A) for 1 .. 4;
$r = login(user => 'adminu', pass => $PW{adminu}, ip => $A);
ok($r->{ok}, '4 failures: correct password still works (limit is 5)');
# success cleared the counter for A+adminu
login(user => 'adminu', pass => 'fake-bad-x', ip => $A) for 1 .. 4;
$r = login(user => 'adminu', pass => $PW{adminu}, ip => $A);
ok($r->{ok}, 'success clears the IP+account counter (4 more failures are fine)');

$T += 5000;
login(user => 'adminu', pass => 'fake-bad-' . $_, ip => $A) for 1 .. 5;
$r = login(user => 'adminu', pass => $PW{adminu}, ip => $A, keep_log => 0);
is($r->{status}, 429, '5 failures: that IP+account is blocked (HTTP 429)');
ok(!$r->{ok}, 'blocked even with the correct password');
ok($r->{retry} && $r->{retry} <= 900 && $r->{retry} >= 1, 'Retry-After is within 15 minutes');
like($r->{c}{stash}{error_msg}, qr/Too many failed login attempts/, 'friendly message shown');

$r = login(user => 'adminu', pass => $PW{adminu}, ip => $B);
ok($r->{ok}, 'admin account is NOT locked: correct password from another IP works');
$r = login(user => 'alice', pass => $PW{alice}, ip => $A);
ok($r->{ok}, 'same blocked IP can still log in to a different account (per-account rule)');

$T += 899;
$r = login(user => 'adminu', pass => $PW{adminu}, ip => $A);
is($r->{status}, 429, 'still blocked just before the window ends');
$T += 5;                                   # fake clock passes 15 minutes after the failures
$r = login(user => 'adminu', pass => $PW{adminu}, ip => $A);
ok($r->{ok}, 'block expires on its own after the 15 minute window; admin can log in again');

# ---- 6. account-wide: soft delay only, never a block ----------------------------
$T += 10_000; @SLEPT = ();
login(user => 'adminu', pass => 'fake-spray', ip => "192.0.2.$_") for 1 .. 20;
is(scalar(@SLEPT), 0, 'no delay before 20 failures');
$r = login(user => 'adminu', pass => $PW{adminu}, ip => '192.0.2.200');
ok($r->{ok}, '20 failures across IPs: owner still logs in from a clean IP (no block)');
is(scalar(@SLEPT), 1, 'soft delay applied once');
ok($SLEPT[0] > 0 && $SLEPT[0] <= 0.25, "soft delay is tiny ($SLEPT[0] s, cap 0.25 s) - a worker is never parked");
$T += 901; @SLEPT = ();
$r = login(user => 'adminu', pass => $PW{adminu}, ip => '192.0.2.201');
ok($r->{ok} && !@SLEPT, 'account-wide delay disappears after the window');

# ---- 7. per-IP spray across accounts --------------------------------------------
$T += 10_000;
my $S1 = '203.0.113.99';
login(user => "ghost$_", pass => 'fake-spray', ip => $S1) for 1 .. 30;
$r = login(user => 'alice', pass => $PW{alice}, ip => $S1);
is($r->{status}, 429, '30 failures from one IP across accounts blocks that IP');
$T += 901;
$r = login(user => 'alice', pass => $PW{alice}, ip => $S1);
ok($r->{ok}, 'IP spray block also expires');

# ---- 8. registration limit -------------------------------------------------------
$T += 10_000;
my $okc = grep { $thr->register_allowed('203.0.113.50') } 1 .. 7;
is($okc, 5, 'registration: 5 per hour per IP');
ok($thr->register_allowed('203.0.113.51'), 'other IP not affected');
$T += 3601;
ok($thr->register_allowed('203.0.113.50'), 'registration block expires after an hour');

# ---- 9. DB-backed store (system_log, no schema change) ---------------------------
{
    my $T2 = 1_900_000_000;
    my $dbstore = Comserv::Util::LoginThrottle::DBStore->new($schema->resultset('SystemLog'));
    my $dthr = Comserv::Util::LoginThrottle->new(store => $dbstore, clock => sub { $T2 }, sleeper => sub { });
    login(user => 'alice', pass => 'fake-db-bad', ip => '203.0.113.77', throttle => $dthr) for 1 .. 5;
    $r = login(user => 'alice', pass => $PW{alice}, ip => '203.0.113.77', throttle => $dthr);
    is($r->{status}, 429, 'DB store: blocked after 5 failures');
    $r = login(user => 'alice', pass => $PW{alice}, ip => '203.0.113.78', throttle => $dthr);
    ok($r->{ok}, 'DB store: other IP not blocked');
    $T2 += 901;
    $r = login(user => 'alice', pass => $PW{alice}, ip => '203.0.113.77', throttle => $dthr);
    ok($r->{ok}, 'DB store: block expires with the fake clock');
    # success marker clears
    login(user => 'alice', pass => 'fake-db-bad', ip => '203.0.113.79', throttle => $dthr) for 1 .. 4;
    login(user => 'alice', pass => $PW{alice}, ip => '203.0.113.79', throttle => $dthr);
    login(user => 'alice', pass => 'fake-db-bad', ip => '203.0.113.79', throttle => $dthr) for 1 .. 4;
    $r = login(user => 'alice', pass => $PW{alice}, ip => '203.0.113.79', throttle => $dthr);
    ok($r->{ok}, 'DB store: success clears the counter');

    my @rows = $schema->resultset('SystemLog')->search({ subroutine => 'login_throttle' })->all;
    ok(scalar(@rows) > 10, 'throttle rows were written to system_log');
    my $blob = join "\n", map { $_->message } @rows;
    for my $secret (values %PW, 'fake-db-bad', 'fake-WRONG', 'fake-spray') {
        ok(index($blob, $secret) < 0, "throttle rows do not contain password '" . substr($secret, 0, 9) . "...'");
    }
    like($blob, qr/^login_fail ip=203\.0\.113\.77 acct=[0-9a-f]{24}$/m, 'rows hold only IP + hashed account key');
    unlike($blob, qr/[0-9a-f]{64}|X-PBKDF2/, 'throttle rows contain no password hash');
}

# fail-open if the store is broken
{
    package BrokenStore; sub new { bless {}, shift } sub add { die "db down" } sub count { die "db down" } sub recent { die "db down" }
}
{
    my $bt = Comserv::Util::LoginThrottle->new(store => BrokenStore->new, clock => sub { $T });
    is($bt->check_login('203.0.113.1', 'alice')->{action}, 'allow', 'storage error fails open (login still works)');
    ok(!$bt->record_failure('203.0.113.1', 'alice'), 'record_failure reports the storage error but does not die');
    ok($bt->register_allowed('203.0.113.1'), 'registration fails open too');
}

# ---- 10a. account key is normalised (name, e-mail, case, spaces share one counter) --
{
    $schema->resultset('User')->create({ username => 'bob', password => $PH->hash('fake-Bob-pass-7'),
                                         email => 'bob@x.com', roles => 'normal', status => 'active' });
    my $st = Comserv::Util::LoginThrottle::MemoryStore->new;
    my $nt = Comserv::Util::LoginThrottle->new(store => $st, clock => sub { $T }, sleeper => sub { });
    my $ipb = '203.0.113.150';
    login(user => 'bob',          pass => 'fake-bad-1', ip => $ipb, throttle => $nt);
    login(user => 'BOB',          pass => 'fake-bad-2', ip => $ipb, throttle => $nt);
    login(user => 'bob@x.com',    pass => 'fake-bad-3', ip => $ipb, throttle => $nt);
    login(user => ' Bob@X.com ',  pass => 'fake-bad-4', ip => $ipb, throttle => $nt);
    login(user => 'bob ',         pass => 'fake-bad-5', ip => $ipb, throttle => $nt);
    $r = login(user => 'bob@x.com', pass => 'fake-Bob-pass-7', ip => $ipb, throttle => $nt);
    is($r->{status}, 429, "5 failures typed as bob / BOB / bob\@x.com / ' Bob\@X.com ' count as ONE account");
    my %keys = map { $_->{msg} =~ /acct=(\w+)/ ? ($1 => 1) : () } @{ $st->{rows} };
    is(scalar(keys %keys), 1, 'all five failures were stored under a single account key');
    is(Comserv::Util::LoginThrottle->account_key('  Ghost '), Comserv::Util::LoginThrottle->account_key('ghost'), 'unknown names: trimmed + lower-cased');
    is(Comserv::Util::LoginThrottle->account_key("uid:5"), Comserv::Util::LoginThrottle->account_key(" UID:5 "), 'account_key trims/lower-cases its input');
    $r = login(user => 'bob', pass => 'fake-Bob-pass-7', ip => '203.0.113.151', throttle => $nt);
    ok($r->{ok}, 'other IP still logs in (per IP + account)');
}

# ---- 10. logs never carry passwords or hashes -----------------------------------
@LOG = ();
login(user => 'newbie_nobody', pass => 'fake-LOGLEAK-1', ip => '203.0.113.60', keep_log => 1);
login(user => 'alice', pass => 'fake-LOGLEAK-2', ip => '203.0.113.60', keep_log => 1);
login(user => 'alice', pass => $PW{alice}, ip => '203.0.113.61', keep_log => 1);
my $logs = join "\n", @LOG;
ok(length $logs > 100, 'captured login log lines');
for my $secret (values %PW, 'fake-LOGLEAK-1', 'fake-LOGLEAK-2') {
    ok(index($logs, $secret) < 0, "log lines do not contain password '" . substr($secret, 0, 9) . "...'");
}
unlike($logs, qr/[0-9a-f]{64}|X-PBKDF2/, 'log lines contain no hash text');

# ---- 11. real work factor: 16-byte CSPRNG salt, 100k iterations, parsed upgrade rule ---
{
    local $Comserv::Util::PasswordHash::ITERATIONS = $REAL_ITER;
    cmp_ok($REAL_ITER, '>=', 100_000, 'work factor is at least 100,000');
    cmp_ok($REAL_ITER, '<=', 300_000, 'work factor is at most 300,000 (login CPU)');
    my $pbkdf2 = Crypt::PBKDF2->new(hash_class => 'HMACSHA2', hash_args => { sha_size => 256 }, iterations => 1, output_len => 32);
    my $h1 = $PH->hash('fake-salt-test-1');
    my $h2 = $PH->hash('fake-salt-test-1');
    my ($i1, $s1) = $PH->pbkdf2_params($h1);
    my ($i2, $s2) = $PH->pbkdf2_params($h2);
    is($i1, $REAL_ITER, 'stored iteration count is the real work factor');
    is($s1, 16, 'salt is 16 bytes');
    is($s2, 16, 'salt is 16 bytes (second hash)');
    my $d1 = $pbkdf2->decode_string($h1); my $d2 = $pbkdf2->decode_string($h2);
    isnt($d1->{salt}, $d2->{salt}, 'salts differ per call');
    my %seen = map { $PH->pbkdf2_params($PH->hash("x$_")) ? () : (); } ();   # (keeps the hash cheap: no extra 0.4 s hashes)
    ok($PH->verify($h1, 'fake-salt-test-1'), 'verify works with the new format');
    ok(!$PH->verify($h1, 'fake-salt-test-2'), 'verify rejects a wrong password');
    ok(!$PH->needs_upgrade($h1), 'current hash does not need upgrade');
    {   # randomness comes from Crypt::URandom, not Perl rand
        my $src = do { local (@ARGV, $/) = ("$FindBin::Bin/../lib/Comserv/Util/PasswordHash.pm"); <> };
        like($src, qr/Crypt::URandom::urandom\(\$SALT_LEN\)/, 'salt is read from Crypt::URandom');
        like($src, qr/generate\(\$password, \$salt\)/, 'salt is passed to generate()');
    }

    # an old hash as released in the first PBKDF2 version: 10,000 iterations, 4-byte salt
    my $old = Crypt::PBKDF2->new(hash_class => 'HMACSHA2', hash_args => { sha_size => 256 }, iterations => 10_000, output_len => 32);
    my $old_hash = $old->generate($PW{alice});
    my ($oi, $os) = $PH->pbkdf2_params($old_hash);
    is($oi, 10_000, 'fixture: old hash has 10,000 iterations'); is($os, 4, 'fixture: old hash has a 4-byte salt');
    ok($PH->verify($old_hash, $PW{alice}), 'old 10k hash still verifies');
    ok($PH->needs_upgrade($old_hash), 'old 10k / 4-byte-salt hash needs upgrade');
    my $iter_only = Crypt::PBKDF2->new(hash_class => 'HMACSHA2', hash_args => { sha_size => 256 }, iterations => 10_000, output_len => 32, salt_len => 16)->generate('x');
    ok($PH->needs_upgrade($iter_only), 'lower iteration count alone needs upgrade');
    my $salt_only = Crypt::PBKDF2->new(hash_class => 'HMACSHA2', hash_args => { sha_size => 256 }, iterations => $REAL_ITER, output_len => 32, salt_len => 4)->generate('x');
    ok($PH->needs_upgrade($salt_only), 'short salt alone needs upgrade');
    ok($PH->needs_upgrade('{X-PBKDF2}HMACSHA2+256:broken'), 'unparseable PBKDF2 string is re-hashed');
    ok(!$PH->needs_upgrade('garbage'), 'garbage (not PBKDF2, not SHA-256) is still left alone');

    # login: old 10k hash upgrades once, a current hash is left alone
    $schema->resultset('User')->find({ username => 'alice' })->update({ password => $old_hash });
    my $t = Comserv::Util::LoginThrottle->new(store => Comserv::Util::LoginThrottle::MemoryStore->new, clock => sub { $T }, sleeper => sub { });
    $r = login(user => 'alice', pass => 'fake-WRONG', ip => '203.0.113.160', throttle => $t);
    is(stored('alice'), $old_hash, 'wrong password does not upgrade the old hash');
    $r = login(user => 'alice', pass => $PW{alice}, ip => '203.0.113.160', throttle => $t);
    ok($r->{ok}, 'old 10k hash logs in');
    isnt(stored('alice'), $old_hash, 'old 10k hash was re-hashed at login');
    my ($ni, $ns) = $PH->pbkdf2_params(stored('alice'));
    is($ni, $REAL_ITER, 'new hash has the current iteration count'); is($ns, 16, 'new hash has a 16-byte salt');
    my $cur = stored('alice');
    $r = login(user => 'alice', pass => $PW{alice}, ip => '203.0.113.160', throttle => $t);
    ok($r->{ok}, 'upgraded account logs in again');
    is(stored('alice'), $cur, 'current hash is NOT re-written');
}

# ---- 12. client IP used by the throttle -------------------------------------------
{
    my $ipt = Comserv::Util::LoginThrottle->new(store => Comserv::Util::LoginThrottle::MemoryStore->new, clock => sub { $T }, sleeper => sub { });
    my $attempt = sub {
        my (%a) = @_;
        my $c = FakeCtx->new(schema => $schema, model => FakeModel->new($schema),
            req => FakeReq->new(address => $a{addr}, headers => $a{headers} || {}, params => { username => 'alice', password => 'fake-wrong' }));
        $c->{stash}{login_throttle} = $ipt;
        $ctrl->do_login($c);
        return $c;
    };
    $attempt->(addr => '203.0.113.200', headers => { 'cf-connecting-ip' => '198.51.100.99', 'x-forwarded-for' => '198.51.100.98' });
    $attempt->(addr => '127.0.0.1',     headers => { 'cf-connecting-ip' => '198.51.100.55' });
    $attempt->(addr => '203.0.113.201');
    my @msgs = map { $_->{msg} } @{ $ipt->{store}{rows} };
    ok((grep { /ip=203\.0\.113\.200 / } @msgs), 'untrusted direct peer: spoofed CF-Connecting-IP / X-Forwarded-For ignored (peer address used)');
    ok(!(grep { /ip=198\.51\.100\.9[89] / } @msgs), 'spoofed header values never became the throttle IP');
    ok((grep { /ip=198\.51\.100\.55 / } @msgs), 'trusted proxy (127.0.0.1) + CF-Connecting-IP: the CF client IP is the throttle IP');
    ok((grep { /ip=203\.0\.113\.201 / } @msgs), 'no headers: the peer address is used');
    # spoofing cannot dodge the block: 5 failures from the same real peer with different fake headers
    my $dodge = sub { $attempt->(addr => '203.0.113.210', headers => { 'cf-connecting-ip' => "198.51.100.$_[0]", 'x-forwarded-for' => "192.0.2.$_[0]" }) };
    $dodge->($_) for 1 .. 5;
    my $blocked = $attempt->(addr => '203.0.113.210', headers => { 'cf-connecting-ip' => '198.51.100.222' });
    is($blocked->res->status, 429, 'rotating fake headers from one untrusted peer does not escape the IP+account block');
    # registration limit uses the same IP
    my $reg = sub {
        my (%a) = @_;
        my $c = FakeCtx->new(schema => $schema, model => FakeModel->new($schema),
            req => FakeReq->new(address => $a{addr}, headers => $a{headers} || {}, params => { csrf_token => 'fake-csrf' }));
        $c->session->{csrf_token} = 'fake-csrf';
        $c->{stash}{login_throttle} = $ipt;
        eval { $ctrl->do_create_account($c) };
        return $c;
    };
    my $n429 = 0;
    for my $i (1 .. 7) { my $c = $reg->(addr => '203.0.113.220', headers => { 'cf-connecting-ip' => "198.51.100.$i" }); $n429++ if $c->res->status == 429 }
    is($n429, 2, 'registration limit: 5 allowed then 429, spoofed headers do not help');
}

# ---- 13. housekeeping: old rows are pruned (cheap, hourly, never fatal) --------------
{
    my $now = 1_950_000_000;
    local $Comserv::Util::LoginThrottle::LAST_PRUNE = 0;
    my $st = Comserv::Util::LoginThrottle::MemoryStore->new;
    my $pt = Comserv::Util::LoginThrottle->new(store => $st, clock => sub { $now }, sleeper => sub { });
    $st->add('login_fail ip=203.0.113.1 acct=aaaa', $now - 8 * 86400);
    $st->add('login_clear ip=203.0.113.1 acct=aaaa', $now - 8 * 86400);
    $st->add('login_fail ip=203.0.113.1 acct=bbbb', $now - 6 * 86400);
    is($pt->maybe_prune, 1, 'prune runs the first time');
    is(scalar(@{ $st->{rows} }), 1, 'rows older than 7 days are gone, newer ones kept');
    is($pt->maybe_prune, 0, 'prune does not run again within the hour');
    $now += 3601;
    is($pt->maybe_prune, 1, 'prune runs again after an hour');

    # DB store: one DELETE, only login_throttle rows
    $Comserv::Util::LoginThrottle::LAST_PRUNE = 0;
    my $rs = $schema->resultset('SystemLog');
    my $fmt = sub { POSIX::strftime('%Y-%m-%d %H:%M:%S', gmtime($_[0])) };
    my %row = (level => 'INFO', file => 'x', line => 0, occurrence_count => 1);
    $rs->create({ %row, timestamp => $fmt->($now - 9 * 86400), subroutine => 'login_throttle', message => 'login_fail ip=1.1.1.1 acct=old' });
    $rs->create({ %row, timestamp => $fmt->($now - 9 * 86400), subroutine => 'other_sub',      message => 'keep me: old but not ours' });
    $rs->create({ %row, timestamp => $fmt->($now - 60),        subroutine => 'login_throttle', message => 'login_fail ip=1.1.1.1 acct=new' });
    my $dt = Comserv::Util::LoginThrottle->new(store => Comserv::Util::LoginThrottle::DBStore->new($rs), clock => sub { $now }, sleeper => sub { });
    is($dt->maybe_prune, 1, 'DB prune ran');
    is($rs->search({ message => 'login_fail ip=1.1.1.1 acct=old' })->count, 0, 'old login_throttle row deleted');
    is($rs->search({ message => 'login_fail ip=1.1.1.1 acct=new' })->count, 1, 'recent login_throttle row kept');
    is($rs->search({ subroutine => 'other_sub' })->count, 1, 'other subroutines are never touched');

    # a broken store never makes prune (or a login) fatal
    $Comserv::Util::LoginThrottle::LAST_PRUNE = 0;
    { package PruneDies; sub new { bless {}, shift } sub prune { die "db down" } sub add { 1 } }
    my $bt = Comserv::Util::LoginThrottle->new(store => PruneDies->new, clock => sub { $now });
    my $ok = eval { $bt->maybe_prune; $bt->record_failure('203.0.113.1', 'x'); 1 };
    ok($ok, 'prune error is swallowed');
}

# ---- 14. system_log index (DBIC sqlt_deploy_hook; Schema Compare cannot create plain indexes) --
{
    my @stmts = do { local $SIG{__WARN__} = sub { }; $schema->deployment_statements('SQLite') };
    ok((grep { /CREATE\s+INDEX\s+"?idx_system_log_subroutine_timestamp"?\s+ON\s+"?system_log"?\s*\(\s*"?subroutine"?\s*,\s*"?timestamp"?\s*\)/i } @stmts),
       'system_log deploys with an index on (subroutine, timestamp)');
}

# ---- 15. do_change_password: hash_password is inside the eval ----------------------------
{
    my $src = do { local (@ARGV, $/) = ("$FindBin::Bin/../lib/Comserv/Controller/User.pm"); <> };
    like($src, qr/eval \{\s*my \$hashed_password = \$self->hash_password\(\$new_password\);\s*\$user->update/, 'do_change_password hashes inside the eval');
    unlike($src, qr/my \$hashed_password = \$self->hash_password\(\$new_password\);\s*\n\s*eval/, 'no hash_password call left outside the eval');
}

done_testing;
