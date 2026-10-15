#!/usr/bin/perl
# Compute the decision-model ordering for one branch's Focus Queue and cache it.
#
# THIS is the explicit "compute" action. The Focus Queue only READS the cache
# (lib/Comserv/Util/AI/DecisionRank.pm) because nimble cold is ~133s and a page
# render must never wait on that.
#
#   perl -Ilib script/compute_decision_rank.pl --branch aisystem
#   perl -Ilib script/compute_decision_rank.pl --branch aisystem --model tev1:0.8b
#   perl -Ilib script/compute_decision_rank.pl --branch aisystem --dry-run --print
#
# --dry-run  score but do not write the cache.
# --print    dump hardcoded order vs model order side by side.
use strict;
use warnings;
use Getopt::Long;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON qw(decode_json);
use LWP::UserAgent;
use Comserv::Util::TodoRanking;
use Comserv::Util::AI::DecisionRank;
binmode(STDOUT, ':utf8');
binmode(STDERR, ':utf8');

my ($branch, $model, $gate, $window, $api, $dry, $print, $help);
GetOptions(
    'branch=s'  => \$branch,
    'model=s'   => \$model,
    'gate=f'    => \$gate,
    'window=i'  => \$window,
    'api=s'     => \$api,
    'dry-run'   => \$dry,
    'print'     => \$print,
    'help'      => \$help,
) or die "bad options\n";
die "usage: $0 --branch <name> [--model nimble:latest] [--gate 0.30] [--window 20] [--dry-run] [--print]\n"
    if $help || !$branch;

$api    ||= 'http://127.0.0.1:4006';
$model  ||= $Comserv::Util::AI::DecisionRank::DEFAULT_MODEL;
$gate   = $Comserv::Util::AI::DecisionRank::DEFAULT_GATE unless defined $gate;
$window ||= $Comserv::Util::AI::DecisionRank::DEFAULT_WINDOW;

# --- branch -> project ids (mirrors resolve_branch_project_ids without $c) ---
my $ua = LWP::UserAgent->new(timeout => 60);

sub api_get {
    my ($path) = @_;
    my $res = $ua->get("$api$path");
    die "GET $path failed: " . $res->status_line unless $res->is_success;
    my $raw = $res->decoded_content;
    $raw =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f]//g;
    return decode_json($raw);
}

my $projects = api_get('/api/projects');
$projects = $projects->{projects} || $projects->{data} || [];

my $root_id;
{
    my $wt_file = "$FindBin::Bin/../root/config/worktrees.json";
    if (-s $wt_file) {
        my $txt; open my $fh, '<:raw', $wt_file or die "$wt_file: $!"; local $/; $txt = <$fh>; close $fh;
        my $wt = eval { decode_json($txt) } || {};
        $root_id = $wt->{branches}{$branch}{project_id} if ref $wt->{branches} eq 'HASH';
    }
}
die "cannot resolve a root project for branch '$branch' (check root/config/worktrees.json)\n"
    unless $root_id;

