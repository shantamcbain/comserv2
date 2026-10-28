package Comserv::Util::AI::ModelTrial;
# Model trial guard (Oct 26 2026, Shanta: Kimi k2.7-code trial from reserve, hard cap $6, 20 tasks).
# Pure cap/stop logic for a trial defined under "trials" in data/ai_model_chains.json (see ModelChains->trial).
# Oct 28 2026 (Shanta): spend is the TRIAL MODEL'S OWN cost (model_cost: Hermes state.db session_model_usage rows for that
# model since the baseline taken before task 1), not all OpenRouter spend. The Kimi trial wrongly counted every OpenRouter
# dollar since its baseline ($10.15 vs about $3.56 of its own). spent() is kept only as the old whole-account figure. A trial is selectable only by an explicit trial run
# (script/ai_trial.pl); nothing here is ever consulted by a router or fallback.
use strict;
use warnings;

# LEGACY (whole OpenRouter account, not a trial's own spend; no longer used for caps): the larger of the month_usd rise and the balance drop since the baseline (so a lagging counter cannot hide spend)
sub spent {
    my ($baseline, $now) = @_;
    return 0 unless ref $baseline eq 'HASH' && ref $now eq 'HASH';
    my $m = (defined $now->{month_usd}   && defined $baseline->{month_usd})   ? $now->{month_usd} - $baseline->{month_usd} : 0;
    my $b = (defined $baseline->{balance_usd} && defined $now->{balance_usd}) ? $baseline->{balance_usd} - $now->{balance_usd} : 0;
    my $s = $m > $b ? $m : $b;
    return $s > 0 ? 0 + sprintf('%.4f', $s) : 0;
}

# model_cost($state_db, $model, $since [, $until]) -> USD spent by that one model on sessions first seen in [$since, $until],
# from Hermes state.db session_model_usage (read-only; per row the larger of actual and estimated cost). undef when unreadable.
sub model_cost {
    my ($db, $model, $since, $until) = @_;
    return undef unless defined $db && -f $db && defined $model && length $model;
    return eval {
        require DBI;
        my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, PrintError => 0, sqlite_open_flags => 1 });
        my $sql = q{SELECT COALESCE(SUM(CASE WHEN COALESCE(actual_cost_usd, 0) > COALESCE(estimated_cost_usd, 0)
                                             THEN actual_cost_usd ELSE estimated_cost_usd END), 0)
                      FROM session_model_usage WHERE model = ? AND first_seen >= CAST(? AS REAL)};
        my @b = ($model, $since // 0);
        if (defined $until) { $sql .= ' AND first_seen <= CAST(? AS REAL)'; push @b, $until }
        my ($c) = $dbh->selectrow_array($sql, undef, @b);
        $dbh->disconnect;
        0 + sprintf('%.4f', $c // 0);
    };
}

# evaluate(trial => {...}, spent => $usd, tasks_done => N, alerted => 0|1, bot_pct => N|undef, live_ok => 0|1)
# -> { action => 'run'|'stop', reason, spent, alert => 0|1 (post the one-time spend check now) }
sub evaluate {
    my (%in) = @_;
    my $t = $in{trial} or return { action => 'stop', reason => 'no trial settings', spent => 0, alert => 0 };
    my $spent = $in{spent} // 0;
    my ($cap, $alert_at, $max, $res, $botstop) = @$t{qw(hard_cap_usd alert_at_usd max_tasks reserve_per_task_usd bot_usage_stop_pct)};
    $res //= 0; $botstop //= 95; $alert_at //= $cap;
    # Oct 28 2026 (Shanta): PROBATION (trial.probation = 1): the model is the paid chain step while it is audited. Its limits are
    # hard_cap_usd (its OWN spend) and max_tasks (sessions); reaching EITHER stops it (the stop notice is the one alert) and it stays
    # stopped, out of the chain, until Shanta approves the audit (script/ai_trial.pl approve). No reserve-per-task or alert_at rule.
    if ($t->{probation}) {
        my $tasks = $in{tasks_done} // 0;
        my $pstop = sub { return { action => 'stop', reason => $_[0], spent => $spent, alert => 0, probation => 1 } };
        return $pstop->(sprintf('probation limit reached: $%.2f of $%s spent', $spent, $cap + 0) . ' - audit due, awaiting Shanta\'s approval') if $spent >= $cap;
        return $pstop->("probation limit reached: $tasks of $max sessions - audit due, awaiting Shanta's approval") if $tasks >= $max;
        return $pstop->('OpenRouter live usage unreadable: cannot count spend') unless $in{live_ok};
        return $pstop->(sprintf('Bot usage %s%% is over %s%%', $in{bot_pct}, $botstop)) if defined $in{bot_pct} && $in{bot_pct} > $botstop;
        return { action => 'run', reason => sprintf('probation: $%.2f of $%s, session %d of %d', $spent, $cap + 0, $tasks + 1, $max), spent => $spent, alert => 0, probation => 1 };
    }
    my $alert = (!$in{alerted} && $spent >= $alert_at) ? 1 : 0;
    my $stop = sub { return { action => 'stop', reason => $_[0], spent => $spent, alert => $alert } };
    return $stop->('OpenRouter live usage unreadable: cannot count spend, so no task is started') unless $in{live_ok};
    return $stop->(sprintf('hard cap reached: $%.2f of $%s', $spent, $cap + 0)) if $spent >= $cap;
    return $stop->("task limit reached: $in{tasks_done} of $max") if ($in{tasks_done} // 0) >= $max;
    return $stop->(sprintf('Bot usage %s%% is over %s%%', $in{bot_pct}, $botstop)) if defined $in{bot_pct} && $in{bot_pct} > $botstop;
    return $stop->(sprintf('next task could pass the cap: $%.2f spent + $%s reserve for one task is over $%s', $spent, $res + 0, $cap + 0)) if $spent + $res > $cap;
    return { action => 'run', reason => sprintf('$%.2f of $%s, task %d of %d', $spent, $cap + 0, ($in{tasks_done} // 0) + 1, $max), spent => $spent, alert => $alert };
}

# exclude_from_or($or, $usd) -> copy of an OpenRouter reading with an approved trial's spend taken out of day/week/month
# so the overrun guard's caps do not trip (and switch Hermes) because of money Shanta approved from reserve.
# $usd is one number (taken out of all three windows) or { day =>, week =>, month => } (this trial model's own spend inside
# each window, so a trial that ran on Oct 26 is not taken out of today's figure).
sub exclude_from_or {
    my ($or, $usd) = @_;
    return $or unless ref $or eq 'HASH' && $or->{ok} && $usd;
    my %by = ref $usd eq 'HASH' ? %$usd : (day => $usd, week => $usd, month => $usd);
    return $or unless grep { ($by{$_} // 0) > 0 } keys %by;
    my %o = %$or;
    for my $k (qw(day week month)) {
        next unless defined $o{"${k}_usd"} && ($by{$k} // 0) > 0;
        my $v = $o{"${k}_usd"} - $by{$k};
        $o{"${k}_usd"} = $v > 0 ? $v : 0;
    }
    $o{trial_excluded_usd} = $by{month} // $by{day} // 0;
    $o{trial_excluded_by_window} = { %by };
    return \%o;
}

1;
