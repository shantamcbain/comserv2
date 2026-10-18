#!/usr/bin/env perl
# Super Grok use-it-up pacing (Oct 8 2026): cycle, calibration, pace, warnings, jobs.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Time::Local qw(timelocal);
local $ENV{TZ} = 'America/Los_Angeles';
use POSIX (); POSIX::tzset();
use JSON::PP ();

use_ok('Comserv::Util::AI::SuperGrokPacing');
my $P = 'Comserv::Util::AI::SuperGrokPacing';
my $T = sub { my ($mo, $d, $h, $m) = @_; timelocal(0, $m, $h, $d, $mo - 1, 2026) };

# cycle: Thu 10:31 PT -> Thu 10:31 PT
my ($cs, $rs) = $P->can('cycle_bounds')->($T->(10, 12, 9, 0));
is $cs, $T->(10, 8, 10, 31), 'cycle start Thu Oct 8 10:31';
is $rs, $T->(10, 15, 10, 31), 'reset Thu Oct 15 10:31';
($cs) = $P->can('cycle_bounds')->($T->(10, 8, 10, 30));
is $cs, $T->(10, 1, 10, 31), 'one minute before reset is still the old cycle';

# Units: 1 M tokens per hour of the week, constant (simple synthetic world).
my $units = sub { my ($f, $t) = @_; ($t - $f) / 3600 };
my @rd = (
    { at => $T->(10, 3, 10, 31), value => 24, kind => 'used', source => 'addon' },    # 48 h after reset: 48 Mtok -> 24 %  => 0.5 %/Mtok
    { at => $T->(10, 5, 10, 31), value => 48, kind => 'used', source => 'manual' },   # +48 Mtok -> +24 %
    { at => $T->(10, 5, 12, 0),  value => 99, kind => 'unconfirmed', source => 'manual' },   # ignored
    { at => $T->(10, 4, 0, 0),   value => 70, kind => 'used', source => 'derived' },  # ignored
    { at => $T->(10, 8, 10, 31), value => 0,  kind => 'used', source => 'other' },    # reset seed
);
my $fit = $P->can('fit_rate')->(readings => \@rd, units => $units, now => $T->(10, 9, 10, 31));
ok $fit->{fitted}, 'rate fitted from readings';
is sprintf('%.2f', $fit->{rate}), '0.50', '0.5 %/M tokens (implicit 0 % at cycle start + pair)';
is scalar @{ $fit->{pairs} }, 2, 'two intervals (unconfirmed/derived skipped, reset seed not an interval)';
my $none = $P->can('fit_rate')->(readings => [], units => $units, now => time);
is $none->{fitted}, 0, 'no readings -> default';
is $none->{rate}, 0.60, 'default rate';

# Pace: Sat Oct 10 10:31 (2/7 of the week), nothing used since the reset seed.
my $idle = sub { 0 };
my $p = $P->can('pacing')->(readings => \@rd, units => $idle, rate => 0.5, now => $T->(10, 10, 10, 31));
is $p->{used_pct}, '0.0', 'used 0 since reset';
is $p->{expected_pct}, '28.6', 'straight line 2/7';
is $p->{pace}, 'behind', 'behind pace';
is $p->{daily_target_pct}, '20.0', '100 % / 5 days';
ok !$p->{midweek_warning}, 'Saturday: no midweek warning';
# Monday 10:31, still idle -> midweek warning
$p = $P->can('pacing')->(readings => \@rd, units => $idle, rate => 0.5, now => $T->(10, 12, 10, 31));
ok $p->{midweek_warning}, 'Monday behind -> warning';
like $p->{warnings}[0], qr/behind pace/, 'warning text';
# Monday on pace (used via units) -> no warning
my $busy = sub { my ($f, $t) = @_; ($t - $f) / 3600 * (100 / 168) / 0.5 };   # exactly the straight line
$p = $P->can('pacing')->(readings => \@rd, units => $busy, rate => 0.5, now => $T->(10, 12, 10, 31));
is $p->{pace}, 'on_pace', 'on pace when burn matches the line';
ok !$p->{midweek_warning}, 'no warning on pace';
# Endgame: Wed 22:31 (36 h left), 50 % left -> endgame; 10 % left -> not
$p = $P->can('pacing')->(readings => [ @rd, { at => $T->(10, 14, 22, 0), value => 50, kind => 'used', source => 'manual' } ],
                         units => $idle, rate => 0.5, now => $T->(10, 13, 22, 31));
