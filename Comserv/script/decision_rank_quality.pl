#!/usr/bin/env perl
# Quality metric for Ollama decision-model todo ordering (DecisionRank).
# Uses pure RankQuality::run_quality on 'apply' rows from the call log.
#
#   perl script/decision_rank_quality.pl [--todos-file F.json] [--calls data/ai... ] [--since-days 30] [--write] [--date YYYY-MM-DD]
#
# --todos-file  use local JSON (detect first arrayref in hash, e.g. under "todos")
#               instead of GET $api/api/todos
# --write       append quality rows to data/ai_decision_rank_quality.jsonl (dedup ts+model)
#               and write data/ai_eval_inbox/<date>-decision-rank-quality.json
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Getopt::Long;
use JSON qw(encode_json decode_json);
use LWP::UserAgent;
use POSIX qw(strftime);
use File::Basename ();
use File::Spec ();
use Comserv::Util::AI::RankQuality qw(run_quality kendall_tau top_k_hit rank_report);

binmode(STDOUT, ':utf8');
binmode(STDERR, ':utf8');

my $api        = 'http://127.0.0.1:4006';
my $todos_file;
my $calls_file = 'data/ai_decision_calls.jsonl';
my $since_days = 30;
my $write      = 0;
my $date_str;
GetOptions(
    'api=s'         => \$api,
    'todos-file=s'  => \$todos_file,
    'calls=s'       => \$calls_file,
    'since-days=i'  => \$since_days,
    'write'         => \$write,
    'date=s'        => \$date_str,
) or die "bad options\n";

$date_str ||= _today_vancouver();

my $cutoff = time - ($since_days * 86400);

# --- load todos (by_id) ---
my %todos_by_id;
if ($todos_file) {
    open my $fh, '<:raw', $todos_file or die "$todos_file: $!";
    local $/; my $txt = <$fh>; close $fh;
    my $j = eval { decode_json($txt) };
    die "$todos_file: bad json: $@" if $@;
    my $arr;
    if (ref $j eq 'ARRAY') {
        $arr = $j;
    } elsif (ref $j eq 'HASH') {
        # detect the first arrayref value
        for my $k (sort keys %$j) {
            if (ref $j->{$k} eq 'ARRAY') { $arr = $j->{$k}; last; }
        }
        $arr ||= [];
    } else {
        $arr = [];
    }
    for my $t (@$arr) {
        next unless ref $t eq 'HASH';
        my $id = $t->{record_id} // $t->{id} // $t->{todo_id};
        next unless defined $id;
        $id = "$id";
        $todos_by_id{$id} = {
            priority       => $t->{priority} // 999,
            last_mod_date  => $t->{last_mod_date},
            status         => $t->{status},
        };
    }
} else {
    my $ua = LWP::UserAgent->new(timeout => 30);
    my $res = $ua->get("$api/api/todos");
    die "GET /api/todos failed: " . $res->status_line unless $res->is_success;
    my $raw = $res->decoded_content;
    my $j = eval { decode_json($raw) };
    die "bad /api/todos json" if $@;
    my $arr = (ref $j eq 'HASH') ? ($j->{todos} || $j->{data} || []) : (ref $j eq 'ARRAY' ? $j : []);
    for my $t (@$arr) {
        next unless ref $t eq 'HASH';
        my $id = $t->{record_id} // $t->{id} // $t->{todo_id};
        next unless defined $id;
        $id = "$id";
        $todos_by_id{$id} = {
            priority       => $t->{priority} // 999,
            last_mod_date  => $t->{last_mod_date},
            status         => $t->{status},
        };
    }
}

# --- load calls ---
my @recs;
if (-s $calls_file) {
    open my $fh, '<:raw', $calls_file or die "$calls_file: $!";
    while (my $ln = <$fh>) {
        chomp $ln; next unless length $ln;
        my $r = eval { decode_json($ln) };
        push @recs, $r if ref $r eq 'HASH';
    }
    close $fh;
}

