package Comserv::Util::AI::ModelScorecard;

# Model scorecard (Oct 10 2026): per model x task type - sessions, calls, data
# requests (tool calls), thrash, wall time, tokens, $ and Super Grok quota,
# outcome and quality signals, and a "cost per result" rating with editable
# weights (data/ai_model_scorecard.json). Pure functions only; the collector is
# Comserv::Model::AI2::ModelScorecard.
#
# HONESTY: task type, outcome, correction, clarification and quality signals
# are HEURISTICS (title/cwd regexes, phrase matching, git commits in the
# session window, test output text). Tokens, calls, timings and OpenRouter
# cost come from Hermes logs/state.db and are measured.

use strict;
use warnings;
use List::Util qw(sum0 min max);
use POSIX qw(floor);

our %DEFAULT_CFG = (
    days          => 14,
    weights       => { time => 1, cost => 1, quality => 2 },
    quota_pct_usd => 0.07,     # Super Grok: ~$30/month => 100%/week ~ $7 => 1% ~ $0.07 (editable)
    quota_pct_per_mtok => 0.57,
    long_ctx_tokens => 200_000,
    long_ctx_weight => 1.3,
    min_turns_for_rating => 3,
);

our @TASK_TYPES = qw(coding runtime_debug chat todo_rank aux benchmark);

our @CORRECTION_RE = (
    qr/\bno[,.!]\s/i, qr/\bnot (?:that|what|hermes|the)\b/i, qr/\bwrong\b/i, qr/\bi said\b/i,
    qr/\bstill (?:not|doesn|broken|fail|missing|no)\b/i, qr/\bdoesn'?t work\b/i, qr/\bdidn'?t (?:work|fix)\b/i,
    qr/\bthat'?s not\b/i, qr/\bstop\b/i, qr/\bundo\b/i, qr/\brevert\b/i, qr/\byou (?:broke|ignored)\b/i,
    qr/\bagain\b.*\b(?:fail|error|broken)\b/i, qr/\bis main\b/i,
);
our @CLARIFY_RE = (
    qr/\b(?:do|would|should) you (?:want|like|prefer)\b/i, qr/\bshould i\b/i, qr/\bwhich (?:one|option|worktree|branch|file)\b/i,
    qr/\bcould you (?:clarify|confirm|tell)\b/i, qr/\bcan you confirm\b/i, qr/\bdo you mean\b/i,
);

sub cfg_merge {
    my ($c) = @_;
    my %o = %DEFAULT_CFG;
    $o{weights} = { %{ $DEFAULT_CFG{weights} } };
    return \%o unless ref $c eq 'HASH';
    for my $k (qw(days quota_pct_usd quota_pct_per_mtok long_ctx_tokens long_ctx_weight min_turns_for_rating)) {
        $o{$k} = 0 + $c->{$k} if defined $c->{$k} && $c->{$k} =~ /^\d+(?:\.\d+)?$/;
    }
    if (ref $c->{weights} eq 'HASH') {
        for my $k (qw(time cost quality)) {
            $o{weights}{$k} = 0 + $c->{weights}{$k} if defined $c->{weights}{$k} && $c->{weights}{$k} =~ /^\d+(?:\.\d+)?$/;
        }
    }
    $o{days} = 1 if $o{days} < 1; $o{days} = 60 if $o{days} > 60;
    return \%o;
}

