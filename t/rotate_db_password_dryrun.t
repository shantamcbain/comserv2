#!/usr/bin/env perl
# Tests for script/rotate_db_password.pl: the dry-run path (default) must change nothing and show no secret.
use strict; use warnings; use Test::More; use File::Temp qw(tempdir); use File::Path qw(make_path); use FindBin;
my $script = "$FindBin::Bin/../script/rotate_db_password.pl";
my $home = tempdir(CLEANUP => 1); my $sec = "$home/.comserv/secrets"; make_path("$sec/dbi", "$home/.comserv/keys"); chmod 0700, "$home/.comserv/keys";
my $FAKE = 'FAKE-old-pw-for-test-only';                       # not a real credential
my $dbi = "$sec/dbi/db_production_mysql.json";
open my $d, '>', $dbi or die; print $d qq({"db_production_mysql":{"username":"comserv_app","password":"$FAKE","priority":1,"host":"h","port":3307},"db_production_mysql_fallback":{"username":"shanta_forager","password":"$FAKE","priority":3}}); close $d; chmod 0600, $dbi;
my $cfg = "$sec/db-rotation.json";
open my $c, '>', $cfg or die; print $c qq({"logins":["comserv_app","comserv_app_b"],"primary_slot":"db_production_mysql","old_slots":["db_production_mysql_fallback"],"secrets_file":"dbi/db_production_mysql.json","grants":[],"state_dir":"$home/state","audit_log":"$home/audit.jsonl",
 "db_servers":[{"name":"db1","host":"127.0.0.1","port":1,"admin_defaults_file":"$home/none.cnf"}],
 "app_nodes":[{"name":"a","secrets_dir":"$sec","restart_cmd":"true","health_cmd":"true"},{"name":"b","secrets_dir":"$sec","restart_cmd":"true","health_cmd":"true"}]}); close $c; chmod 0600, $cfg;
sub snap { my $t = ''; for my $f (glob("$sec/dbi/* $sec/*")) { next unless -f $f; open my $h, '<', $f; local $/; $t .= "$f=" . <$h> . (stat $f)[9] } return $t }
sub run { my @a = @_; local $ENV{HOME} = $home; open my $p, '-|', "$^X $script @a 2>&1" or die; local $/; my $o = <$p>; close $p; return ($o, $? >> 8) }

my $before = snap();
my ($out, $rc) = run("--config $cfg");
is($rc, 0, 'dry-run is the default and exits 0');
like($out, qr/DRY-RUN \(nothing will be changed\)/, 'says dry-run');
for my $step (qw(snapshot pick-logins new-password stage-db:db1 verify-new-login roll-node:a roll-node:b soak save-state)) { like($out, qr/\Q$step\E/, "plan lists $step") }
unlike($out, qr/\Q$FAKE\E/, 'no password value printed');
is(snap(), $before, 'dry-run changed no secret file');
ok(!-e "$home/audit.jsonl" && !-e "$home/state", 'dry-run wrote no audit log or state, generated no password');

($out, $rc) = run("--config $cfg --generate");
is($rc, 0, 'dry-run with --generate still exits 0'); ok(!-e "$home/state/new_db_password", '--generate in dry-run creates nothing');

($out, $rc) = run("--config $cfg --phase retire");
like($out, qr/retire-db/, 'retire plan lists retire-db'); is(snap(), $before, 'retire dry-run changed nothing');

chmod 0644, $cfg; ($out, $rc) = run("--config $cfg"); isnt($rc, 0, 'world-readable config is refused'); like($out, qr/must be mode 0600/, 'says why'); chmod 0600, $cfg;
($out, $rc) = run("--config $cfg --execute"); isnt($rc, 0, '--execute without --generate/--new-password-file is refused'); is(snap(), $before, 'refused execute changed nothing');

# pure helpers (script loads as a module: main() only runs when executed)
{ local $ENV{HOME} = $home; require $script; }
my $data = { p => { username => 'old', password => 'o', priority => 1 }, fb => { username => 'other', password => 'x', priority => 5 }, p_fb => { username => 'old', password => 'o', priority => 3 } };
my $cut = main::transform_cutover({ %$data, map { $_ => { %{ $data->{$_} } } } keys %$data }, 'p', 'p', 'new', 'NEWPW');
is($cut->{p}{username}, 'new', 'cutover: primary slot now the new login'); is($cut->{p}{priority}, 1, 'cutover: new login is priority 1');
is($cut->{p_prev}{username}, 'old', 'cutover: old login kept as fallback'); cmp_ok($cut->{p_prev}{priority}, '>', 5, 'cutover: fallback sorts after every other slot');
my $ret = main::transform_retire($cut, 'p', 'old');
ok(!exists $ret->{p_prev} && !exists $ret->{p_fb}, 'retire: fallback and every slot using the old login removed'); is($ret->{fb}{username}, 'other', 'retire: unrelated slots untouched'); is($ret->{p}{username}, 'new', 'retire: primary kept');
my $pw = main::gen_pw(); like($pw, qr/\A[A-Za-z0-9_.-]{32}\z/, 'generated password is 32 safe chars'); isnt($pw, main::gen_pw(), 'generated passwords differ');
done_testing;
