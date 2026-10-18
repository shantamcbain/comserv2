#!/usr/bin/perl
# Read the decision-model artifacts and print an evaluation-ready report.
#
#   perl -Ilib script/decision_rank_report.pl            # last 5 calls + latest apply + cache
#   perl -Ilib script/decision_rank_report.pl --all      # every call
#   perl -Ilib script/decision_rank_report.pl --variance # per-key score drift between runs
#
# Reads (never writes):
#   data/ai_decision_calls.jsonl  transcript: what we asked, what came back, what was applied
#   data/ai_rank_order.json       the cache the Focus Queue actually reads on load
#   data/ai_decision_attribution_*.txt  probe output (is_broken / is_routine / category)
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Getopt::Long;
use File::Basename ();
use JSON qw(decode_json);
use Comserv::Util::AI::DecisionRank;
binmode(STDOUT, ':utf8');

my ($all, $variance, $limit);
GetOptions('all' => \$all, 'variance' => \$variance, 'limit=i' => \$limit) or die "bad options\n";
$limit ||= 5;

my $CALLS = Comserv::Util::AI::DecisionRank->call_log_file || '<unset>';
my $CACHE = Comserv::Util::AI::DecisionRank->cache_file;
my $ROOT  = File::Basename::dirname($CACHE);

sub ts { my $t = shift; return $t ? scalar(localtime($t)) : '-'; }
sub slack { my $s = shift; return $s < 60 ? "${s}s" : sprintf('%dm%02ds', $s / 60, $s % 60); }

print "=" x 96, "\nDECISION-MODEL ARTIFACTS\n", "=" x 96, "\n";
for my $f ($CALLS, $CACHE, glob("$ROOT/ai_decision_attribution_*.txt")) {
    next unless defined $f;
    if (-s $f) {
        my @st = stat($f);
        printf "  %-58s %7d bytes  %s\n", $f, $st[7], scalar(localtime($st[9]));
    } else {
        printf "  %-58s (missing)\n", $f;
    }
}
print "  untouched by: data/ai_eval_inbox + outbox (daily AI eval pipeline, separate flow)\n";

# --- transcript -------------------------------------------------------------
my @rec;
if (-s $CALLS) {
    open my $fh, '<:raw', $CALLS or die "$CALLS: $!";
    while (my $ln = <$fh>) {
        chomp $ln; next unless length $ln;
        my $r = eval { decode_json($ln) };
        push @rec, $r if ref $r eq 'HASH';
    }
    close $fh;
}
my @calls  = grep { $_->{kind} eq 'decision_call' } @rec;
my @applies = grep { $_->{kind} eq 'apply' } @rec;
print "\n", "=" x 96, "\nTRANSCRIPT: $CALLS\n", "=" x 96, "\n";
printf "  %d decision_call record(s), %d apply record(s)\n", scalar(@calls), scalar(@applies);