# classify_task(title, source, cwd, aux_task) -> task type (heuristic)
sub classify_task {
    my (%a) = @_;
    my $t = lc($a{title} // '');
    return 'aux' if ($a{aux_task} // '') =~ /\S/;
    return 'benchmark' if ($a{cwd} // '') =~ m{^/tmp/r\d+/bench};
    return 'todo_rank' if $t =~ /\b(?:rank|todo|decision|priorit)/;
    return 'runtime_debug' if $t =~ /\b(?:fix|debug|error|not working|missing|fail|stall|upgrade|xorg|install|git|upstream|push|crash|broken|warning|unauthori[sz]ed|restore|why)\b/;
    return 'coding' if $t =~ /\b(?:add|create|build|implement|feature|module|parse|compute|manage|refactor|write|test|plan|resume|update)\b/;
    return 'coding' if ($a{source} // '') eq 'oneshot';
    return 'chat';
}

sub correction_count {
    my (@texts) = @_;
    my $n = 0;
    for my $t (@texts) {
        next unless defined $t && length $t && length $t < 4000;   # skip pasted logs
        $n++ if grep { $t =~ $_ } @CORRECTION_RE;
    }
    return $n;
}

sub clarify_count {
    my (@texts) = @_;
    my $n = 0;
    for my $t (@texts) {
        next unless defined $t && $t =~ /\?\s*\z|\?\s*\n/;
        $n++ if grep { $t =~ $_ } @CLARIFY_RE;
    }
    return $n;
}

# thrash episodes: >= 3 consecutive identical tool calls (name + args).
sub thrash_episodes {
    my (@sigs) = @_;
    my ($n, $run, $prev) = (0, 0, '');
    for my $s (@sigs) {
        if ($s eq $prev) { $run++; $n++ if $run == 3 } else { $run = 1; $prev = $s }
    }
    return $n;
}

# tests signal from tool outputs: (pass, fail)
sub test_signals {
    my (@outs) = @_;
    my ($p, $f) = (0, 0);
    for my $o (@outs) {
        next unless defined $o;
        $p++ if $o =~ /\bResult: PASS\b|\bAll tests successful\b|\b\d+ passed\b(?!.*\bfailed\b)/;
        $f++ if $o =~ /\bResult: FAIL\b|\bFailed \d+\/\d+|\b\d+ failed\b|\bnot ok \d+/;
    }
    return ($p, $f);
}

# outcome for a session (heuristic)
sub outcome {
    my (%s) = @_;
    return 'committed' if ($s{commits} // 0) > 0;
    return 'abandoned' if !$s{stop_turns} || ($s{last_role} // '') eq 'user';
    return 'user_corrected' if ($s{corrections} // 0) >= 2;
    return 'completed';
}

sub median {
    my @v = sort { $a <=> $b } grep { defined } @_;
    return undef unless @v;
    return @v % 2 ? $v[$#v / 2] : ($v[$#v / 2] + $v[$#v / 2 + 1]) / 2;
}

# aggregate(segments => [...], cfg) -> { rows => [...], models => {...} }
# segment: { session, model, provider, task, calls, tool_calls, tokens_in, tokens_out,
#   tokens_cache, weighted_mtok, active_s, turns => [secs...], stop_turns, max_iter_turns,
#   interrupted_turns, thrash, usd, corrections, clarifications, tests_pass, tests_fail,
#   commits, reverts, outcome }
sub aggregate {
    my (%in) = @_;
    my $cfg = cfg_merge($in{cfg});
    my %g;
    for my $s (@{ $in{segments} || [] }) {
        my $k = "$s->{model}\t$s->{task}";
        my $r = $g{$k} ||= { model => $s->{model}, provider => $s->{provider}, task => $s->{task},
                             sessions => {}, outcomes => {}, turn_secs => [] };
        $r->{sessions}{ $s->{session} } = 1;
        $r->{$_} += ($s->{$_} // 0) for qw(calls tool_calls tokens_in tokens_out tokens_cache weighted_mtok active_s
                                             stop_turns max_iter_turns interrupted_turns thrash usd corrections
                                             clarifications tests_pass tests_fail commits reverts);
        push @{ $r->{turn_secs} }, @{ $s->{turns} || [] };
        $r->{outcomes}{ $s->{outcome} // 'unknown' }++;
    }
    my @rows;
    for my $r (values %g) {
        my $n = scalar keys %{ $r->{sessions} };
        my $quota = $r->{provider} =~ /^(?:xai-oauth|xai|supergrok)$/ ? $r->{weighted_mtok} * $cfg->{quota_pct_per_mtok} : 0;
        my $turns = $r->{stop_turns} + $r->{max_iter_turns} + $r->{interrupted_turns};
        my $good  = ($r->{outcomes}{completed} // 0) + ($r->{outcomes}{committed} // 0);
        my $q = 100 * ($n ? $good / $n : 0);
        $q -= 15 * ($r->{outcomes}{user_corrected} // 0) / ($n || 1);
        $q -= 20 * ($turns ? $r->{max_iter_turns} / $turns : 0);
        $q -= 5 * min(4, $r->{thrash} / ($n || 1));
        $q += 10 * ($r->{tests_pass} + $r->{tests_fail} ? ($r->{tests_pass} - $r->{tests_fail}) / ($r->{tests_pass} + $r->{tests_fail}) : 0);
        $q -= 20 * min(1, $r->{reverts});
        $q = max(0, min(100, $q));
        my $eff_usd = $r->{usd} + $quota * $cfg->{quota_pct_usd};
        my $med = median(@{ $r->{turn_secs} });
        push @rows, {
            model => $r->{model}, provider => $r->{provider}, task => $r->{task},
            sessions => $n, calls => $r->{calls}, data_requests => $r->{tool_calls}, thrash => $r->{thrash},
            wall_h => sprintf('%.2f', $r->{active_s} / 3600),
            tokens_m => sprintf('%.2f', ($r->{tokens_in} + $r->{tokens_out}) / 1e6),
            cached_pct => ($r->{tokens_in} ? sprintf('%.0f', 100 * $r->{tokens_cache} / $r->{tokens_in}) : '0'),
            usd => sprintf('%.2f', $r->{usd}), quota_pct => sprintf('%.1f', $quota), eff_usd => sprintf('%.2f', $eff_usd),
            turns => $turns, stop_turns => $r->{stop_turns}, max_iter_turns => $r->{max_iter_turns},
            median_turn_s => (defined $med ? sprintf('%.0f', $med) : undef),
            outcomes => $r->{outcomes}, corrections => $r->{corrections}, clarifications => $r->{clarifications},
            tests_pass => $r->{tests_pass}, tests_fail => $r->{tests_fail}, commits => $r->{commits}, reverts => $r->{reverts},
            quality => sprintf('%.0f', $q),
            cost_per_result => sprintf('%.2f', $eff_usd / max(1, $good)),
            time_per_result_min => sprintf('%.1f', $r->{active_s} / 60 / max(1, $good)),
            good => $good,
        };
    }
    _rate(\@rows, $cfg);
    @rows = sort { $a->{task} cmp $b->{task} || ($b->{rating} // -1) <=> ($a->{rating} // -1) || $b->{calls} <=> $a->{calls} } @rows;
    return { rows => \@rows, cfg => $cfg };
}

# Ratings are relative within a task type: best time/cost in that task = 100.
sub _rate {
    my ($rows, $cfg) = @_;
    my $w = $cfg->{weights};
    my $ws = ($w->{time} + $w->{cost} + $w->{quality}) || 1;
    my %by;
    push @{ $by{ $_->{task} } }, $_ for @$rows;
    for my $task (keys %by) {
        my @r = grep { $_->{turns} >= $cfg->{min_turns_for_rating} } @{ $by{$task} };
        my $tmin = min(map { $_->{time_per_result_min} } @r) // 0;
        my $cmin = min(map { $_->{cost_per_result} } @r) // 0;
        for my $x (@{ $by{$task} }) {
            if ($x->{turns} < $cfg->{min_turns_for_rating}) { $x->{rating} = undef; $x->{rating_note} = 'too few turns'; next }
            my $ts = 100 * ($tmin + 1) / ($x->{time_per_result_min} + 1);
            my $cs = 100 * ($cmin + 0.05) / ($x->{cost_per_result} + 0.05);
            $x->{time_score} = sprintf('%.0f', $ts);
            $x->{cost_score} = sprintf('%.0f', $cs);
            $x->{rating} = sprintf('%.0f', ($w->{time} * $ts + $w->{cost} * $cs + $w->{quality} * $x->{quality}) / $ws);
        }
    }
}

1;
