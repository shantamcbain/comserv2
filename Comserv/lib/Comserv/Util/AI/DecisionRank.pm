package Comserv::Util::AI::DecisionRank;
use strict;
use warnings;
use File::Basename ();
use File::Spec ();
use JSON qw(encode_json decode_json);
use Try::Tiny;
use Comserv::Util::Logging;

# Local decision-model ordering for the Focus Queue (AISYSTEMPlan 5f).
#
# WHY A CACHE AND NOT A LIVE CALL
#   ollama /v1/systemone is cheap ($0, local) but SLOW to start: measured on this
#   workstation, tev1:0.8b takes ~12s and nimble:latest ~133s cold for a 17-todo
#   call. A page render must never wait on that, so the ordering is computed by
#   script/compute_decision_rank.pl and only READ here.
#
# SERVER LIMITS THAT SHAPE THE REQUEST (measured 2026-09-30)
#   - input cap is PER QUESTION PROMPT: state + that question's rubric must fit
#     in 2050 tokens, and the server REFUSES rather than truncating. A 5-level
#     rubric over a 17-row state blew it at 2713; terse 3-level fits (~1748).
#   - usage.input_tokens is the SUM across the questions (29716 for 17), because
#     the state is re-sent with each question. Cost scales linearly, so window it.
#   - scores returned by separate calls are NOT comparable (each call is scored
#     against its own state). Never chunk a queue to "score all of it".
#
# CONFIDENCE IS THE SAFETY VALVE
#   confidence is how concentrated the model's distribution is, not accuracy.
#   Measured: nimble returned 0.73/0.58/0.51/0.46/0.44 on its top five and
#   0.01-0.26 on the rest; tev1:0.8b returned 0.00-0.29 throughout (i.e. noise).
#   Below the gate we keep the hardcoded ap_score order.

our $CACHE_VERSION = 1;
our $DEFAULT_MODEL = 'nimble:latest';
our $DEFAULT_GATE  = 0.30;
our $DEFAULT_WINDOW = 20;      # rows re-ranked; see per-question token cap above
our $CACHE_TTL      = 6 * 3600;

my $HERE = File::Basename::dirname(__FILE__);                       # .../lib/Comserv/Util/AI
my $ROOT = File::Spec->catdir($HERE, '..', '..', '..', '..');       # app root

sub cache_file {
    return $ENV{COMSERV_DECISION_RANK_FILE}
        if $ENV{COMSERV_DECISION_RANK_FILE};
    return File::Spec->catfile($ROOT, 'data', 'ai_rank_order.json');
}

sub confidence_gate { $DEFAULT_GATE }

# --- per-call transcript ----------------------------------------------------
# WHY: the cache keeps only derived score+confidence, so after the fact there is
# no way to see what we asked or what came back — which made "why did the model
# rank that first?" unanswerable. Every call now appends one JSON line.
#
# PRIVACY: `state` is todo subjects for the ranking use case and is safe to keep.
# The same module will later be handed ticket/mail text, so callers pass
# redact_state => 1 and only a length + sha256 is stored.
our $CALL_LOG_FILE;
sub call_log_file {
    return $ENV{COMSERV_DECISION_CALL_LOG} if $ENV{COMSERV_DECISION_CALL_LOG};
    return $CALL_LOG_FILE if $CALL_LOG_FILE;
    return File::Spec->catfile($ROOT, 'data', 'ai_decision_calls.jsonl');
}

sub _append_jsonl {
    my ($class, $href) = @_;
    my $file = $class->call_log_file;
    my $ok = eval {
        my $dir = File::Basename::dirname($file);
        unless (-d $dir) { require File::Path; File::Path::mkpath($dir); }
        open my $fh, '>>:raw', $file or die "$file: $!";
        print {$fh} encode_json($href), "\n";
        close $fh;
        1;
    };
    return $ok ? 1 : 0;
}

