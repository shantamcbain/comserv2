package Comserv::Model::AI2::ModelScorecard;

# Model scorecard collector (Oct 10 2026). Reads Hermes data read-only:
#   ~/.hermes/logs/agent.log*      API calls (model, provider, tokens, time) and
#                                  "Turn ended" lines (reason, model)
#   ~/.hermes/state.db (read-only) sessions (title, source, cwd), messages
#                                  (user/assistant/tool text, tool_calls),
#                                  session_model_usage (per-model $ and aux tasks)
#   git log in each session's repo (commits in the session window, later reverts)
# and hands segments to Comserv::Util::AI::ModelScorecard::aggregate.
# Cached in data/ai_model_scorecard_cache.json (10 min). Weights/config in
# data/ai_model_scorecard.json (editable on /ai/eval).

use strict;
use warnings;
use DBI;
use JSON::PP ();
use POSIX qw(strftime);
use Time::Local qw(timelocal);
use Comserv::Util::AI::ModelScorecard;
use Comserv::Util::AI::HermesOverrunGuard;

my $J = JSON::PP->new->canonical->utf8;
our $CACHE_TTL = 600;

sub new { my ($class, %a) = @_; return bless { %a }, $class }

sub hermes_home { $_[0]{hermes_home} || $ENV{HERMES_HOME} || (($ENV{HOME} || '/home/shanta') . '/.hermes') }
sub root { my $r = $_[0]{root} || '.'; $r =~ s{/$}{}; $r }
sub config_file { $_[0]->root . '/data/ai_model_scorecard.json' }
sub cache_file  { $_[0]->root . '/data/ai_model_scorecard_cache.json' }

sub _read_json { my ($f) = @_; open my $fh, '<', $f or return undef; local $/; my $d = eval { $J->decode(<$fh>) }; close $fh; $d }
sub _write_json { my ($f, $d) = @_; open my $fh, '>', "$f.tmp" or return "cannot write $f: $!"; print $fh JSON::PP->new->canonical->pretty->encode($d); close $fh; rename "$f.tmp", $f or return "rename: $!"; return undef }

sub config { my ($s) = @_; return Comserv::Util::AI::ModelScorecard::cfg_merge(_read_json($s->config_file) || {}) }

sub save_config {
    my ($s, $in, $by) = @_;
    my $cur = _read_json($s->config_file) || {};
    for my $k (qw(time cost quality)) {
        my $v = $in->{"w_$k"};
        $cur->{weights}{$k} = 0 + $v if defined $v && $v =~ /^\d+(?:\.\d+)?$/ && $v <= 100;
    }
    for my $k (qw(quota_pct_usd days)) {
        $cur->{$k} = 0 + $in->{$k} if defined $in->{$k} && $in->{$k} =~ /^\d+(?:\.\d+)?$/;
    }
    $cur->{updated_by} = $by; $cur->{updated_at} = time;
    my $err = _write_json($s->config_file, $cur);
    unlink $s->cache_file unless $err;
    return $err;
}