my @applies = grep { ($_->{kind} // '') eq 'apply' && ($_->{ts} // 0) >= $cutoff } @recs;
my @dec_calls = grep { ($_->{kind} // '') eq 'decision_call' && ($_->{ts} // 0) >= $cutoff } @recs;

# run quality for every apply
my @qualities;
for my $ar (@applies) {
    my $q = run_quality($ar, \%todos_by_id);
    push @qualities, $q if ref $q eq 'HASH';
}

# aggregate decision_call per model
my %mstats;
for my $dc (@dec_calls) {
    my $m = $dc->{model} // 'unknown';
    $mstats{$m}{calls}++;
    if (defined $dc->{elapsed_s}) {
        push @{ $mstats{$m}{elaps} }, $dc->{elapsed_s};
    }
    if (ref $dc->{usage} eq 'HASH' && defined $dc->{usage}{input_tokens}) {
        push @{ $mstats{$m}{itoks} }, $dc->{usage}{input_tokens};
    }
    if ($dc->{error}) {
        $mstats{$m}{fail}++;
    } else {
        $mstats{$m}{succ}++;
    }
}
for my $m (keys %mstats) {
    my $s = $mstats{$m};
    $s->{succ} //= 0;
    $s->{fail} //= 0;
    $s->{mean_e} = _mean($s->{elaps} || []);
    $s->{max_e}  = _max($s->{elaps} || []);
    $s->{mean_i} = _mean($s->{itoks} || []);
}

# configured models that must be shown even with zero
my @configured = qw(nimble:latest tev1:0.8b tev1:latest);

print "=== DECISION RANK QUALITY ===\n";
print "report_date=$date_str  since_days=$since_days  calls=$calls_file\n";
print "todos_by_id=" . scalar(keys %todos_by_id) . "  applies=" . scalar(@applies) . "  qualities=" . scalar(@qualities) . "\n\n";

# per-apply quality rows
if (@qualities) {
    print "APPLY QUALITIES:\n";
    printf "%-20s %4s %6s %6s %6s %6s %6s %6s %4s %6s %6s %6s\n",
        'model', 'n', 'tau_m', 'tau_c', 'tau_f', 'tau_mc', 'diverg', 'top5m', 'w_n', 'w_m5', 'w_c5', 'w_f5';
    for my $q (@qualities) {
        printf "%-20s %4d %6s %6s %6s %6s %6s %6s %4d %6s %6s %6s\n",
            $q->{model},
            $q->{n} // 0,
            _fmt($q->{tau_model_vs_manual}),
            _fmt($q->{tau_coded_vs_manual}),
            _fmt($q->{tau_final_vs_manual}),
            _fmt($q->{tau_model_vs_coded}),
            _fmt($q->{divergence}),
            _fmt($q->{top5_model_manual}),
            $q->{worked_n} // 0,
            _fmt($q->{worked_in_model_top5}),
            _fmt($q->{worked_in_coded_top5}),
            _fmt($q->{worked_in_final_top5});
    }
    print "\n";
} else {
    print "No apply rows in window.\n\n";
}

# decision call aggregates, including zero for configured
print "DECISION CALL AGGREGATES (since $since_days days):\n";
printf "%-18s %6s %6s %6s %8s %8s %10s\n",
    'model', 'calls', 'succ', 'fail', 'mean_e', 'max_e', 'mean_in_t';
my %seen_m;
for my $m (sort keys %mstats, @configured) {
    next if $seen_m{$m}++;
    my $s = $mstats{$m} || {};
    if (! %$s && ! grep { $_ eq $m } keys %mstats) {
        # zero calls model
        printf "%-18s %6d %6d %6d %8s %8s %10s\n", $m, 0,0,0, '-', '-', '-';
        next;
    }
    if (($s->{calls} // 0) == 0) {
        printf "%-18s %6d %6d %6d %8s %8s %10s   no ranking calls logged\n",
            $m, 0,0,0,'-','-','-';
    } else {
        printf "%-18s %6d %6d %6d %8.1f %8.1f %10.0f\n",
            $m,
            $s->{calls} // 0,
            $s->{succ} // 0,
            $s->{fail} // 0,
            $s->{mean_e} // 0,
            $s->{max_e} // 0,
            $s->{mean_i} // 0;
    }
}
print "\n";

if ($write) {
    # dedupe + append qualities to jsonl
    my $qlog = 'data/ai_decision_rank_quality.jsonl';
    my %seen;
    if (-s $qlog) {
        open my $fh, '<:raw', $qlog or warn;
        while (my $ln = <$fh>) {
            chomp $ln; next unless length;
            my $r = eval { decode_json($ln) };
            if (ref $r eq 'HASH' && defined $r->{ts} && defined $r->{model}) {
                $seen{ "$r->{ts}|$r->{model}" } = 1;
            }
        }
        close $fh;
    }
    my $new = 0;
    open my $ofh, '>>:raw', $qlog or die "$qlog: $!";
    for my $q (@qualities) {
        my $key = "$q->{ts}|$q->{model}";
        next if $seen{$key};
        print $ofh encode_json($q), "\n";
        $seen{$key} = 1;
        $new++;
    }
    close $ofh;
    print "Appended $new quality records to $qlog (deduped).\n";

    # write inbox file
    my $inbox_dir = 'data/ai_eval_inbox';
    unless (-d $inbox_dir) {
        require File::Path; File::Path::mkpath($inbox_dir);
    }
    my $inbox = "$inbox_dir/$date_str-decision-rank-quality.json";

    my $now_str = do {
        local $ENV{TZ} = 'America/Vancouver';
        POSIX::tzset();
        strftime('%Y-%m-%dT%H:%M:%S-07:00', localtime);
    };

    my %by_model;
    for my $q (@qualities) {
        push @{ $by_model{ $q->{model} } }, $q;
    }

    my @models_out;
    my %mseen;
    for my $m (@configured, sort keys %by_model, sort keys %mstats) {
        next if $mseen{$m}++;
        my $qs = $by_model{$m} || [];
        my $latest = @$qs ? $qs->[-1] : undef;
        if ($latest) {
            push @models_out, {
                title       => "Decision rank quality: $m",
                change_type => "other",
                target      => "data/ai_decision_rank_quality.jsonl",
                rationale   => "run_quality on apply rows for model $m (n=$latest->{n}, worked_n=$latest->{worked_n})",
                payload     => {
                    status => "computed",
                    metrics => $latest,
                    undo   => "delete this inbox file and data/ai_decision_rank_quality.jsonl",
                },
            };
        } else {
            push @models_out, {
                title       => "Decision rank quality: $m",
                change_type => "other",
                target      => "data/ai_decision_rank_quality.jsonl",
                rationale   => "No apply records for this model in window",
                payload     => {
                    status => "no ranking calls logged",
                    undo   => "delete this inbox file and data/ai_decision_rank_quality.jsonl",
                },
            };
        }
    }

    my $summary = "Decision rank quality for " . scalar(@qualities) . " apply rows (models: " . join(',', sort keys %by_model) . "). Since $since_days days. Configured models without calls noted.";

    my $md = "# Decision rank quality - $date_str\n\n";
    $md .= "Applies processed: " . scalar(@qualities) . "  todos matched: " . scalar(keys %todos_by_id) . "\n\n";
    $md .= "## Per-apply metrics\n\n";
    if (@qualities) {
        $md .= "| model | n | tau_m_vs_man | top5 | worked_n | worked_in_m_top5 |\n";
        $md .= "|-------|---|--------------|------|----------|------------------|\n";
        for my $q (@qualities) {
            $md .= sprintf "| %s | %d | %s | %s | %d | %s |\n",
                $q->{model}, $q->{n}||0, _fmt($q->{tau_model_vs_manual}),
                _fmt($q->{top5_model_manual}), $q->{worked_n}||0, _fmt($q->{worked_in_model_top5});
        }
    } else {
        $md .= "No applies.\n";
    }
    $md .= "\n## Configured models\n\n";
    for my $item (@models_out) {
        $md .= "- **$item->{title}**: $item->{payload}{status}\n";
        if ($item->{payload}{metrics}) {
            $md .= "  undo: $item->{payload}{undo}\n";
        }
    }

    my $inbox_content = {
        report_date => $date_str,
        source      => "Decision rank quality (Grok Bot)",
        created_by  => "Grok Bot (decision rank quality task)",
        created_at  => $now_str,
        summary     => $summary,
        markdown    => $md,
        metrics     => {
            applies     => scalar(@qualities),
            todos       => scalar(keys %todos_by_id),
            since_days  => $since_days,
        },
        proposals   => \@models_out,
    };

    open my $ifh, '>:raw', $inbox or die "$inbox: $!";
    print $ifh encode_json($inbox_content);
    close $ifh;
    print "Wrote $inbox\n";
}

sub _today_vancouver {
    local $ENV{TZ} = 'America/Vancouver';
    POSIX::tzset();
    return strftime('%Y-%m-%d', localtime);
}

sub _fmt {
    my $v = shift;
    return '-' unless defined $v;
    return sprintf('%.3f', $v) if $v =~ /^-?\d+\.?\d*$/;
    return $v;
}

sub _mean {
    my $a = shift;
    return 0 unless @$a;
    my $s = 0; $s += $_ for @$a;
    return $s / scalar(@$a);
}

sub _max {
    my $a = shift;
    return 0 unless @$a;
    my $m = $a->[0];
    for (@$a) { $m = $_ if $_ > $m }
    return $m;
}

# note: %by_model used above was forward ref, but code moved the build before use in if($write)
# (the initial for m loop was placeholder, cleaned in actual write)
1;
