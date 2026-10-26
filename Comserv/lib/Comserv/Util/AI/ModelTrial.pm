package Comserv::Util::AI::ModelTrial;
# Model trial guard (Oct 26 2026, Shanta: Kimi k2.7-code trial from reserve, hard cap $6, 20 tasks).
# Pure cap/stop logic for a trial defined under "trials" in data/ai_model_chains.json (see ModelChains->trial).
# Spend is counted from the OpenRouter live figures the overrun guard reads (/ai/usage_live month_usd and
# balance_usd) against a baseline taken before task 1. A trial is selectable only by an explicit trial run
# (script/ai_trial.pl); nothing here is ever consulted by a router or fallback.
use strict;
use warnings;

# spent: the larger of the month_usd rise and the balance drop since the baseline (so a lagging counter cannot hide spend)
sub spent {
    my ($baseline, $now) = @_;
    return 0 unless ref $baseline eq 'HASH' && ref $now eq 'HASH';
    my $m = (defined $now->{month_usd}   && defined $baseline->{month_usd})   ? $now->{month_usd} - $baseline->{month_usd} : 0;
    my $b = (defined $baseline->{balance_usd} && defined $now->{balance_usd}) ? $baseline->{balance_usd} - $now->{balance_usd} : 0;
    my $s = $m > $b ? $m : $b;
    return $s > 0 ? 0 + sprintf('%.4f', $s) : 0;
}

# evaluate(trial => {...}, spent => $usd, tasks_done => N, alerted => 0|1, bot_pct => N|undef, live_ok => 0|1)
# -> { action => 'run'|'stop', reason, spent, alert => 0|1 (post the one-time spend check now) }
sub evaluate {
    my (%in) = @_;
    my $t = $in{trial} or return { action => 'stop', reason => 'no trial settings', spent => 0, alert => 0 };
    my $spent = $in{spent} // 0;
    my ($cap, $alert_at, $max, $res, $botstop) = @$t{qw(hard_cap_usd alert_at_usd max_tasks reserve_per_task_usd bot_usage_stop_pct)};
    $res //= 0; $botstop //= 95;
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
sub exclude_from_or {
    my ($or, $usd) = @_;
    return $or unless ref $or eq 'HASH' && $or->{ok} && $usd && $usd > 0;
    my %o = %$or;
    for my $k (qw(day_usd week_usd month_usd)) {
        next unless defined $o{$k};
        my $v = $o{$k} - $usd;
        $o{$k} = $v > 0 ? $v : 0;
    }
    $o{trial_excluded_usd} = $usd;
    return \%o;
}

1;