my %branch = ($root_id => 1);
my $added = 1;
while ($added) {
    $added = 0;
    for my $p (@$projects) {
        my $pid = $p->{id} // $p->{project_id};
        next unless defined $pid;
        next if $branch{$pid};
        if ($branch{ $p->{parent_id} // 0 }) { $branch{$pid} = 1; $added = 1; }
    }
}
my @pids = sort { $a <=> $b } keys %branch;
printf "branch=%s root=%s projects=%s\n", $branch, $root_id, join(',', @pids);

# --- the candidate queue: same selection + ordering as the controller -------
# The branch view does NOT render branch-only todos. It renders @all_sorted
# (every row that passes the focus filters) ordered Active -> branch ->
# blocking -> score, truncated to FOCUS_QUEUE_LIMIT. Scoring only
# branch-project rows left ~7 rendered rows unscored and un-reorderable.
my $todos = api_get('/api/todos');
$todos = $todos->{todos} || $todos->{data} || [];
my @rows = grep { my $s = $_->{status} // '';
                  $s ne '3' && $s ne '4' && $s !~ /^(done|completed|closed|cancel)/i }
           grep { !($_->{is_recurring} // 0) }
           @$todos;

# same exclusions the controller applies before scoring
{
    require Comserv::Util::ProjectDependencies;
    require Comserv::Util::TodoTypes;
    @rows = grep {
        !Comserv::Util::ProjectDependencies::is_audit_panel_todo($_->{subject}, $_->{parent_id})
        && !Comserv::Util::TodoTypes::is_calendar_fixture($_)
    } @rows;
}

die "no open todos to score\n" unless @rows;

my $now = time;
Comserv::Util::TodoRanking::score_todo($_, { now_epoch => $now }) for @rows;

# Order EXACTLY like the branch view: cmp_branch_focus, then take the window
# from the top — those are the rows the page actually shows first.
require Comserv::Util::FocusRanking;
my %scope = map { $_ => 1 } @pids;
my @ordered = sort {
    Comserv::Util::FocusRanking::cmp_branch_focus($a, $b,
        { branch => $branch, branch_project_ids => \%scope })
} @rows;

my @by_code = @ordered;
printf "candidates=%d (open, post-exclusion)  branch=%s  window=%d\n\n",
    scalar(@rows), $branch, $window;

# --- model ordering (the window is the top N by hardcoded score) ------------
print "asking $model (one batched call)...\n";
my $t0 = time;
my $entry = Comserv::Util::AI::DecisionRank->score_branch($branch, \@by_code,
    model => $model, gate => $gate, window => $window);
my $elapsed = time - $t0;

if ($entry->{error}) {
    print "FAILED after ${elapsed}s: $entry->{error}\n";
    exit 1;
}
printf "elapsed=%ds model=%s asked=%s answered=%s input_tokens=%s\n\n",
    $elapsed, $entry->{model}, ($entry->{asked} // '?'), ($entry->{answered} // '?'),
    ($entry->{input_tokens} // '?');

if ($print) {
    # Show the APPLIED order (what the page will render), not a re-sort of the
    # whole candidate set — the window is only $window rows deep, and everything
    # outside it is deliberately left on the hardcoded order.
    my %was; $was{ $by_code[$_]{record_id} } = $_ + 1 for 0 .. $#by_code;
    my $applied = Comserv::Util::AI::DecisionRank->apply_order(
        [@by_code], $entry,
        { branch => $branch, branch_project_ids => \%scope, gate => $gate });
    unless ($applied) {
        print "apply_order returned nothing - cannot show applied order\n";
    }
    else {
        printf "%-5s %-5s %-6s %-7s %-6s %-5s %s\n",
            'was', 'now', 'move', 'coded', 'dec', 'conf', 'todo';
        print '-' x 104, "\n";
        my @head = @$applied[0 .. ($#$applied > 24 ? 24 : $#$applied)];
        for my $i (0 .. $#head) {
            my $r  = $head[$i];
            my $id = $r->{record_id};
            my $w  = $was{$id} // '?';
            my $mv = ($w =~ /^\d+$/) ? ($w - ($i + 1)) : 0;
            printf "%-5s %-5s %-6s %-7.3f %-6s %-5s %s%s\n",
                $w, $i + 1, ($mv > 0 ? "+$mv" : $mv),
                ($r->{ap_score} // 0),
                (defined $r->{decision_score} ? sprintf('%.3f', $r->{decision_score}) : '-'),
                (defined $r->{decision_conf} ? sprintf('%.2f', $r->{decision_conf}) : '-'),
                substr(($r->{subject} // ''), 0, 44),
                ($r->{decision_used} ? '  <- MODEL' : '');
        }
        my $used  = grep { $_->{decision_used} } @$applied;
        # how many rows changed position at all
        my %now; $now{ $applied->[$_]{record_id} } = $_ + 1 for 0 .. $#$applied;
        my $changed = grep { ($was{ $applied->[$_]{record_id} } // 0) != $_ + 1 }
                      0 .. $#$applied;
        printf "\nwindow=%d scored=%d gate-passed=%d rows_changed_position=%d of %d candidates\n",
            $entry->{window}, scalar(keys %{ $entry->{rows} }), $used, $changed, scalar(@by_code);
    }
    print "\n";
}

if ($dry) {
    print "[dry-run] cache NOT written\n";
} else {
    my $file = Comserv::Util::AI::DecisionRank->write_cache($branch, $entry);
    print "cache written: $file\n";
    printf "  branch=%s model=%s gate=%.2f computed_at=%s rows=%d\n",
        $branch, $entry->{model}, $entry->{gate}, $entry->{computed_at},
        scalar keys %{ $entry->{rows} };

    # Record what the page will do with it: hardcoded order vs model order vs
    # final order. Without this a bad outcome cannot be attributed to the model
    # vs the gate/grouping logic.
    my $final = Comserv::Util::AI::DecisionRank->apply_order(
        [@by_code], $entry,
        { branch => $branch, branch_project_ids => \%scope, gate => $gate });
    if ($final) {
        my @coded = map { $_->{record_id} } @by_code[0 .. ($#by_code > 19 ? 19 : $#by_code)];
        my @model = map { $_->{record_id} } sort {
            ($entry->{rows}{ $b->{record_id} }{score} // -1)
                <=> ($entry->{rows}{ $a->{record_id} }{score} // -1)
        } @by_code[0 .. ($#by_code > 19 ? 19 : $#by_code)];
        my @fin = map { $_->{record_id} } @$final[0 .. ($#$final > 19 ? 19 : $#$final)];
        my $passed = grep { $_->{decision_used} } @$final;
        my %was; $was{ $by_code[$_]{record_id} } = $_ + 1 for 0 .. $#by_code;
        my $changed = grep { ($was{ $final->[$_]{record_id} } // 0) != $_ + 1 } 0 .. $#$final;
        Comserv::Util::AI::DecisionRank->record_apply($branch, {
            model       => $entry->{model},
            gate        => $entry->{gate},
            window      => $entry->{window},
            candidates  => scalar(@by_code),
            gate_passed => $passed,
            changed     => $changed,
            coded_order => \@coded,
            model_order => \@model,
            final_order => \@fin,
        });
        print "apply record appended to ", Comserv::Util::AI::DecisionRank->call_log_file, "\n";
    }
}