# build(force => 0|1) -> { rows, cfg, generated_at, coverage, notes }
sub build {
    my ($s, %a) = @_;
    my $cfg = $s->config;
    if (!$a{force} && (my $c = _read_json($s->cache_file))) {
        return $c if ($c->{generated_at} // 0) > time - $CACHE_TTL && ($c->{cfg_key} // '') eq $J->encode($cfg);
    }
    my $since = time - $cfg->{days} * 86400;
    my @notes;
    my $calls = $s->_calls($since, \@notes);
    my $db = $s->_state($since, \@notes);
    my @segs = $s->_segments($calls, $db, $cfg, \@notes);
    my $agg = Comserv::Util::AI::ModelScorecard::aggregate(segments => \@segs, cfg => $cfg);
    my $out = { %$agg, generated_at => time, generated_pt => _pt(time), since_pt => _pt($since),
                cfg_key => $J->encode($cfg), notes => \@notes,
                coverage => { sessions => scalar(keys %{ $db->{sessions} }), segments => scalar(@segs),
                              calls => scalar(@{ $calls->{calls} }), turns => scalar(@{ $calls->{turns} }) },
                speed => _speed(\@segs) };
    _write_json($s->cache_file, $out);
    return $out;
}

sub _pt { local $ENV{TZ} = 'America/Vancouver'; POSIX::tzset(); my $r = strftime('%a %b %d %H:%M PT', localtime $_[0]); POSIX::tzset(); $r }

# Per model: median seconds per finished turn (user message -> "Turn ended"), all tasks.
sub _speed {
    my ($segs) = @_;
    my %m;
    for my $g (@$segs) {
        push @{ $m{ $g->{model} }{t} }, @{ $g->{turns} || [] };
        $m{ $g->{model} }{calls} += $g->{calls} // 0;
        $m{ $g->{model} }{tcalls} += $g->{turn_calls} // 0;
    }
    my @out;
    for my $k (sort keys %m) {
        my @t = @{ $m{$k}{t} || [] };
        next unless @t;
        my @sorted = sort { $a <=> $b } @t;
        push @out, { model => $k, turns => scalar(@t),
                     median_s => sprintf('%.0f', Comserv::Util::AI::ModelScorecard::median(@t)),
                     p90_s => sprintf('%.0f', $sorted[int(0.9 * $#sorted)]),
                     calls_per_turn => sprintf('%.1f', ($m{$k}{tcalls} || 0) / scalar(@t)) };
    }
    return [ sort { $a->{median_s} <=> $b->{median_s} } @out ];
}

# agent.log*: API calls (resolved epochs) + Turn ended lines (epoch via the
# same file's API-call offset, which handles the mixed UTC/local stamps).
sub _calls {
    my ($s, $since, $notes) = @_;
    my $dir = $s->hermes_home . '/logs';
    my (@calls, @turns, %seen);
    for my $f (grep { -r } map { "$dir/agent.log$_" } ('.3', '.2', '.1', '')) {
        open my $fh, '<', $f or next;
        local $/; my $text = <$fh>; close $fh;
        my $parsed = Comserv::Util::AI::HermesOverrunGuard::parse_api_calls($text, undef, all => 1, anchor => (stat $f)[9]);
        my $i = 0;
        my $off = 0;     # resolved - raw-local, from the latest API-call line
        for my $line (split /\n/, $text) {
            if ($line =~ m{^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2}),\d+\s+\w+\s+\[([^\]]+)\].*?model=(\S+)\s+provider=(\S+)\s+in=(\d+)\s+out=(\d+)}) {
                my $raw = eval { timelocal($6, $5, $4, $3, $2 - 1, $1) };
                my $c = $parsed->[$i++];
                $off = $c->{t} - $raw if $c && defined $raw && $c->{session} eq $7;
                next;
            }
            next unless $line =~ m{^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2}),\d+\s+\w+\s+\[([^\]]+)\]\s+agent\.conversation_loop: Turn ended: reason=([a-z_]+)\S*\s+model=(\S+)\s+api_calls=(\d+)};
            my $raw = eval { timelocal($6, $5, $4, $3, $2 - 1, $1) } // next;
            push @turns, { session => $7, reason => $8, model => $9, api_calls => $10, t => $raw + $off };
        }
        push @$notes, "$f: matched " . scalar(@$parsed) . " calls but walked $i API-call lines" if $i != @$parsed && $notes;
        push @calls, grep { !$seen{"$_->{t}|$_->{session}|$_->{in}|$_->{out}"}++ } @$parsed;
    }
    my %tseen;
    return { calls => [ sort { $a->{t} <=> $b->{t} } grep { $_->{t} >= $since } @calls ],
             turns => [ sort { $a->{t} <=> $b->{t} } grep { $_->{t} >= $since && !$tseen{"$_->{session}|$_->{t}"}++ } @turns ] };
}

sub _state {
    my ($s, $since, $notes) = @_;
    my $file = $ENV{HERMES_STATE_DB} || $s->hermes_home . '/state.db';
    my $out = { sessions => {}, msgs => {}, usage => [] };
    my $dbh = eval { DBI->connect("dbi:SQLite:dbname=$file", '', '', { RaiseError => 1, PrintError => 0, ReadOnly => 1 }) };
    unless ($dbh) { push @$notes, "state.db not readable: $@"; return $out }
    eval {
        my $r = $dbh->selectall_arrayref(q{SELECT id, source, title, cwd, model, started_at, last_activity_at, end_reason, actual_cost_usd, estimated_cost_usd
            FROM sessions WHERE COALESCE(last_activity_at, started_at) >= CAST(? AS REAL)}, { Slice => {} }, $since);
        $out->{sessions}{ $_->{id} } = $_ for @$r;
        my $m = $dbh->selectall_arrayref(q{SELECT session_id, role, substr(COALESCE(content,''),1,6000) AS content, tool_calls, timestamp
            FROM messages WHERE timestamp >= ? ORDER BY timestamp}, { Slice => {} }, $since);
        push @{ $out->{msgs}{ $_->{session_id} } }, $_ for @$m;
        $out->{usage} = $dbh->selectall_arrayref(q{SELECT session_id, model, billing_provider, COALESCE(task,'') AS task, api_call_count,
            input_tokens, output_tokens, cache_read_tokens, CASE WHEN COALESCE(actual_cost_usd,0) > 0 THEN actual_cost_usd ELSE COALESCE(estimated_cost_usd,0) END AS usd
            FROM session_model_usage WHERE last_seen >= ?}, { Slice => {} }, $since);
        1;
    } or push @$notes, "state.db query failed: $@";
    $dbh->disconnect;
    return $out;
}