ok $p->{endgame}, 'last 36 h with 50 % left -> endgame';
$p = $P->can('pacing')->(readings => [ @rd, { at => $T->(10, 13, 22, 0), value => 90, kind => 'used', source => 'manual' } ],
                         units => $idle, rate => 0.5, now => $T->(10, 13, 22, 31));
ok !$p->{endgame}, '10 % left -> no endgame list';
is $p->{base_reading}{value}, 90, 'latest in-cycle reading is the base';
# reading "left" converted
$p = $P->can('pacing')->(readings => [ { at => $T->(10, 9, 9, 0), value => 70, kind => 'left', source => 'manual' } ],
                         units => $idle, rate => 0.5, now => $T->(10, 9, 10, 0));
is $p->{used_pct}, '30.0', '70 % left = 30 % used';
# capped at 100
$p = $P->can('pacing')->(readings => [], units => sub { 1000 }, rate => 0.5, now => $T->(10, 9, 10, 0));
is $p->{used_pct}, '100.0', 'estimate capped at 100 %';

# Meter staleness (>24 h) ignores seeded/other readings
my $m = $P->can('meter_status')->(readings => \@rd, now => $T->(10, 9, 10, 0));
ok $m->{stale}, 'last real meter reading Oct 5 -> stale';
like $m->{prompt}, qr/manual reading/, 'prompt asks for a manual reading';
is $m->{form_url}, '/ai/usage#usage-estimator', 'links the existing readings form';
$m = $P->can('meter_status')->(readings => [ @rd, { at => $T->(10, 9, 8, 0), value => 5, kind => 'used', source => 'manual' } ], now => $T->(10, 9, 10, 0));
ok !$m->{stale}, 'fresh manual reading -> not stale';

# Jobs ranking
my $jobs = $P->can('recommend_jobs')->(
    tickets   => [ { id => 1, number => 'T-1', subject => 'Login broken', priority => 'high' },
                   { id => 2, number => 'T-2', subject => 'Typo', priority => 'low' } ],
    proposals => [ { id => 9, title => 'Fix X', status => 'approved', change_type => 'code', report_id => 22 },
                   { id => 10, title => 'Set Y', status => 'proposed', change_type => 'config' } ],
    todos     => [ { id => 100, subject => 'Ranked high', rank_score => 1.4 }, { id => 101, subject => 'Ranked low', rank_score => 0.1 } ]);
