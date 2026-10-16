package Comserv::Util::AI::TaskGrouper;

# Hermes session -> task grouping (Oct 12 2026, eval #33). Pure functions, no
# I/O; the reader is Comserv::Model::AI2::TaskTracker.
#
# A "task" is one piece of work the user asked for. Rules (heuristic):
#   - Child sessions (parent_session_id present in the set) continue the
#     parent's chain (resume / compression / handoff).
#   - A new task starts at a user message that comes more than gap_min
#     minutes after the previous message in the chain, or at the first user
#     message of a chain.
#   - Active minutes = sum of gaps between consecutive messages, each capped
#     at idle_min (gaps longer than that count as idle and add nothing).
#   - $ and tokens: each session's totals are split across its tasks by the
#     number of assistant messages the task holds in that session.

use strict;
use warnings;
use JSON::PP ();
use Comserv::Util::AI::ModelScorecard;

my $J = JSON::PP->new->allow_nonref;

our %DEFAULTS = (gap_min => 30, idle_min => 10, prompt_chars => 300, max_prompts => 8, rewrite_threshold => 3);

sub _root {
    my ($sessions, $sid) = @_;
    my %seen;
    while (my $p = ($sessions->{$sid} || {})->{parent_session_id}) {
        last unless $sessions->{$p};
        last if $seen{$p}++;
        $sid = $p;
    }
    return $sid;
}

