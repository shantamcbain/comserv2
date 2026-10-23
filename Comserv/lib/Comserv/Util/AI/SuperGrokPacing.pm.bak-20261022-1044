package Comserv::Util::AI::SuperGrokPacing;

# Super Grok "use it up" pacing (Oct 8 2026). Weekly cycle Thu 10:31 PT ->
# Thu 10:31 PT. Shanta wants the quota used each week, not left on the table.
#
#  used %   = latest in-cycle reading (manual / grok.com add-on; reset = 0 %)
#             + Hermes xai-oauth tokens since that reading x fitted % per M tokens
#  rate     = sum(delta %) / sum(M tokens) over consecutive same-cycle readings
#             (and cycle start = 0 %) in the last few cycles. Calibrated on tokens,
#             not calls: per-call cost swung 0.05-0.09 %/call between intervals
#             (context size varies), per-M-token stayed 0.53-0.65 %.
#  target   = left % / days left; pace = used % vs a straight line through the week.
#  midweek  = Mon/Tue PT and behind pace -> warning.
#  endgame  = last 36 h before reset with > 20 % left -> ranked backlog jobs for
#             Hermes on $JOB_MODEL (HelpDesk, open eval proposals, TodoRank todos).
# Pure: callers pass readings, a units callback and the job sources.

use strict;
use warnings;
use POSIX qw(strftime floor);
use Time::Local qw(timelocal);

our $CYCLE_S          = 7 * 86400;
our $DEFAULT_RATE     = 0.60;      # % per M Hermes xai tokens (fit Sep 24-Oct 8 2026: 0.596)
our $FIT_CYCLES       = 3;
our $PACE_BAND        = 5;         # +/- points around the straight line = on pace
our $MIDWEEK_BEHIND   = 10;        # points behind on Mon/Tue -> warn
our $ENDGAME_H        = 36;
our $ENDGAME_LEFT     = 20;
our $METER_STALE_H    = 24;
our $ADDON_DOWN_H     = 2;   # Oct 22 2026: add-on silent > 2 h = down, value not fresh
our $JOB_MODEL        = 'grok-4.7';  # Oct 8 2026: 4.7 fixed the :3001 git push in one pass where grok-build failed (45 calls)
our $TOKENS_PER_CALL  = 160_000;   # grok-4.7 agent call avg 161K tokens, 91% cached (grok-build ~102K)
our @METER_SOURCES    = qw(manual addon spoken screenshot);

# Quota weight per token relative to grok-build-0.1. xAI API list prices
# differ (grok-4.6/4.7 $2.00/$0.50 cached/$6.00 vs grok-build $1.00/$0.20/$2.00),
# but the Super Grok meter does not follow them: fitting 7 reading intervals
# Sep 17-Oct 8 2026 (grok-build 154M, grok-4.6 252M, grok-4.7 54M tokens) gives
# coefficient of variation 0.09 at weight 1.0 vs 0.15 at 1.5 and 0.44 at 2.5.
# So all Grok models count the same per token; the hook stays for re-fitting.
our @MODEL_WEIGHTS = ([qr/grok/ => 1.0]);
sub model_weight {
    my ($m) = @_;
    $m //= '';
    for (@MODEL_WEIGHTS) { return $_->[1] if $m =~ $_->[0] }
    return 1.0;
}