sub _git_commits {
    my ($s, $cwd, $from, $to) = @_;
    return () unless defined $cwd && -d $cwd;
    my $key = "$cwd";
    my $top = $s->{_top}{$key} //= do { my $t = `git -C '$cwd' rev-parse --show-toplevel 2>/dev/null`; chomp $t; $t };
    return () unless $top;
    my @c;
    for my $l (`git -C '$top' log --all --since=\@$from --until=\@$to --format='%h%x09%ct%x09%s' 2>/dev/null`) {
        chomp $l; my ($h, $t, $subj) = split /\t/, $l, 3;
        push @c, { hash => $h, t => $t, subject => $subj // '' } if $h;
    }
    my $reverts = 0;
    if (@c) {
        for my $l (`git -C '$top' log --all --since=\@$to --until=\@@{[ $to + 3 * 86400 ]} --format='%s%x09%b' 2>/dev/null`) {
            for my $x (@c) {
                $reverts++ if $l =~ /\brevert/i && (index($l, $x->{hash}) >= 0 || index($l, substr($x->{subject}, 0, 40)) >= 0);
            }
        }
    }
    return (\@c, $reverts);
}

sub _segments {
    my ($s, $calls, $db, $cfg, $notes) = @_;
    my (%by_sess, %turns_by);
    push @{ $by_sess{ $_->{session} } }, $_ for @{ $calls->{calls} };
    push @{ $turns_by{ $_->{session} } }, $_ for @{ $calls->{turns} };
    my %usage;   # main-loop $ per session/model
    # proposal #34c, eval report 35: paid OpenRouter rows Hermes logged at $0 are priced from OpenRouter list rates
    my $orp = $s->{or_prices} // eval { require Comserv::Util::AI::OpenRouterPrices; Comserv::Util::AI::OpenRouterPrices::load($s->root) } // {};
    my $n_or_priced = 0;
    my $or_fill = sub {
        my ($g) = @_;
        return unless ($g->{provider} // '') eq 'openrouter' && !($g->{usd} // 0) && ($g->{model} // '') !~ /:free\z/;
        my $u = Comserv::Util::AI::OpenRouterPrices::usd_for($orp, $g->{model}, $g->{tokens_in}, $g->{tokens_out}, $g->{tokens_cache});
        return unless $u && $u > 0;
        $g->{usd} = $u; $g->{usd_source} = 'openrouter_list_price'; $n_or_priced++;
    };
    my @segs;
    for my $u (@{ $db->{usage} }) {
        if ($u->{task} ne '') {
            my $ses = $db->{sessions}{ $u->{session_id} } || {};
            push @segs, { session => $u->{session_id}, model => $u->{model} // '?', provider => $u->{billing_provider} // '?',
                          task => 'aux', calls => $u->{api_call_count} // 0,
                          tokens_in => ($u->{input_tokens} // 0) + ($u->{cache_read_tokens} // 0), tokens_out => $u->{output_tokens} // 0,
                          tokens_cache => $u->{cache_read_tokens} // 0, usd => $u->{usd} // 0, outcome => 'aux', aux_task => $u->{task},
                          weighted_mtok => (($u->{billing_provider} // '') =~ /xai/ ? (($u->{input_tokens} // 0) + ($u->{cache_read_tokens} // 0) + ($u->{output_tokens} // 0)) / 1e6 : 0) };
            $or_fill->($segs[-1]);
            next;
        }
        $usage{ $u->{session_id} }{ $u->{model} // '' } += $u->{usd} // 0;
    }
    for my $sid (sort keys %by_sess) {
        my $cl  = $by_sess{$sid};
        my $ses = $db->{sessions}{$sid} || { id => $sid };
        my $msgs = $db->{msgs}{$sid} || [];
        my $task = Comserv::Util::AI::ModelScorecard::classify_task(title => $ses->{title}, source => $ses->{source}, cwd => $ses->{cwd});
        my $model_at = sub {
            my ($t) = @_; my $m;
            for (@$cl) { last if $_->{t} > $t + 5; $m = $_->{model} }
            return $m // $cl->[0]{model};
        };
        my %seg;
        my $sg = sub { my ($m) = @_; $seg{$m} ||= { session => $sid, model => $m, task => $task, turns => [], sigs => [] } };
        for my $c (@$cl) {
            my $g = $sg->($c->{model});
            $g->{provider} = $c->{provider};
            $g->{calls}++;
            $g->{tokens_in} += $c->{in}; $g->{tokens_out} += $c->{out}; $g->{tokens_cache} += $c->{cache} // 0;
            my $w = ($c->{in} >= $cfg->{long_ctx_tokens} ? $cfg->{long_ctx_weight} : 1);
            $g->{weighted_mtok} += ($c->{in} + $c->{out}) * $w / 1e6 if $c->{provider} =~ /^(?:xai-oauth|xai|supergrok)$/;
        }
        # turns: user message -> Turn ended
        my @users = map { $_->{timestamp} } grep { $_->{role} eq 'user' } @$msgs;
        for my $tn (@{ $turns_by{$sid} || [] }) {
            my $g = $sg->($tn->{model});
            my ($start) = reverse grep { $_ <= $tn->{t} + 1 } @users;
            my $secs = defined $start ? $tn->{t} - $start : undef;
            $secs = undef if defined $secs && ($secs < 0 || $secs > 4 * 3600);
            if ($tn->{reason} eq 'max_iterations_reached') { $g->{max_iter_turns}++ }
            elsif ($tn->{reason} =~ /^interrupted/) { $g->{interrupted_turns}++ }
            else { $g->{stop_turns}++ }
            if (defined $secs) { push @{ $g->{turns} }, $secs if $tn->{reason} eq 'text_response' || $tn->{reason} eq 'stop' || $tn->{reason} !~ /max_iter|interrupt/; $g->{active_s} += $secs }
            $g->{turn_calls} += $tn->{api_calls};
        }
        # messages: corrections, clarifications, tool calls, tests
        for my $m (@$msgs) {
            my $mm = $model_at->($m->{timestamp});
            my $g = $sg->($mm);
            if ($m->{role} eq 'user') {
                $g->{corrections} += Comserv::Util::AI::ModelScorecard::correction_count($m->{content});
            } elsif ($m->{role} eq 'assistant') {
                $g->{clarifications} += Comserv::Util::AI::ModelScorecard::clarify_count($m->{content});
                if (my $tc = eval { $J->decode($m->{tool_calls} // '') }) {
                    for my $x (ref $tc eq 'ARRAY' ? @$tc : ()) {
                        my $f = $x->{function} || {};
                        push @{ $g->{sigs} }, ($f->{name} // '?') . '|' . ($f->{arguments} // '');
                        $g->{tool_calls}++;
                    }
                }
            } elsif ($m->{role} eq 'tool') {
                my ($p, $f) = Comserv::Util::AI::ModelScorecard::test_signals($m->{content});
                $g->{tests_pass} += $p; $g->{tests_fail} += $f;
            }
        }
        # session outcome -> the model of the last turn; others "switched_away"
        my $first = $cl->[0]{t}; my $last = max0($cl->[-1]{t}, ($ses->{last_activity_at} // 0));
        my ($commits, $reverts) = $s->_git_commits($ses->{cwd}, int($first), int($last + 900));
        my $corr = sum0(map { $_->{corrections} // 0 } values %seg);
        my $stop = sum0(map { $_->{stop_turns} // 0 } values %seg);
        my ($last_role) = map { $_->{role} } grep { $_->{role} =~ /^(?:user|assistant)$/ } reverse @$msgs;
        my $oc = Comserv::Util::AI::ModelScorecard::outcome(commits => ($commits ? scalar @$commits : 0), stop_turns => $stop,
                                                           last_role => $last_role, corrections => $corr);
        my $last_model = ($turns_by{$sid} && @{ $turns_by{$sid} }) ? $turns_by{$sid}[-1]{model} : $cl->[-1]{model};
        for my $g (values %seg) {
            next unless $g->{calls} || $g->{stop_turns} || $g->{max_iter_turns};
            $g->{provider} //= ($g->{model} =~ /grok/ ? 'xai-oauth' : $g->{model} =~ m{/} ? 'openrouter' : 'ollama');
            $g->{thrash} = Comserv::Util::AI::ModelScorecard::thrash_episodes(@{ delete $g->{sigs} });
            $g->{usd} = $usage{$sid}{ $g->{model} } // 0;
            $g->{usd} = 0 if $g->{provider} =~ /^(?:xai-oauth|xai|supergrok|ollama|ollama-launch|custom)$/;
            $or_fill->($g);
            if ($g->{model} eq $last_model) {
                $g->{outcome} = $oc;
                $g->{commits} = $commits ? scalar @$commits : 0;
                $g->{reverts} = $reverts // 0;
            } else {
                $g->{outcome} = 'switched_away';
            }
            push @segs, $g;
        }
    }
    push @$notes, "$n_or_priced paid OpenRouter segment(s) logged at \$0 by Hermes were priced from OpenRouter list rates (data/ai_openrouter_prices.json)" if $n_or_priced && ref $notes eq 'ARRAY';
    return @segs;
}

sub max0 { my $m = 0; for (@_) { $m = $_ if defined $_ && $_ > $m } $m }
sub sum0 { my $t = 0; $t += $_ // 0 for @_; $t }

1;