# edited file paths from one assistant message's tool_calls JSON
sub edited_paths {
    my ($tool_calls) = @_;
    return () unless defined $tool_calls && length $tool_calls;
    my $tc = eval { $J->decode($tool_calls) };
    return () unless ref $tc eq 'ARRAY';
    my @p;
    for my $x (@$tc) {
        my $f = ref $x eq 'HASH' ? ($x->{function} || $x) : next;
        next unless ($f->{name} // '') =~ /^(?:patch|write_file|edit_file|str_replace)$/;
        my $a = ref $f->{arguments} ? $f->{arguments} : eval { $J->decode($f->{arguments} // '{}') };
        next unless ref $a eq 'HASH';
        my $path = $a->{path} // $a->{file_path} // $a->{filename};
        push @p, $path if defined $path && length $path;
    }
    return @p;
}

sub tool_call_count {
    my ($tool_calls) = @_;
    return 0 unless defined $tool_calls && length $tool_calls;
    my $tc = eval { $J->decode($tool_calls) };
    return ref $tc eq 'ARRAY' ? scalar @$tc : 0;
}

# group(sessions => {id => {...}}, msgs => {sid => [ {role, content, tool_calls, timestamp} ]},
#       usage => {sid => { usd, tokens, models => [..] }}, cfg => {...}) -> [ task, ... ]
sub group {
    my (%a) = @_;
    my $cfg = { %DEFAULTS, %{ $a{cfg} || {} } };
    my $sessions = $a{sessions} || {};
    my $msgs     = $a{msgs}     || {};
    my $usage    = $a{usage}    || {};

    my %chain;
    for my $sid (keys %$msgs) {
        my $root = _root($sessions, $sid);
        push @{ $chain{$root} }, map { { %$_, session => $sid } } @{ $msgs->{$sid} };
    }

    my @tasks;
    my %asst_in;   # sid -> total assistant msgs
    for my $root (sort keys %chain) {
        my @m = sort { $a->{timestamp} <=> $b->{timestamp} } @{ $chain{$root} };
        my ($cur, $prev_t);
        for my $m (@m) {
            my $t = $m->{timestamp} || 0;
            my $gap = defined $prev_t ? ($t - $prev_t) : undef;
            if ($m->{role} eq 'user' && (!$cur || (defined $gap && $gap > $cfg->{gap_min} * 60))) {
                $cur = { id => $root . ':' . int($t), root_session => $root, start => $t, end => $t,
                         prompts => [], user_msgs => 0, active_s => 0, corrections => 0, tool_calls => 0,
                         files => {}, sessions => {}, asst => {} };
                push @tasks, $cur;
            }
            $prev_t = $t;
            next unless $cur;    # assistant/tool messages before any user message
            $cur->{active_s} += ($gap < $cfg->{idle_min} * 60 ? $gap : 0) if defined $gap && $gap > 0;
            $cur->{end} = $t;
            $cur->{sessions}{ $m->{session} } = 1;
            if ($m->{role} eq 'user') {
                $cur->{user_msgs}++;
                my $txt = $m->{content} // '';
                $cur->{corrections} += Comserv::Util::AI::ModelScorecard::correction_count($txt);
                if (@{ $cur->{prompts} } < $cfg->{max_prompts}) {
                    (my $p = $txt) =~ s/\s+/ /g;
                    push @{ $cur->{prompts} }, substr($p, 0, $cfg->{prompt_chars});
                }
            } elsif ($m->{role} eq 'assistant') {
                $cur->{asst}{ $m->{session} }++;
                $asst_in{ $m->{session} }++;
                $cur->{tool_calls} += tool_call_count($m->{tool_calls});
                $cur->{files}{$_}++ for edited_paths($m->{tool_calls});
            }
        }
    }

    for my $t (@tasks) {
        my ($usd, $tok, %models) = (0, 0);
        for my $sid (keys %{ $t->{asst} }) {
            my $u = $usage->{$sid} || {};
            my $share = $asst_in{$sid} ? $t->{asst}{$sid} / $asst_in{$sid} : 0;
            $usd += ($u->{usd} || 0) * $share;
            $tok += ($u->{tokens} || 0) * $share;
            $models{$_} = 1 for @{ $u->{models} || [] };
        }
        for my $sid (keys %{ $t->{sessions} }) {
            my $m = ($sessions->{$sid} || {})->{model};
            $models{$m} = 1 if !%models && $m;
        }
        my @rew = grep { $t->{files}{$_} >= $cfg->{rewrite_threshold} } sort keys %{ $t->{files} };
        my $last_sid = (sort { ($sessions->{$b}{started_at} // 0) <=> ($sessions->{$a}{started_at} // 0) } keys %{ $t->{sessions} })[0];
        $t->{usd}            = sprintf('%.4f', $usd) + 0;
        $t->{tokens}         = int($tok);
        $t->{models}         = [ sort keys %models ];
        $t->{last_model}     = ($sessions->{ $last_sid // '' } || {})->{model} || $t->{models}[0] || '?';
        $t->{active_min}     = sprintf('%.1f', $t->{active_s} / 60) + 0;
        $t->{files_edited}   = scalar keys %{ $t->{files} };
        $t->{edited_list}    = [ sort keys %{ $t->{files} } ];
        $t->{edits}          = 0; $t->{edits} += $_ for values %{ $t->{files} };
        $t->{rewritten}      = [ map { { path => $_, edits => $t->{files}{$_} } } @rew ];
        $t->{title}          = ($sessions->{ $t->{root_session} } || {})->{title} // '';
        $t->{sessions}       = [ sort keys %{ $t->{sessions} } ];
        $t->{guess}          = guess_outcome($t);
        delete $t->{asst};
    }
    return [ sort { $b->{start} <=> $a->{start} } @tasks ];
}

# Heuristic only; the human rating always wins.
sub guess_outcome {
    my ($t) = @_;
    return 'failed?'  if ($t->{corrections} // 0) >= 3;
    return 'partial?' if ($t->{corrections} // 0) >= 1 || @{ $t->{rewritten} || [] };
    return 'done?'    if ($t->{edits} // 0) > 0;
    return 'chat';
}

# Per last_model: tasks, rated counts, $ per Done task (all spend on that
# model's tasks, failed ones included, divided by Done count).
sub summarize {
    my (%a) = @_;
    my $tasks = $a{tasks} || [];
    my $ratings = $a{ratings} || {};
    my %by;
    for my $t (@$tasks) {
        my $r = ($ratings->{ $t->{id} } || {})->{rating};
        my $g = $by{ $t->{last_model} } ||= { model => $t->{last_model}, tasks => 0, rated => 0, done => 0, partial => 0, failed => 0,
                                             usd => 0, tokens => 0, active_min => 0, corrections => 0, rewrites => 0 };
        $g->{tasks}++;
        $g->{usd} += $t->{usd};
        $g->{tokens} += $t->{tokens};
        $g->{active_min} += $t->{active_min};
        $g->{corrections} += $t->{corrections};
        $g->{rewrites} += scalar @{ $t->{rewritten} || [] };
        if ($r && $r =~ /^(done|partial|failed)$/) { $g->{rated}++; $g->{$r}++ }
    }
    for my $g (values %by) {
        $g->{usd}            = sprintf('%.2f', $g->{usd}) + 0;
        $g->{tokens_m}       = sprintf('%.2f', $g->{tokens} / 1e6) + 0;
        $g->{usd_per_done}   = $g->{done} ? sprintf('%.3f', $g->{usd} / $g->{done}) + 0 : undef;
        $g->{mtok_per_done}  = $g->{done} ? sprintf('%.2f', $g->{tokens} / 1e6 / $g->{done}) + 0 : undef;
        $g->{min_per_done}   = $g->{done} ? sprintf('%.1f', $g->{active_min} / $g->{done}) + 0 : undef;
        $g->{done_rate_pct}  = $g->{rated} ? int(100 * $g->{done} / $g->{rated} + 0.5) : undef;
    }
    return [ sort { $b->{tasks} <=> $a->{tasks} } values %by ];
}

1;