sub _state_for_log {
    my ($class, $state, $redact) = @_;
    if ($redact) {
        require Digest::SHA;
        return {
            redacted => 1,
            bytes    => length($state // ''),
            sha256   => Digest::SHA::sha256_hex($state // ''),
        };
    }
    return $state;
}

sub record_apply {
    my ($class, $branch, $info) = @_;
    return $class->_append_jsonl({
        kind        => 'apply',
        ts          => time,
        branch      => $branch,
        model       => $info->{model},
        gate        => $info->{gate},
        window      => $info->{window},
        candidates  => $info->{candidates},
        gate_passed => $info->{gate_passed},
        changed     => $info->{changed},
        coded_order => $info->{coded_order},
        model_order => $info->{model_order},
        final_order => $info->{final_order},
    });
}


# --- cache ------------------------------------------------------------------
sub read_cache {
    my ($class, $branch, %opt) = @_;
    return unless defined $branch && length $branch;
    my $file = $class->cache_file;
    return unless -s $file;
    my $txt;
    try {
        open my $fh, '<:raw', $file or die "$file: $!";
        local $/; $txt = <$fh>; close $fh;
    } catch {
        return;
    };
    my $data = eval { decode_json($txt) };
    return unless ref($data) eq 'HASH';
    my $entry = $data->{branches}{$branch};
    return unless ref($entry) eq 'HASH' && ref($entry->{rows}) eq 'HASH';
    unless ($opt{ignore_ttl}) {
        my $age = time - ($entry->{computed_at} // 0);
        return if $age > $CACHE_TTL;
    }
    return $entry;
}

sub write_cache {
    my ($class, $branch, $entry) = @_;
    my $file = $class->cache_file;
    my $data = { version => $CACHE_VERSION, branches => {} };
    if (-s $file) {
        my $txt;
        try { open my $fh, '<:raw', $file or die "$file: $!"; local $/; $txt = <$fh>; close $fh; };
        my $old = eval { decode_json($txt // '') };
        $data = $old if ref($old) eq 'HASH' && ref($old->{branches}) eq 'HASH';
    }
    $data->{version} = $CACHE_VERSION;
    $data->{branches}{$branch} = $entry;

    my $dir = File::Basename::dirname($file);
    unless (-d $dir) { require File::Path; File::Path::make_path($dir); }
    my $tmp = "$file.tmp.$$";
    open my $out, '>:raw', $tmp or die "$tmp: $!";
    print {$out} encode_json($data);
    close $out;
    rename $tmp, $file or die "rename $tmp -> $file: $!";
    return $file;
}

# --- the model call ---------------------------------------------------------
# Build the compact per-question state. Keep every line short: state + one
# 3-level rubric must fit the 2050-token per-question prompt cap.
sub build_state {
    my ($class, $rows) = @_;
    my $state = "Comserv2 dev branch open work. Which todo should be worked NEXT? "
              . "Higher = more important now. Work blocked by another todo is low value.\n";
    my %key_of;
    for my $r (@$rows) {
        my $key = 't' . ($r->{record_id} // 0);
        $key_of{$key} = $r;
        my $subj = $r->{subject} // '';
        $subj =~ s/\s+/ /g;
        $state .= sprintf("%s P%s s=%s due=%s %s\n",
            $key, ($r->{priority} // '?'), ($r->{status} // '?'),
            ($r->{due_date} // '-'), substr($subj, 0, 52));
    }
    return ($state, \%key_of);
}

sub build_questions {
    my ($class, $key_of) = @_;
    my %q;
    for my $k (keys %$key_of) {
        $q{$k} = {
            type         => 'score',
            instructions => "Importance of $k now",
            criteria     => [ 'low', 'medium', 'high' ],
        };
    }
    return \%q;
}

# Score one branch's queue. One call, window-limited. Returns a cache entry.
sub score_branch {
    my ($class, $branch, $rows, %opt) = @_;
    my $model  = $opt{model}  || $DEFAULT_MODEL;
    my $gate   = defined $opt{gate} ? $opt{gate} : $DEFAULT_GATE;
    my $window = $opt{window} || $DEFAULT_WINDOW;
    my $host   = $opt{host}   || '127.0.0.1';
    my $port   = $opt{port}   || 11434;

    my @win = @$rows;
    @win = @win[0 .. $window - 1] if @win > $window;
    return { error => 'no rows to score' } unless @win;

    my ($state, $key_of) = $class->build_state(\@win);
    my $questions = $class->build_questions($key_of);
    my $nq        = scalar keys %$key_of;
    my $redact    = $opt{redact_state} ? 1 : 0;

    require Comserv::Model::Ollama;
    my $o = Comserv::Model::Ollama->new(host => $host, port => $port);
    $o->model($model);
    $o->timeout($opt{timeout} || 900);

    my $t0   = time;
    my $resp = $o->systemone(state => $state, questions => $questions);
    my $elapsed = time - $t0;

    if (!$resp) {
        # Failures are the interesting ones (token-cap rejections, HTTP errors,
        # a dead daemon). Record the ask, not just the fact that it failed.
        my $err = $o->last_error || 'systemone call failed';
        $class->_append_jsonl({
            kind       => 'decision_call',
            ts         => time,
            branch     => $branch,
            model      => $model,
            host       => "$host:$port",
            gate       => 0 + $gate,
            window     => 0 + $window,
            candidates => scalar @$rows,
            asked      => $nq,
            elapsed_s  => $elapsed,
            status     => 'error',
            error      => $err,
            state      => $class->_state_for_log($state, $redact),
            questions  => $questions,
            answers    => undef,
        });
        $class->_log_usage($opt{c}, {
            model => $model, host => "$host:$port", branch => $branch, gate => $gate,
            window => $window, asked => $nq, answered => 0,
            status => 'error', error_message => $err, duration_ms => $elapsed * 1000,
        });
        return { error => $err, model => $model };
    }

    my %rows;
    my $answered = 0;
    for my $key (sort keys %$key_of) {
        my ($score, $legend, $conf) = $o->systemone_score($resp, $key);
        my $id = $key_of->{$key}{record_id};
        next unless defined $id;
        unless (defined $score) {
            # No answer for this key: store it, but with confidence 0 so the
            # gate keeps it on the hardcoded order.
            $rows{$id} = { score => undef, confidence => 0 };
            next;
        }
        $answered++;
        $rows{$id} = { score => 0 + $score, confidence => 0 + ($conf // 0) };
    }

    $class->_append_jsonl({
        kind       => 'decision_call',
        ts         => time,
        branch     => $branch,
        model      => $resp->{model} || $model,
        host       => "$host:$port",
        gate       => 0 + $gate,
        window     => 0 + $window,
        candidates => scalar @$rows,
        asked      => $nq,
        answered   => $answered,
        elapsed_s  => $elapsed,
        usage      => {
            input_tokens  => $resp->{usage}{input_tokens},
            output_tokens => $resp->{usage}{output_tokens},
        },
        status    => 'success',
        error     => undef,
        state     => $class->_state_for_log($state, $redact),
        questions => $questions,
        answers   => $resp->{answers},
    });
    $class->_log_usage($opt{c}, {
        model => $resp->{model} || $model, host => "$host:$port", branch => $branch,
        gate => $gate, window => $window, asked => $nq, answered => $answered,
        status => 'success', duration_ms => $elapsed * 1000,
        prompt_tokens     => ($resp->{usage}{input_tokens} // 0),
        completion_tokens => ($resp->{usage}{output_tokens} // 0),
        answers           => $resp->{answers},
    });

    return {
        model        => $resp->{model} || $model,
        gate         => 0 + $gate,
        window       => 0 + $window,
        computed_at  => time,
        answered     => $answered,
        asked        => scalar keys %$key_of,
        input_tokens => $resp->{usage}{input_tokens},
        rows         => \%rows,
    };
}

# Ledger write. Only possible with a Catalyst context, so script-driven computes
# land in the JSONL transcript above but NOT in ai_usage_logs; in-app callers
# (todo creation, HelpDesk) get both.
sub _log_usage {
    my ($class, $c, $info) = @_;
    return unless $c && ref($c) && $c->can('model');
    my $ok = eval {
        require Comserv::Model::AI::Usage;
        my $usage = eval { $c->model('AI::Usage') }
                 || Comserv::Model::AI::Usage->new;
        $usage->log($c,
            provider          => 'ollama',
            model             => $info->{model},
            request_type      => 'decision',
            prompt_tokens     => ($info->{prompt_tokens} // 0),
            completion_tokens => ($info->{completion_tokens} // 0),
            duration_ms       => $info->{duration_ms},
            status            => $info->{status},
            error_message     => $info->{error_message},
            ollama_host       => $info->{host},
            response_text     => (ref $info->{answers} ? encode_json($info->{answers}) : undef),
            metadata          => {
                decision_branch => $info->{branch},
                gate            => $info->{gate},
                window          => $info->{window},
                asked           => $info->{asked},
                answered        => $info->{answered},
                source          => 'DecisionRank',
            },
        );
        1;
    };
    return $ok ? 1 : 0;
}

# --- applying the cache at render time --------------------------------------
# Reorders ONLY inside contiguous groups of rows that share the same "already
# being worked" and "belongs to this branch" classification, so
# FocusRanking::cmp_branch_focus semantics (Active first, branch above other,
# blocking above blocked) are preserved. Rows that clear the confidence gate are
# ordered by model score and float to the top of their group; everything else
# keeps the hardcoded ap_score order it arrived in.
sub _group_key {
    my ($row, $branch, $scope) = @_;
    my $active = (($row->{status} // '') eq '5') ? 1 : 0;
    my $inbranch = 0;
    if (defined $branch && length $branch && $branch ne 'main') {
        $inbranch = eval {
            Comserv::Util::FocusRanking::todo_matches_branch($row, $branch, $scope)
        } ? 1 : 0;
    }
    return "$active|$inbranch";
}

sub apply_order {
    my ($class, $rows, $cache, $ctx) = @_;
    return unless ref($rows) eq 'ARRAY' && @$rows;
    return unless ref($cache) eq 'HASH' && ref($cache->{rows}) eq 'HASH';

    require Comserv::Util::FocusRanking;
    my $branch = $ctx->{branch} || '';
    my $scope  = $ctx->{branch_project_ids} || {};
    my $gate   = defined $ctx->{gate} ? $ctx->{gate}
               : (defined $cache->{gate} ? $cache->{gate} : $DEFAULT_GATE);
    my $by_id  = $cache->{rows};

    my @out;
    my $i = 0;
    while ($i < @$rows) {
        my $key = _group_key($rows->[$i], $branch, $scope);
        my $j = $i;
        $j++ while $j < @$rows && _group_key($rows->[$j], $branch, $scope) eq $key;

        my (@ranked, @plain);
        my $n = 0;
        for my $r (@{$rows}[$i .. $j - 1]) {
            my $d = $by_id->{ $r->{record_id} };
            if (ref($d) eq 'HASH' && defined $d->{score}
                && (($d->{confidence} // 0) >= $gate)) {
                push @ranked, [ $r, $d->{score}, $d->{confidence}, $n ];
            } else {
                push @plain, [ $r, $n ];
            }
            $n++;
        }
        @ranked = sort { $b->[1] <=> $a->[1] || $a->[3] <=> $b->[3] } @ranked;
        push @out, map { $_->[0] } @ranked;
        push @out, map { $_->[0] } @plain;   # keep the incoming (hardcoded) order
        $i = $j;
    }

    for my $r (@out) {
        my $d = $by_id->{ $r->{record_id} };
        next unless ref($d) eq 'HASH';
        $r->{decision_score} = $d->{score};
        $r->{decision_conf}  = $d->{confidence};
        $r->{decision_used}  = (defined $d->{score}
                                && (($d->{confidence} // 0) >= $gate)) ? 1 : 0;
    }
    return \@out;
}

1;

