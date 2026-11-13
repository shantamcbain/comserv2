use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use Comserv::Util::AI::SettingsWatch;

my $root = tempdir(CLEANUP => 1);
my $home = tempdir(CLEANUP => 1);
make_path("$root/lib/Comserv/Util/AI", "$root/data", "$root/root/config",
          "$root/lib/Comserv/Model/AI", "$home/.comserv/logs", "$root/data/ai_eval_inbox");

# Minimal files so default_watch_list has something, plus a temp watch target.
write_file("$root/data/ai_model_chains.json", '{"chain_chat":["x"]}');
write_file("$home/.comserv/ai_caps.json", '{"openrouter":{"day":3,"week":15,"month":65}}');
write_file("$root/root/config/ai_kill_switch.json", '{"killed":[]}');
write_file("$root/root/config/ai_usage.json", '{"alert_percent":80}');
write_file("$root/root/config/ai_grounding.json", '{"mode":"off"}');
write_file("$root/lib/Comserv/Util/AI/Dummy.pm", "package Comserv::Util::AI::Dummy;\n1;\n");
write_file("$root/lib/Comserv/Model/AI/Config.pm", "package Comserv::Model::AI::Config;\n1;\n");

my @defaults = @{ Comserv::Util::AI::SettingsWatch::default_watch_list($root, $home) };
ok(grep { $_ =~ /ai_model_chains\.json$/ } @defaults, 'default list includes model chains');
ok(grep { $_ =~ /ai_caps\.json$/ } @defaults, 'default list includes shared caps');
ok(grep { $_ =~ /Dummy\.pm$/ } @defaults, 'default list includes Util/AI modules');
ok(grep { $_ =~ /Config\.pm$/ } @defaults, 'default list includes Model/AI/Config.pm');
ok(!grep { $_ =~ /\.bak/ } @defaults, 'default list skips backups');

my $now = 1_700_000_000;
my @restarts;
my $health_ok = 1;
my $unit = { ActiveState => 'active', SubState => 'running', MainPID => '1' };
my @logs;
my $watch_json = "$root/tmp_watch.json";
write_file($watch_json, '{"ok":1}');

sub watcher {
    my (%extra) = @_;
    return Comserv::Util::AI::SettingsWatch->new(
        app_root          => $root,
        home              => $home,
        state_file        => "$home/.comserv/ai_settings_watch.state",
        log_file          => "$home/.comserv/logs/ai_settings_watch.log",
        lock_file         => "$home/.comserv/ai_settings_watch.lock",
        status_file       => "$home/.comserv/ai_settings_watch.status.json",
        inbox_dir         => "$root/data/ai_eval_inbox",
        watch             => $extra{watch} || [ $watch_json ],
        debounce_seconds  => $extra{debounce} // 120,
        cooldown_seconds  => $extra{cooldown} // 300,
        health_timeout    => 60,
        skip_lock         => 1,
        now_cb            => sub { $now },
        restart_cb        => sub { push @restarts, $now; 1 },
        health_cb         => sub { $health_ok },
        unit_status_cb    => sub { $unit },
        log_cb            => sub { push @logs, $_[0] },
        %extra,
    );
}

# 1. First run initializes, no restart.
my $w = watcher();
my $r = $w->run;
is $r->{action}, 'init', 'first run initializes state';
is $r->{reason}, 'first run';
is scalar(@restarts), 0, 'no restart on init';
ok(-f "$home/.comserv/ai_settings_watch.state", 'state file written');

# 2. Unchanged run is idle.
$r = $w->run;
is $r->{action}, 'idle', 'no change is idle';
is scalar(@restarts), 0;

# 3. --init again re-baselines without restart.
$r = $w->run(init_only => 1);
is $r->{action}, 'init';
is $r->{reason}, 'init flag';
is scalar(@restarts), 0;

# 4. Change starts debounce; further change resets the timer.
write_file($watch_json, '{"ok":2}');
$r = $w->run;
is $r->{action}, 'debounce';
is $r->{reason}, 'change_detected';
my $first_pending = $r->{pending_since};
is $first_pending, $now;
$now += 60;
write_file($watch_json, '{"ok":3}');    # further edit
$r = $w->run;
is $r->{action}, 'debounce';
is $r->{reason}, 'change_detected', 'further change resets debounce';
is $r->{pending_since}, $now, 'pending_since moved forward';
isnt $r->{pending_since}, $first_pending;

# 5. Waiting mid-window does not restart.
$now += 119;
$r = $w->run;
is $r->{action}, 'debounce';
is $r->{reason}, 'waiting';
is scalar(@restarts), 0;

# 6. After 120s, syntax-ok change restarts (via hook) and records success.
$now += 1;
$r = $w->run;
is $r->{action}, 'restarted', 'settled change restarts';
is scalar(@restarts), 1, 'one restart';
is $r->{ok}, 1;

# 7. Dry-run would restart but does not call the hook.
write_file($watch_json, '{"ok":4}');
$now += 400;                # past cooldown
$r = $w->run;               # start debounce
$now += 120;
$r = $w->run(dry_run => 1);
is $r->{action}, 'dry_run_restart', 'dry-run reports would_restart';
is scalar(@restarts), 1, 'dry-run did not call restart hook';

