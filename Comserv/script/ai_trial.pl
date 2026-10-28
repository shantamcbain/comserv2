#!/usr/bin/env perl
# Explicit model-trial runner support (Oct 26 2026). Never part of a fallback.
#   perl script/ai_trial.pl begin  kimi_k27_code        record the OpenRouter baseline (once, before task 1)
#   perl script/ai_trial.pl check  kimi_k27_code        spend + stop check; posts the one-time spend alert; prints JSON
#   perl script/ai_trial.pl record kimi_k27_code JSON   count a finished task (JSON object is appended to the trial log)
#   perl script/ai_trial.pl status kimi_k27_code
# State and log: data/ai_trials/<name>.state.json and <name>.tasks.jsonl (runtime data, not committed). No keys are read or printed.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use JSON::PP ();
use HTTP::Tiny;
use Comserv::Util::AI::ModelChains;
use Comserv::Util::AI::ModelTrial;
use Comserv::Util::AI::HermesOverrunGuard;
use Comserv::Util::Logging;

my $J = JSON::PP->new->canonical->utf8;
my ($cmd, $name, $arg) = @ARGV;
die "usage: $0 begin|check|record|status NAME [JSON]\n" unless $cmd && $name;
my $root = "$Bin/..";
my $dir  = "$root/data/ai_trials";
mkdir $dir unless -d $dir;
my $sf = "$dir/$name.state.json";

sub fail { my ($m) = @_; eval { Comserv::Util::Logging->instance->log_with_details(undef, 'error', __FILE__, __LINE__, 'ai_trial', $m) }; print $J->encode({ ok => 0, error => $m }), "\n"; exit 1 }
sub rd { my ($f) = @_; open my $fh, '<', $f or return undef; local $/; my $d = eval { $J->decode(<$fh>) }; $d }
sub wr { my ($f, $d) = @_; open my $fh, '>', "$f.tmp" or fail("cannot write $f: $!"); print $fh $J->encode($d); close $fh; rename "$f.tmp", $f or fail("rename $f: $!") }

my $ld = Comserv::Util::AI::ModelChains->load(undef, path => "$root/data/ai_model_chains.json");
my $trial = Comserv::Util::AI::ModelChains->trial($ld, $name) or fail("trial '$name' missing or invalid in data/ai_model_chains.json");
my $guard = Comserv::Util::AI::HermesOverrunGuard->new(app_root => $root);
my $st = rd($sf) || {};

sub live {
    my $o = $guard->openrouter_status;
    return ($o && $o->{ok}) ? $o : undef;
}
sub bot_pct {
    my $r = HTTP::Tiny->new(timeout => 90)->get('http://127.0.0.1:4006/ai/usage_pacing_json');
    return undef unless $r->{success};
    my $d = eval { $J->decode($r->{content}) } or return undef;
    return ref $d->{grok_bot} eq 'HASH' ? $d->{grok_bot}{used_pct} : undef;
}

if ($cmd eq 'begin') {
    fail('baseline already recorded (refusing to reset it)') if $st->{baseline};
    my $o = live() or fail('OpenRouter live usage unreadable; baseline not recorded');
    $st = { name => $name, model => $trial->{model}, baseline => { map { $_ => $o->{$_} } qw(month_usd week_usd day_usd balance_usd) },
            baseline_at => time, tasks_done => 0, alerted => 0 };
    wr($sf, $st);
    print $J->encode({ ok => 1, baseline => $st->{baseline} }), "\n";
}
elsif ($cmd eq 'check' || $cmd eq 'status') {
    fail('no baseline: run begin first') unless $st->{baseline};
    my $o = live();
    my $spent = $o ? Comserv::Util::AI::ModelTrial::spent($st->{baseline}, $o) : ($st->{last_spent} // 0);
    my $bp = bot_pct();
    my $e = Comserv::Util::AI::ModelTrial::evaluate(trial => $trial, spent => $spent, tasks_done => $st->{tasks_done},
                                                    alerted => $st->{alerted}, bot_pct => $bp, live_ok => $o ? 1 : 0);
    if ($cmd eq 'check') {
        $st->{last_spent} = $spent; $st->{last_checked_at} = time;
        $st->{exclude_usd} = $spent if $spent > ($st->{exclude_usd} // 0);   # the overrun guard leaves this out of the OpenRouter caps
        if ($e->{alert}) {
            # same alert path as the overrun guard's state changes (notify_change dedupes on state)
            my $fired = $guard->notify_change($st, 'trial', $name, "Model trial $name: \$3 spend check",
                sprintf('%s: $%.2f spent of $%s after %d tasks (OpenRouter live figures). Hard stop at $%s.', $trial->{model}, $spent, $trial->{hard_cap_usd}, $st->{tasks_done}, $trial->{hard_cap_usd}), 'alert_at');
            $st->{alerted} = 1;   # the spend check is posted once, ever
            $e->{alert_posted} = $fired ? 1 : 0;
        }
        if ($e->{action} eq 'stop' && !$st->{stopped}) {
            $st->{stopped} = $e->{reason};
            $guard->notify_change($st, 'trial_stop', $name, "Model trial $name STOPPED", "$e->{reason}. Spent \$" . sprintf('%.2f', $spent) . " after $st->{tasks_done} tasks.", 'stop');
        }
        wr($sf, $st);
    }
    $e->{tasks_done} = $st->{tasks_done}; $e->{bot_pct} = $bp; $e->{stopped} = $st->{stopped} if $st->{stopped};
    print $J->encode($e), "\n";
}
elsif ($cmd eq 'record') {
    fail('no baseline: run begin first') unless $st->{baseline};
    my $rec = eval { $J->decode($arg // '{}') } or fail('record needs a JSON object');
    my $o = live();
    $rec->{at} = time; $rec->{task_no} = $st->{tasks_done} + 1;
    $rec->{spent_total_usd} = $o ? Comserv::Util::AI::ModelTrial::spent($st->{baseline}, $o) : $st->{last_spent};
    open my $lf, '>>', "$dir/$name.tasks.jsonl" or fail("cannot append log: $!");
    print $lf $J->encode($rec), "\n"; close $lf;
    $st->{tasks_done}++;
    $st->{exclude_usd} = $rec->{spent_total_usd} if ($rec->{spent_total_usd} // 0) > ($st->{exclude_usd} // 0);
    wr($sf, $st);
    print $J->encode({ ok => 1, tasks_done => $st->{tasks_done}, spent_total_usd => $rec->{spent_total_usd} }), "\n";
}
else { fail("unknown command $cmd") }