my @show = $all ? @calls : @calls[-$limit .. -1];
@show = grep { defined } @show;
for my $r (@show) {
    print "\n  ", ts($r->{ts}), "  ", $r->{branch}, "  model=", $r->{model},
          "  status=", ($r->{status} // '?'), "\n";
    printf "    host=%s gate=%s window=%s candidates=%s asked=%s answered=%s elapsed=%s\n",
        ($r->{host} // '-'), ($r->{gate} // '-'), ($r->{window} // '-'),
        ($r->{candidates} // '-'), ($r->{asked} // '-'), ($r->{answered} // '-'),
        (defined $r->{elapsed_s} ? slack($r->{elapsed_s}) : '-');
    if ($r->{usage}) {
        printf "    tokens in=%s out=%s\n",
            ($r->{usage}{input_tokens} // '-'), ($r->{usage}{output_tokens} // '-');
    }
    print "    ERROR: $r->{error}\n" if $r->{error};
    my $st = $r->{state};
    printf "    state: %s\n", (ref $st ? "redacted ($st->{bytes} bytes, sha256 $st->{sha256})" : "kept (" . length($st // '') . " bytes)");
    my $a = $r->{answers} || {};
    my @k = sort keys %$a;
    printf "    answers: %d key(s)\n", scalar(@k);
}

# --- run-to-run variance ----------------------------------------------------
if ($variance) {
    print "\n", "=" x 96, "\nRUN-TO-RUN VARIANCE (same branch+model, different calls)\n", "=" x 96, "\n";
    my %by_key;
    for my $r (@calls) {
        my $a = $r->{answers} || {};
        my $tag = ts($r->{ts});
        for my $k (keys %$a) {
            my $s = $a->{$k}{score};
            next unless defined $s;
            push @{ $by_key{$k} }, [ $tag, 0 + $s, 0 + ($a->{$k}{confidence} // 0) ];
        }
    }
    my @multi = grep { @{ $by_key{$_} } > 1 } sort keys %by_key;
    if (!@multi) {
        print "  only one scored call on file - nothing to compare yet.\n";
        print "  Run the same compute twice to measure how much the order moves with nothing changed.\n";
    }
    else {
        printf "  %-10s %-24s %-24s %s\n", 'key', 'run A score/conf', 'run B score/conf', 'delta';
        for my $k (@multi) {
            my @v = @{ $by_key{$k} };
            printf "  %-10s %-24s %-24s %+.3f\n", $k,
                sprintf('%.3f / %.2f', $v[0][1], $v[0][2]),
                sprintf('%.3f / %.2f', $v[-1][1], $v[-1][2]),
                $v[-1][1] - $v[0][1];
        }
        my $sum = 0; $sum += abs($_->[-1][1] - $_->[0][1]) for map { $by_key{$_} } @multi;
        printf "  mean absolute score drift: %.3f across %d key(s)\n", $sum / @multi, scalar(@multi);
    }
}

# --- what the page did with it ---------------------------------------------
print "\n", "=" x 96, "\nAPPLIED ORDER (what the Focus Queue actually rendered)\n", "=" x 96, "\n";
my @ap_show = $all ? @applies : @applies[-1 .. -1];
@ap_show = grep { defined } @ap_show;
if (!@ap_show) {
    print "  no apply records yet.\n";
}
for my $r (@ap_show) {
    print "\n  ", ts($r->{ts}), "  ", $r->{branch}, "  model=", $r->{model},
          "  gate=", ($r->{gate} // '-'), "\n";
    printf "    candidates=%s window=%s gate_passed=%s rows_changed_position=%s\n",
        ($r->{candidates} // '-'), ($r->{window} // '-'),
        ($r->{gate_passed} // '-'), ($r->{changed} // '-');
    my %coded; $coded{ $r->{coded_order}[$_] } = $_ + 1 for 0 .. $#{ $r->{coded_order} || [] };
    printf "    %-5s %-5s %-6s %s\n", 'was', 'now', 'move', 'todo id';
    for my $i (0 .. $#{ $r->{final_order} || [] }) {
        my $id = $r->{final_order}[$i];
        my $was = $coded{$id};
        next unless defined $was;
        printf "    %-5s %-5s %-6s %s\n", $was, $i + 1,
            (($was - ($i + 1)) > 0 ? '+' . ($was - ($i + 1)) : ($was - ($i + 1))), $id;
    }
}

# --- the cache the controller reads on load ---------------------------------
print "\n", "=" x 96, "\nCACHE READ ON PAGE LOAD: $CACHE\n", "=" x 96, "\n";
my $data;
if (-s $CACHE) {
    open my $fh, '<:raw', $CACHE or die $CACHE;
    local $/; my $txt = <$fh>; close $fh;
    $data = eval { decode_json($txt) };
}
if (ref $data ne 'HASH') {
    print "  unreadable or absent - the page falls back to the hardcoded order.\n";
}
else {
    for my $branch (sort keys %{ $data->{branches} || {} }) {
        my $e = $data->{branches}{$branch};
        my $age = time - ($e->{computed_at} // 0);
        printf "\n  branch=%s model=%s gate=%s window=%s rows=%d computed=%s (%s ago, ttl %s)\n",
            $branch, ($e->{model} // '?'), ($e->{gate} // '?'), ($e->{window} // '?'),
            scalar(keys %{ $e->{rows} || {} }), ts($e->{computed_at}), slack($age),
            (($age <= $Comserv::Util::AI::DecisionRank::CACHE_TTL) ? 'fresh' : 'STALE - ignored');
        my @rows = sort { ($e->{rows}{$b}{score} // -1) <=> ($e->{rows}{$a}{score} // -1) }
                   keys %{ $e->{rows} || {} };
        printf "  %-8s %-8s %-7s %s\n", 'todo', 'score', 'conf', 'clears gate?';
        for my $id (@rows) {
            my $d = $e->{rows}{$id};
            printf "  %-8s %-8.3f %-7.2f %s\n", $id, ($d->{score} // 0), ($d->{confidence} // 0),
                (($d->{confidence} // 0) >= ($e->{gate} // 0.3) ? 'yes (reordered)' : 'no (kept hardcoded)');
        }
    }
}