is $jobs->[0]{kind}, 'helpdesk', 'high-priority ticket first';
is $jobs->[1]{id}, 100, 'top TodoRank todo next (1 + 1.4)';
ok !(grep { ($_->{id} // 0) == 10 && $_->{kind} eq 'eval_proposal' } @$jobs), 'config proposals excluded';
is $jobs->[0]{rank}, 1, 'ranked';
like $P->can('hermes_command')->($jobs->[0]), qr/--provider xai-oauth -m grok-4\.7 /, 'Hermes command on grok-4.7';
is Comserv::Util::AI::SuperGrokPacing::model_weight('grok-build-0.1'), 1.0, 'weight grok-build';
is Comserv::Util::AI::SuperGrokPacing::model_weight('grok-4.7'), 1.0, 'weight grok-4.7';
is Comserv::Util::AI::SuperGrokPacing::model_weight('grok-4.6'), 1.0, 'weight grok-4.6';
is Comserv::Util::AI::SuperGrokPacing::model_weight('ollama/x'), 1.0, 'weight default';

# ---- burn alerts (Oct 8 2026) ----
{
    my $P = 'Comserv::Util::AI::SuperGrokPacing';
    local $ENV{TZ} = 'America/Los_Angeles'; POSIX::tzset();
    my $ten = Time::Local::timelocal(0, 0, 10, 8, 9, 2026);
    my $seven_pm = Time::Local::timelocal(0, 5, 19, 8, 9, 2026);
    is $P->can('day_start')->($seven_pm), Time::Local::timelocal(0, 0, 5, 8, 9, 2026), 'day_start = 05:00 PT (work day, Oct 11 2026)';
    is $P->can('day_start')->(Time::Local::timelocal(0, 0, 3, 9, 9, 2026)), Time::Local::timelocal(0, 0, 5, 8, 9, 2026), '03:00 belongs to the previous work day';
    is $P->can('day_start')->($seven_pm, 0), Time::Local::timelocal(0, 0, 0, 8, 9, 2026), 'day_start_hour 0 = midnight';
    is $P->can('pt_date')->(Time::Local::timelocal(0, 59, 4, 11, 9, 2026)), '2026-10-10', 'pt_date 04:59 -> previous work day';
    is $P->can('pt_date')->(Time::Local::timelocal(0, 0, 5, 11, 9, 2026)), '2026-10-11', 'pt_date 05:00 -> new work day';
    my $five = Time::Local::timelocal(0, 0, 5, 8, 9, 2026);
    my $a = $P->can('burn_alerts')->(used => 41, used_day_start => 0, day_from => $five, expected => 5, now => $seven_pm, budget_pct => 10);
    is scalar(@$a), 2, 'Oct 8 case: day rise and work-window both fire';
    is $a->[0]{kind}, 'day_rise', '... day_rise first';
    is $a->[0]{level}, 'critical', '... critical';
    like $a->[0]{message}, qr/burned 41 points in the Thu Oct 08 work day/, '... message names the work day (Oct 18)';
    # Oct 18 2026: no previous-day alert after midnight (03:20 Sunday case).
    my $three20 = Time::Local::timelocal(0, 20, 3, 9, 9, 2026);
    is_deeply $P->can('burn_alerts')->(used => 44, used_day_start => 16, day_from => $five, now => $three20, budget_pct => 14),
        [], 'after midnight: previous work day sends nothing';
    like $P->can('burn_alerts')->(used => 44, used_day_start => 16, day_from => $five, now => $seven_pm, used_basis => 'meter')->[0]{message},
        qr/\(meter\)/, 'message says which number was used';
    is $a->[1]{kind}, 'work_window', '... work_window (>60% of budget by 09:00)';
    my $nine = Time::Local::timelocal(0, 5, 9, 8, 9, 2026);
    my $eight = Time::Local::timelocal(0, 55, 8, 8, 9, 2026);
    $a = $P->can('burn_alerts')->(used => 4, used_day_start => 0, day_from => $five, now => $nine, budget_pct => 6);
    is_deeply [map { $_->{kind} } @$a], ['work_window'], '09:05, 4 of 6 points (67%) -> work_window';
    $a = $P->can('burn_alerts')->(used => 4, used_day_start => 0, day_from => $five, now => $eight, budget_pct => 6);
    is scalar(@$a), 0, '08:55: before check_hour, quiet';
    $a = $P->can('burn_alerts')->(used => 3, used_day_start => 0, day_from => $five, now => $nine, budget_pct => 6);
    is scalar(@$a), 0, '09:05, 50% of budget: quiet';
    $a = $P->can('burn_alerts')->(used => 3, used_day_start => 0, day_from => $five, now => $eight, budget_pct => 6, cfg => { check_hour => 8, budget_fraction => 0.4 });
    is_deeply [map { $_->{kind} } @$a], ['work_window'], 'check_hour / budget_fraction configurable';
    $a = $P->can('burn_alerts')->(used => 30, used_day_start => 0, day_from => $ten, expected => 1, now => Time::Local::timelocal(0, 0, 11, 8, 9, 2026));
    is_deeply [map { $_->{kind} } @$a], ['day_rise'], 'before noon: only day_rise';
    $a = $P->can('burn_alerts')->(used => 20, used_day_start => 8, day_from => $ten, expected => 15, now => $seven_pm);
    is scalar(@$a), 0, '12-point day, 5 ahead: quiet';
    $a = $P->can('burn_alerts')->(used => 20, used_day_start => 8, day_from => $ten, expected => 15, now => $seven_pm, cfg => { day_rise_pts => 10 });
    is scalar(@$a), 1, 'configurable day_rise threshold';
    is $P->can('alert_config')->({ day_rise_pts => 'x' })->{day_rise_pts}, 15, 'bad config value ignored';
    # pacing() wires it: 0% at reset 10:31, units give 41 points by 19:05
    my $reset = Time::Local::timelocal(0, 31, 10, 8, 9, 2026);
    my $p = $P->can('pacing')->(readings => [ { at => $reset, value => 0, kind => 'used', source => 'other' } ],
        units => sub { my ($f, $t) = @_; ($t - $f) / 3600 * 8 }, rate => 0.6, now => $seven_pm, anchor => $reset);
    ok abs($p->{used_pct} - 41.1) < 0.2, 'pacing used ~41%';
    is $p->{used_day_start_pct}, '0.0', 'day measured from the reset (later than midnight)';
    is scalar(@{ $p->{alerts} }), 2, 'pacing returns alerts';
    is $P->can('call_weight')->({ model => 'grok-4.7', in => 250_000 }), 1.3, 'long-context call weight';
    is $P->can('call_weight')->({ model => 'grok-4.7', in => 150_000 }), 1.0, 'short call weight';
    POSIX::tzset();
}

# ---- script --alert (no HTTP, no notify) ----
{
    require File::Temp;
    my $dir = File::Temp::tempdir(CLEANUP => 1);
    mkdir "$dir/ai_eval_inbox";
    my $resp = { org => { health => { supergrok_pacing => {
        used_pct => '41.0', left_pct => '59.0', cycle_start_pt => 'Thu Oct 08 10:31 PT', reset_pt => 'Thu Oct 15 10:31 PT', days_left => '6.6',
        day_rise_pct => '41.0', day_from_pt => 'Thu Oct 08 10:31 PT', pace => 'ahead', pace_delta => '+36', expected_pct => '5',
        daily_target_pct => '9', daily_target_mtok => '15', daily_target_calls => '95', rate_pct_per_mtok => '0.550',
        base_reading => { value => 0, at_pt => 'x' }, meter => { stale => 0 },
        alerts => [ { kind => 'day_rise', level => 'critical', value => '41.0', message => 'Super Grok burned 41 points today' } ] } } } };
    open my $fh, '>', "$dir/resp.json"; print $fh JSON::PP::encode_json($resp); close $fh;
    my $perl = $^X;
    my $out = `$perl $FindBin::Bin/../script/supergrok_pacing.pl --alert --no-notify --json-file $dir/resp.json --data-dir $dir 2>&1`;
    like $out, qr/\[day_rise\].*-> log/, 'script: alert fired (log only)';
    ok -s "$dir/supergrok_alert_notice.txt", 'notice file written';
    my @inbox = glob("$dir/ai_eval_inbox/*-supergrok-pacing.json");
    is scalar(@inbox), 1, 'inbox file written';
    open my $ih, '<', $inbox[0]; local $/; my $rep = JSON::PP::decode_json(<$ih>); close $ih;
    like $rep->{summary}, qr/^ALERT: Super Grok burned 41/, 'inbox summary starts with the ALERT line';
    $out = `$perl $FindBin::Bin/../script/supergrok_pacing.pl --alert --no-notify --json-file $dir/resp.json --data-dir $dir 2>&1`;
    like $out, qr/nothing new/, 'same alert not repeated';
    $resp->{org}{health}{supergrok_pacing}{alerts}[0]{value} = '52';
    open $fh, '>', "$dir/resp.json"; print $fh JSON::PP::encode_json($resp); close $fh;
    $out = `$perl $FindBin::Bin/../script/supergrok_pacing.pl --alert --no-notify --json-file $dir/resp.json --data-dir $dir 2>&1`;
    like $out, qr/\[day_rise\]/, 're-notifies after +10 points';
    $resp->{org}{health}{supergrok_pacing}{alerts} = [];
    $resp->{org}{health}{supergrok_pacing}{meter} = { stale => 1, prompt => 'Super Grok meter has not reported for 30 h' };
    open $fh, '>', "$dir/resp.json"; print $fh JSON::PP::encode_json($resp); close $fh;
    $out = `$perl $FindBin::Bin/../script/supergrok_pacing.pl --alert --no-notify --json-file $dir/resp.json --data-dir $dir 2>&1`;
    like $out, qr/\[meter_stale\].*manual|\[meter_stale\]/, 'stale meter still asks for a reading';
    is -s "$dir/supergrok_alert_notice.txt" // 0, 0, 'notice file cleared when no burn alerts';
}


# ---- daily budget (Oct 9 2026) ----
{
    my $P = 'Comserv::Util::AI::SuperGrokPacing';
    local $ENV{TZ} = 'America/Los_Angeles'; POSIX::tzset();
    my $mid   = Time::Local::timelocal(0, 0, 0, 9, 9, 2026);
    my $reset = Time::Local::timelocal(0, 31, 10, 15, 9, 2026);
    my $now   = Time::Local::timelocal(0, 15, 8, 9, 9, 2026);
    my $db = $P->can('daily_budget')->(used => 54, used_day_start => 53, day_from => $mid, reset => $reset, now => $now);
    is $db->{budget_pct}, '5.7', 'budget (90-53)/6.44 days';
    is $db->{used_today_pct}, '1.0', 'used today';
    is $db->{over}, 0, 'under budget';
    is $db->{date}, '2026-10-09', 'PT date';
    $db = $P->can('daily_budget')->(used => 59.5, used_day_start => 53, day_from => $mid, reset => $reset, now => $now);
    is $db->{over}, 1, 'over budget';
    is $db->{switch_off}, 1, 'switch_off';
    like $db->{reason}, qr/today 6\.5% >= budget 5\.7%/, 'reason';
    $db = $P->can('daily_budget')->(used => 59.5, used_day_start => 53, day_from => $mid, reset => $reset, now => $now,
        cfg => { extra_today_pct => 3, extra_today_date => '2026-10-09' });
    is $db->{effective_budget_pct}, '8.7', 'extra today raises budget';
    is $db->{over}, 0, '... not over';
    is $db->{override_active}, 1, '... override active';
    $db = $P->can('daily_budget')->(used => 59.5, used_day_start => 53, day_from => $mid, reset => $reset, now => $now,
        cfg => { extra_today_pct => 3, extra_today_date => '2026-10-08' });
    is $db->{over}, 1, 'extra for another day ignored';
    $db = $P->can('daily_budget')->(used => 70, used_day_start => 53, day_from => $mid, reset => $reset, now => $now,
        cfg => { allow_overrun_date => '2026-10-09' });
    is $db->{over}, 0, 'allow_overrun_date today: never over';
    is $db->{allow_overrun}, 1, '... flagged';
    $db = $P->can('daily_budget')->(used => 91, used_day_start => 85, day_from => $mid, reset => $reset, now => $now,
        cfg => { allow_overrun_date => '2026-10-09' });
    is $db->{week_off}, 1, 'week cutoff still applies with allow_overrun';
    is $db->{switch_off}, 1, '... switch_off';
    $db = $P->can('daily_budget')->(used => 91, used_day_start => 85, day_from => $mid, reset => $reset, now => $now, cfg => { week_off_at => 95 });
    is $db->{week_off}, 0, 'week_off_at configurable';
    is $db->{budget_pct}, '1.6', '... budget uses it';
    # normalization: readings 41 (Oct 8 19:04) and 54 (Oct 9 08:12), uniform tokens -> split by time
    my $cs = Time::Local::timelocal(0, 31, 10, 8, 9, 2026);
    my @rd = ({ at => $cs, value => 0, kind => 'used', source => 'other' },
              { at => Time::Local::timelocal(0, 4, 19, 8, 9, 2026), value => 41, kind => 'used', source => 'spoken' },
              { at => Time::Local::timelocal(0, 12, 8, 9, 9, 2026), value => 54, kind => 'used', source => 'spoken' });
    my $p = $P->can('pacing')->(readings => \@rd, units => sub { ($_[1] - $_[0]) / 3600 }, rate => 0.55, now => $now, anchor => $cs);
    my $exp = 41 + 13 * ((Time::Local::timelocal(0, 0, 5, 9, 9, 2026) - $rd[1]{at}) / ($rd[2]{at} - $rd[1]{at}));
    ok abs($p->{daily_budget}{used_day_start_pct} - $exp) < 0.11, "05:00 day start interpolated between readings ($exp)";
    ok exists $p->{daily_budget}{budget_pct}, 'pacing returns daily_budget';
    POSIX::tzset();
}

# Oct 18 2026: fresh grok.com meter (< 2 h) beats the token estimate for burn alerts.
{
    my $P = 'Comserv::Util::AI::SuperGrokPacing';
    local $ENV{TZ} = 'America/Los_Angeles'; POSIX::tzset();
    my $now  = Time::Local::timelocal(0, 0, 15, 17, 9, 2026);       # Sat Oct 17 15:00 PT
    my $five = Time::Local::timelocal(0, 0, 5, 17, 9, 2026);
    my @rd = ({ at => $five - 600, value => 15, kind => 'used', source => 'addon' });
    my $units = sub { my ($f, $t) = @_; return ($t - $f) / 3600 * 1.0 };     # 1 M tok/h
    my %base = (readings => \@rd, units => $units, rate => 3, now => $now, alert_cfg => {});
    my $est = $P->can('pacing')->(%base);
    ok( (grep { $_->{kind} eq 'day_rise' && $_->{basis} eq 'estimate' } @{ $est->{alerts} }), 'no meter: estimate drives day_rise');
    my $m = $P->can('pacing')->(%base, meter_now => { value => 20, at => $now - 1800 });
    ok !(grep { $_->{kind} eq 'day_rise' } @{ $m->{alerts} }), 'fresh meter 20% (rise ~5) -> no day_rise despite high estimate';
    my $old = $P->can('pacing')->(%base, meter_now => { value => 20, at => $now - 3 * 3600 });
    ok( (grep { $_->{kind} eq 'day_rise' && $_->{basis} eq 'estimate' } @{ $old->{alerts} }), 'meter 3 h old -> estimate again');
}

done_testing;