# Long-context weight: xAI bills prompts >= 200K tokens at 2x; the Super Grok
# meter fits best at ~1.3x (Oct 8 2026: 8 intervals, CV 0.06 at 1.3 vs 0.09 at
# 1.0; the 10:31-19:05 PT burn then estimates 41.1% vs the 41% meter reading).
our $LONG_CTX_TOKENS = 200_000;
our $LONG_CTX_WEIGHT = 1.3;
sub call_weight {
    my ($call) = @_;
    my $w = model_weight($call->{model});
    $w *= $LONG_CTX_WEIGHT if ($call->{in} // 0) >= $LONG_CTX_TOKENS;
    return $w;
}

# Burn alerts (Oct 8 2026: 41 points burned 10:31-19:05 PT with no warning).
# Overridable per key from data/supergrok_pacing.json {"alerts": {...}}.
# Oct 11 2026: Shanta works 05:00-12:00 PT, so the "day" is the WORK day
# starting at day_start_hour (default 5) and the old noon ahead-of-pace check is
# replaced by a work-window check: at/after check_hour PT, alert if more than
# budget_fraction of today's daily budget is already gone.
our %ALERT_DEFAULTS = (
    day_rise_pts    => 15,    # used % rise within one work day
    check_hour      => 9,     # work-window check from this PT hour (same work day)
    budget_fraction => 0.6,   # ... alert when used_today > fraction x effective daily budget
);
sub alert_config {
    my ($cfg) = @_;
    my %c = %ALERT_DEFAULTS;
    for (keys %ALERT_DEFAULTS) { $c{$_} = 0 + $cfg->{$_} if ref $cfg eq 'HASH' && defined $cfg->{$_} && $cfg->{$_} =~ /^\d+(?:\.\d+)?$/ }
    return \%c;
}

# Daily Super Grok budget (Oct 9 2026). The switch itself is owned by
# ~/.hermes/scripts/supergrok_daily_guard.py, which reads daily_budget from
# GET /ai/usage_pacing_json; this module only does the arithmetic.
# data/supergrok_pacing.json keys: week_off_at (90), extra_today_pct +
# extra_today_date (YYYY-MM-DD PT), allow_overrun_date (YYYY-MM-DD PT).
our $WEEK_OFF_AT = 90;
our $DAY_START_HOUR = 5;
sub day_start_hour {
    my ($cfg) = @_;
    my $h = ref $cfg eq 'HASH' ? $cfg->{day_start_hour} : undef;
    return (defined $h && $h =~ /^\d+$/ && $h <= 23) ? 0 + $h : $DAY_START_HOUR;
}
# PT date of the work day containing $e (a day starts at $h:00 PT; $h=0 -> calendar day).
sub pt_date {
    my ($e, $h) = @_;
    $h //= $DAY_START_HOUR;
    local $ENV{TZ} = 'America/Los_Angeles'; POSIX::tzset();
    my @l = localtime $e;
    my $d = ($l[2] < $h) ? strftime('%Y-%m-%d', localtime(timelocal(0, 0, 12, @l[3, 4, 5]) - 86400))
                         : strftime('%Y-%m-%d', @l);
    POSIX::tzset();
    return $d;
}

# Pure. in: used, used_day_start, day_from, reset, now, cfg.
sub daily_budget {
    my (%in) = @_;
    my $cfg   = ref $in{cfg} eq 'HASH' ? $in{cfg} : {};
    my $num   = sub { defined $_[0] && $_[0] =~ /^\d+(?:\.\d+)?$/ ? 0 + $_[0] : undef };
    my $woa   = $num->($cfg->{week_off_at}) // $WEEK_OFF_AT;
    my $dsh   = day_start_hour($cfg);
    my $today = pt_date($in{now}, $dsh);
    my $days  = ($in{reset} - $in{day_from}) / 86400;
    $days = 0.25 if $days < 0.25;
    my $budget = ($woa - $in{used_day_start}) / $days;
    $budget = 0 if $budget < 0;
    my $extra = (($cfg->{extra_today_date} // '') eq $today) ? ($num->($cfg->{extra_today_pct}) // 0) : 0;
    my $allow = (($cfg->{allow_overrun_date} // '') eq $today) ? 1 : 0;
    my $eff   = $budget + $extra;
    my $used_today = $in{used} - $in{used_day_start};
    $used_today = 0 if $used_today < 0;
    my $over  = (!$allow && $used_today >= $eff) ? 1 : 0;
    my $week_off = $in{used} >= $woa ? 1 : 0;
    return {
        date => $today, day_start_hour => $dsh, week_off_at => $woa, days_left_at_day_start => sprintf('%.2f', $days),
        used_day_start_pct => sprintf('%.1f', $in{used_day_start}), used_now_pct => sprintf('%.1f', $in{used}),
        budget_pct => sprintf('%.1f', $budget), extra_pct => sprintf('%.1f', $extra),
        effective_budget_pct => sprintf('%.1f', $eff), used_today_pct => sprintf('%.1f', $used_today),
        remaining_today_pct => sprintf('%.1f', ($eff - $used_today > 0 ? $eff - $used_today : 0)),
        allow_overrun => $allow, override_active => (($allow || $extra > 0) ? 1 : 0),
        over => $over, week_off => $week_off, switch_off => (($over || $week_off) ? 1 : 0),
        reason => ($week_off ? sprintf('week %.0f%% >= %s%%', $in{used}, $woa)
                  : $over ? sprintf('today %.1f%% >= budget %.1f%%%s', $used_today, $eff, $extra ? sprintf(' (incl. +%.1f extra)', $extra) : '')
                  : ''),
    };
}

# Start of the work day (h:00 PT, default 05:00) at or before $now.
sub day_start {
    my ($now, $h) = @_;
    $h //= $DAY_START_HOUR;
    local $ENV{TZ} = 'America/Los_Angeles'; POSIX::tzset();
    my @l = localtime $now;
    my $t = timelocal(0, 0, $h, @l[3, 4, 5]);
    if ($t > $now) { my @y = localtime(timelocal(0, 0, 12, @l[3, 4, 5]) - 86400); $t = timelocal(0, 0, $h, @y[3, 4, 5]) }
    POSIX::tzset();
    return $t;
}

# Pure. in: used, used_day_start, day_from (epoch the rise is measured from),
# expected, now, cfg (alert_config). out: [ {kind, level, message} ]
sub burn_alerts {
    my (%in) = @_;
    my $c = alert_config($in{cfg});
    my @a;
    # 2026-10-18: after midnight the 05:00-05:00 work day still belongs to the
    # previous calendar day; its alerts are no longer "today" - send nothing.
    if (defined $in{day_from} && defined $in{now}) {
        local $ENV{TZ} = 'America/Los_Angeles'; POSIX::tzset();
        my ($d0, $d1) = (strftime('%Y-%m-%d', localtime $in{day_from}), strftime('%Y-%m-%d', localtime $in{now}));
        POSIX::tzset();
        return \@a if $d0 ne $d1;
    }
    my $rise = $in{used} - $in{used_day_start};
    my $basis = $in{used_basis} // 'estimate';
    if ($rise > $c->{day_rise_pts}) {
        my $day = defined $in{day_from} ? do { local $ENV{TZ} = 'America/Los_Angeles'; POSIX::tzset();
            my $x = strftime('%a %b %d', localtime $in{day_from}); POSIX::tzset(); $x } : 'today';
        push @a, { kind => 'day_rise', level => 'critical', value => sprintf('%.1f', $rise), basis => $basis,
                   message => sprintf('Super Grok burned %.0f points in the %s work day (since %s; limit %s): now %.0f%% used (%s). Slow down or stop the big sessions.',
                                      $rise, $day, pt($in{day_from}), $c->{day_rise_pts}, $in{used}, $basis) };
    }
    # Work-window check: hours since the work-day start >= check_hour - day_start_hour.
    my $dsh = $in{day_start_hour} // $DAY_START_HOUR;
    my $hrs_in = defined $in{day_from} ? ($in{now} - $in{day_from}) / 3600 : 0;
    my $budget = $in{budget_pct};
    if (defined $budget && $budget > 0 && $hrs_in >= $c->{check_hour} - $dsh) {
        my $frac = $rise / $budget;
        if ($frac > $c->{budget_fraction}) {
            push @a, { kind => 'work_window', level => 'warning', value => sprintf('%.2f', $frac),
                       message => sprintf('By %02d:00 PT %.0f%% of today\'s Super Grok budget is gone (%.1f of %.1f points; limit %.0f%%). Pace the rest of the work window or switch big jobs to glm.',
                                          $c->{check_hour}, 100 * $frac, $rise, $budget, 100 * $c->{budget_fraction}) };
        }
    }
    return \@a;
}

sub _tz { local $ENV{TZ} = 'America/Los_Angeles'; POSIX::tzset(); }

sub pt {
    my ($e) = @_;
    return '' unless defined $e && $e > 0;
    local $ENV{TZ} = 'America/Los_Angeles'; POSIX::tzset();
    return strftime('%a %b %d %H:%M PT', localtime $e);
}

# Default anchor: the Thu Oct 8 2026 10:31 PT reset.
sub default_anchor {
    local $ENV{TZ} = 'America/Los_Angeles'; POSIX::tzset();
    return timelocal(0, 31, 10, 8, 9, 2026);
}

# (cycle_start, reset) containing $now. Weekly in PT wall-clock terms is close
# enough; DST shifts the instant by an hour twice a year and is ignored.
sub cycle_bounds {
    my ($now, $anchor) = @_;
    $anchor //= default_anchor();
    my $k = floor(($now - $anchor) / $CYCLE_S);
    my $start = $anchor + $k * $CYCLE_S;
    return ($start, $start + $CYCLE_S);
}

sub _used { my ($r) = @_; return undef unless $r; return ($r->{kind} // 'used') eq 'left' ? 100 - $r->{value} : $r->{value} }

# Clean, sorted readings; unconfirmed/derived dropped.
sub clean_readings {
    my ($rd) = @_;
    my %seen;
    return [ sort { $a->{at} <=> $b->{at} }
             grep { !$seen{ "$_->{at}|$_->{value}" }++ }
             grep { ref $_ eq 'HASH' && defined $_->{at} && defined $_->{value} && $_->{value} =~ /^\d+(?:\.\d+)?$/
                    && ($_->{kind} // 'used') ne 'unconfirmed' && ($_->{source} // '') ne 'derived' } @{ $rd || [] } ];
}

# fit_rate(readings => [...], units => sub ($from, $to) -> M tokens, now, anchor)
sub fit_rate {
    my (%in) = @_;
    my $now = $in{now} // time;
    my ($cs) = cycle_bounds($now, $in{anchor});
    my $oldest = $cs - $FIT_CYCLES * $CYCLE_S;
    my @rd = grep { $_->{at} >= $oldest && $_->{at} <= $now } @{ clean_readings($in{readings}) };
    my (@pairs, $sd, $su);
    $sd = $su = 0;
    my $prev;
    for my $r (@rd) {
        my ($rcs) = cycle_bounds($r->{at} - 1, $in{anchor});   # reading exactly at reset belongs to the new cycle's start
        ($rcs) = cycle_bounds($r->{at}, $in{anchor}) if _used($r) == 0;
        my $from = ($prev && $prev->{_cs} == $rcs) ? $prev : { at => $rcs, value => 0, kind => 'used', _cs => $rcs, _implicit => 1 };
        my $d = _used($r) - _used($from);
        my $u = $in{units}->($from->{at}, $r->{at});
        if ($r->{at} > $from->{at} && $d >= 0 && defined $u) {
            if ($u > 0.5 || $d > 0) {           # skip empty intervals and unlogged jumps
                if ($u > 0.5) {
                    push @pairs, { from_pt => pt($from->{at}), to_pt => pt($r->{at}), delta => $d, mtok => $u,
                                   rate => $d / $u, implicit_start => $from->{_implicit} ? 1 : 0 };
                    $sd += $d; $su += $u;
                }
            }
        }
        $prev = { %$r, _cs => $rcs };
    }
    my $rate = $su > 0 && $sd > 0 ? $sd / $su : undef;
    return { rate => $rate // ($in{default} // $DEFAULT_RATE), fitted => (defined $rate ? 1 : 0),
             pairs => \@pairs, delta_sum => $sd, mtok_sum => $su };
}

# pacing(now, readings, units => cb, rate, anchor) -> hashref (all numbers rounded for display)
sub pacing {
    my (%in) = @_;
    my $now = $in{now} // time;
    my ($cs, $reset) = cycle_bounds($now, $in{anchor});
    my $rate = $in{rate} // $DEFAULT_RATE;
    my @in_cycle = grep { $_->{at} >= $cs && $_->{at} <= $now } @{ clean_readings($in{readings}) };
    my $base = @in_cycle ? $in_cycle[-1] : { at => $cs, value => 0, kind => 'used', source => 'reset' };
    my $units = $in{units}->($base->{at}, $now) // 0;
    my $used = _used($base) + $units * $rate;
    $used = 100 if $used > 100;
    my $dsh = day_start_hour($in{daily_cfg});
    my $day_from = day_start($now, $dsh);
    $day_from = $cs if $day_from < $cs;
    # Normalized to readings: with a reading on each side of day_from, split the
    # meter delta by weighted tokens (time if no tokens); else extrapolate.
    my $used_day_start = do {
        my @b = grep { $_->{at} <= $day_from } @in_cycle;
        my ($a1) = grep { $_->{at} > $day_from } @in_cycle;
        my $b0 = @b ? $b[-1] : { at => $cs, value => 0, kind => 'used' };
        my $u0;
        if ($a1 && _used($a1) >= _used($b0)) {
            my $tot  = $in{units}->($b0->{at}, $a1->{at}) // 0;
            my $part = $in{units}->($b0->{at}, $day_from) // 0;
            my $f = $tot > 0.5 ? $part / $tot : ($day_from - $b0->{at}) / (($a1->{at} - $b0->{at}) || 1);
            $u0 = _used($b0) + (_used($a1) - _used($b0)) * $f;
        } else {
            $u0 = _used($b0) + ($in{units}->($b0->{at}, $day_from) // 0) * $rate;
        }
        $u0 > 100 ? 100 : $u0;
    };
    my $elapsed = ($now - $cs) / $CYCLE_S;
    my $expected = 100 * $elapsed;
    my $delta = $used - $expected;
    my $left = 100 - $used;
    my $days_left = ($reset - $now) / 86400;
    my $hours_left = $days_left * 24;
    my $target_day = $days_left > 0 ? $left / ($days_left < 0.25 ? 0.25 : $days_left) : $left;
    my $mtok_day = $rate > 0 ? $target_day / $rate : undef;
    my $dow = do { local $ENV{TZ} = 'America/Los_Angeles'; POSIX::tzset(); (localtime $now)[6] };   # 1 Mon, 2 Tue
    my $status = $delta > $PACE_BAND ? 'ahead' : $delta < -$PACE_BAND ? 'behind' : 'on_pace';
    my %o = (
        cycle_start => $cs, cycle_start_pt => pt($cs), reset_at => $reset, reset_pt => pt($reset),
        rate_pct_per_mtok => sprintf('%.3f', $rate),
        base_reading => { at_pt => pt($base->{at}), value => _used($base), source => $base->{source} // '' },
        mtok_since_reading => sprintf('%.1f', $units),
        used_pct => sprintf('%.1f', $used), left_pct => sprintf('%.1f', $left),
        expected_pct => sprintf('%.1f', $expected), pace_delta => sprintf('%+.1f', $delta), pace => $status,
        days_left => sprintf('%.1f', $days_left), hours_left => sprintf('%.1f', $hours_left),
        daily_target_pct => sprintf('%.1f', $target_day),
        daily_target_mtok => (defined $mtok_day ? sprintf('%.0f', $mtok_day) : undef),
        daily_target_calls => (defined $mtok_day ? sprintf('%.0f', $mtok_day * 1e6 / $TOKENS_PER_CALL) : undef),
        warnings => [],
        day_from_pt => pt($day_from), used_day_start_pct => sprintf('%.1f', $used_day_start),
        day_rise_pct => sprintf('%.1f', $used - $used_day_start),
    );
    $o{daily_budget} = daily_budget(used => $used, used_day_start => $used_day_start, day_from => $day_from,
                                    reset => $reset, now => $now, cfg => $in{daily_cfg});
    $o{day_start_hour} = $dsh;
    # 2026-10-18: a grok.com meter value under 2 h old beats the token estimate
    # for the burn alerts (estimate said 44 %, meter 36 %).
    my ($alert_used, $basis) = ($used, 'estimate');
    if (my $m = $in{meter_now}) {
        if (defined $m->{value} && $m->{value} =~ /^\d+(?:\.\d+)?$/ && $m->{at}
            && $m->{at} >= $cs && $now - $m->{at} < 2 * 3600) {
            ($alert_used, $basis) = (0 + $m->{value}, 'meter');
        }
    }
    $o{alerts} = burn_alerts(used => $alert_used, used_basis => $basis, used_day_start => $used_day_start, day_from => $day_from,
                             expected => $expected, now => $now, cfg => $in{alert_cfg},
                             day_start_hour => $dsh, budget_pct => $o{daily_budget}{effective_budget_pct});
    $o{alert_config} = alert_config($in{alert_cfg});
    if (($dow == 1 || $dow == 2) && $delta < -$MIDWEEK_BEHIND) {
        push @{ $o{warnings} }, sprintf('Midweek: Super Grok is %.0f points behind pace (%.0f%% used, %.0f%% expected by now). Use about %.0f%%/day (~%s M tokens, ~%s %s calls) to finish the week.',
            -$delta, $used, $expected, $target_day, $o{daily_target_mtok} // '?', $o{daily_target_calls} // '?', $JOB_MODEL);
        $o{midweek_warning} = 1;
    }
    if ($hours_left <= $ENDGAME_H && $left > $ENDGAME_LEFT) {
        $o{endgame} = 1;
        push @{ $o{warnings} }, sprintf('Last %.0f h before reset with %.0f%% left: run backlog jobs on Hermes %s (ranked list below).', $hours_left, $left, $JOB_MODEL);
    }
    return \%o;
}

# Meter freshness: newest real meter reading (manual / add-on / spoken / screenshot).
sub meter_status {
    my (%in) = @_;
    my $now = $in{now} // time;
    my %ok = map { ($_ => 1) } @METER_SOURCES;
    my @m = grep { $ok{ $_->{source} // '' } } @{ clean_readings($in{readings}) };
    my $last = $m[-1];
    # Oct 20 2026: history only gets a row when the value changes; the add-on still
    # posts unchanged values (grokcom_usage.json 'at' = last seen). Fresher wins.
    my $ls = $in{last_seen};
    if ($ls && defined $ls->{at} && defined $ls->{value} && $ls->{value} =~ /^-?\d+(?:\.\d+)?$/
        && (!$last || $ls->{at} > $last->{at})) {
        $last = { at => $ls->{at}, value => $ls->{value}, kind => 'used', source => 'addon' };
    }
    my $age_h = $last ? ($now - $last->{at}) / 3600 : undef;
    my $addon_age_h = ($ls && defined $ls->{at}) ? ($now - $ls->{at}) / 3600 : $age_h;
    my $addon_down = !defined $addon_age_h || $addon_age_h > $ADDON_DOWN_H ? 1 : 0;
    my $stale = !defined $age_h || $age_h > $METER_STALE_H ? 1 : 0;
    my $fresh = (!$stale && defined $age_h && $age_h <= $ADDON_DOWN_H) ? 1 : 0;
    return {
        addon_down => $addon_down, fresh => $fresh, addon_down_after_h => $ADDON_DOWN_H,
        ($addon_down ? (addon_status => sprintf('Super Grok add-on down: no post for %s; last value not fresh',
                                                defined $addon_age_h ? sprintf('%.1f h', $addon_age_h) : 'ever')) : (addon_status => 'ok')),
        last_at_pt => ($last ? pt($last->{at}) : 'never'), last_value => _used($last), last_source => ($last ? $last->{source} : undef),
        age_h => (defined $age_h ? sprintf('%.1f', $age_h) : undef), stale => $stale, stale_after_h => $METER_STALE_H,
        ($stale ? (prompt => sprintf('Super Grok meter has not reported for %s (last: %s). Please enter a manual reading from grok.com Settings > Usage.',
                                     defined $age_h ? sprintf('%.0f h', $age_h) : 'ever', $last ? pt($last->{at}) . " $last->{value}%" : 'none'),
                   form_url => '/ai/usage#usage-estimator') : ()),
    };
}

# Ranked backlog jobs. in: tickets [{id, number, subject, priority, status}],
# proposals [{id, title, status, change_type}], todos [{id, subject, rank_score, priority}]
our %TICKET_PRI = (critical => 3.0, urgent => 3.0, high => 2.5, medium => 1.6, normal => 1.6, low => 1.0);
sub recommend_jobs {
    my (%in) = @_;
    my $limit = $in{limit} // 12;
    my @jobs;
    for my $t (@{ $in{tickets} || [] }) {
        my $s = $TICKET_PRI{ lc($t->{priority} // 'medium') } // 1.6;
        push @jobs, { kind => 'helpdesk', id => $t->{id}, title => "HelpDesk $t->{number}: $t->{subject}",
                      url => "/HelpDesk/ticket/view/$t->{number}", score => $s, why => 'open ticket, priority ' . ($t->{priority} // 'medium') };
    }
    for my $p (@{ $in{proposals} || [] }) {
        next if ($p->{change_type} // '') eq 'config';        # config proposals are applied on /ai/eval, not coded
        my $s = ($p->{status} // '') eq 'approved' ? 2.2 : 1.3;
        push @jobs, { kind => 'eval_proposal', id => $p->{id}, title => "Eval proposal: $p->{title}",
                      url => "/ai/eval/report/" . ($p->{report_id} // ''), score => $s, why => "open eval proposal ($p->{status})" };
    }
    my @todos = sort { ($b->{rank_score} // -1) <=> ($a->{rank_score} // -1) } @{ $in{todos} || [] };
    my $i = 0;
    for my $t (@todos) {
        $i++;
        my $s = defined $t->{rank_score} ? 1.0 + $t->{rank_score} : 0.8;   # TodoRank/DecisionRank blended score (0-1.5)
        push @jobs, { kind => 'todo', id => $t->{id}, title => "Todo #$t->{id}: $t->{subject}",
                      url => "/todo/details?record_id=$t->{id}", score => $s,
                      why => defined $t->{rank_score} ? sprintf('TodoRank #%d (score %.2f)%s', $i, $t->{rank_score}, $t->{reason} ? " - $t->{reason}" : '') : 'open todo (unranked)' };
    }
    @jobs = sort { $b->{score} <=> $a->{score} || ($a->{kind} cmp $b->{kind}) } @jobs;
    splice @jobs, $limit if @jobs > $limit;
    my $n = 0;
    $_->{rank} = ++$n, $_->{score} = sprintf('%.2f', $_->{score}) for @jobs;
    return \@jobs;
}

# One Hermes command line per job (shown for copy/paste; never run from the page).
sub hermes_command {
    my ($job, %o) = @_;
    my $wt = $o{worktree} // '~/.comserv/worktrees/aisystem/Comserv/Comserv';
    (my $title = $job->{title} // '') =~ s/["`\$\\]//g;
    return sprintf(q{cd %s && hermes chat -Q --oneshot --provider xai-oauth -m %s -t file,terminal --max-turns %d --query "%s (%s). Keep changes uncommitted; add tests."},
        $wt, $o{model} // $JOB_MODEL, $o{max_turns} // 40, $title, $job->{url} // '');
}

1;