# 8. Bad JSON: no restart, inbox alert, and no duplicate on the same fingerprint.
# Still pending from dry-run; next real run does the syntax check.
$now += 400;
write_file($watch_json, '{not-json');
$r = $w->run;               # fingerprint changed -> debounce reset
is $r->{action}, 'debounce';
$now += 120;
$r = $w->run;
is $r->{action}, 'syntax_fail', 'bad JSON fails syntax check';
is $r->{ok}, 0;
is scalar(@restarts), 1, 'no restart on syntax fail';
my $inbox = inbox_file();
ok($inbox, 'alert inbox file created');
my $events = inbox_events($inbox);
is scalar(@$events), 1, 'one inbox event for the syntax failure';
$r = $w->run;
is $r->{action}, 'syntax_fail';
$events = inbox_events($inbox);
is scalar(@$events), 1, 'same fingerprint does not duplicate inbox event';

# 9. Bad Perl: no restart.
my $pm = "$root/tmp_watch.pm";
write_file($pm, "package TmpWatch;\nuse strict;\n1;\n");
# Re-init on just the pm so we go through a clean change path.
unlink "$home/.comserv/ai_settings_watch.state";
$w = watcher(watch => [$pm]);
$r = $w->run;
is $r->{action}, 'init';
write_file($pm, "package TmpWatch;\nuse strict;\n this is { definitely +++ not perl\n");
$r = $w->run;
is $r->{action}, 'debounce';
$now += 120;
$r = $w->run;
is $r->{action}, 'syntax_fail', 'bad perl fails perl -c';
is scalar(@restarts), 1;

# 10. Good perl after a valid change does restart.
write_file($pm, "package TmpWatch;\n1;\n");
$r = $w->run;               # debounce
$now += 120;
$now += 400;                # also past any cooldown from earlier (none happened)
$r = $w->run;
# cooldown may still apply from the success in test 6 if we didn't bump enough
# after test 6: last restart at that $now, then we added 400+120+400 + 120 + 400 + 120.
# That's plenty. If cooldown skips, bump and retry.
if ($r->{action} eq 'skip' && ($r->{reason} || '') eq 'cooldown') {
    $now += $r->{left} + 1;
    $r = $w->run;
}
is $r->{action}, 'restarted', 'valid perl change restarts';
is scalar(@restarts), 2;

# 11. Cooldown blocks a second restart.
write_file($pm, "package TmpWatch;\nour \$V = 2;\n1;\n");
$r = $w->run;
$now += 120;
$r = $w->run;
is $r->{action}, 'skip';
is $r->{reason}, 'cooldown';
is scalar(@restarts), 2, 'cooldown prevented second restart';

# 12. Mid-start skips even after cooldown.
$now += 400;
$unit = { ActiveState => 'activating', SubState => 'start-pre', MainPID => '0' };
write_file($pm, "package TmpWatch;\nour \$V = 3;\n1;\n");
# pending may already be set from test 11
$r = $w->run;
if ($r->{action} eq 'debounce' && ($r->{reason} || '') eq 'change_detected') {
    $now += 120;
    $r = $w->run;
}
is $r->{action}, 'skip';
is $r->{reason}, 'mid_start';
is scalar(@restarts), 2;

# 13. Missing watched file: no restart, alert.
$unit = { ActiveState => 'active', SubState => 'running', MainPID => '1' };
$now += 400;
unlink $pm;
$r = $w->run;
if ($r->{action} eq 'debounce') { $now += 120; $r = $w->run }
is $r->{action}, 'precheck_fail';
is $r->{reason}, 'missing_file';
is scalar(@restarts), 2;

# 14. Health failure after restart alerts and does not apply checksums
# (so a later run can retry once cooldown allows).
write_file($pm, "package TmpWatch;\nour \$V = 4;\n1;\n");
$health_ok = 0;
$r = $w->run;               # change vs MISSING / previous
$now += 120;
$now += 400 if 1;
$r = $w->run;
if ($r->{action} eq 'skip' && ($r->{reason} || '') eq 'cooldown') {
    $now += $r->{left} + 1;
    $r = $w->run;
}
is $r->{action}, 'health_fail', 'failed health check is reported';
is $r->{ok}, 0;
ok(scalar(@restarts) >= 3, 'restart was attempted before health fail');

# 15. Stamp uses Dawson Creek label; lock skips a second holder.
like $w->stamp(0), qr/Dawson Creek time/, 'log stamp names Dawson Creek time';
$w->{skip_lock} = 0;
# Hold the lock in this process, then a second object should skip.
open my $hold, '>', "$home/.comserv/ai_settings_watch.lock" or die $!;
flock($hold, 6) or die "lock: $!";  # LOCK_EX|LOCK_NB = 2|4 = 6
my $w2 = watcher(watch => [$watch_json], skip_lock => 0);
# same lock path
$w2->{lock_file} = "$home/.comserv/ai_settings_watch.lock";
$r = $w2->run;
is $r->{action}, 'skip';
is $r->{reason}, 'already_running';
close $hold;

# 16. http_answers refuses a non-4006 port.
my ($ok, $detail) = $w->http_answers('http://127.0.0.1:3001/', 1);
ok(!$ok, 'health check will not target :3001');
like $detail, qr/refusing health check/;

# 17. Default unit/port constants are aisystem :4006 only.
is(Comserv::Util::AI::SettingsWatch::UNIT, 'comserv-aisystem-4006.service');
is(Comserv::Util::AI::SettingsWatch::PORT, 4006);

done_testing;

sub write_file {
    my ($f, $c) = @_;
    open my $fh, '>', $f or die "$f: $!";
    print $fh $c;
    close $fh;
}
sub inbox_file {
    my @f = glob("$root/data/ai_eval_inbox/*-ai-settings-watch.json");
    return $f[0];
}
sub inbox_events {
    my ($f) = @_;
    open my $fh, '<', $f or return [];
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $d = eval { JSON::PP->new->utf8->decode($raw) } || {};
    return $d->{events} || [];
}
