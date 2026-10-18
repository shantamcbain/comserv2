#!/usr/bin/perl
# ATTRIBUTION PROBE: what is the decision model actually reacting to?
#
# SystemOne returns no rationale, so we infer it by asking the same state several
# different questions and correlating:
#   A) per item: importance (score) + is_broken (noul) + is_routine (noul)
#   B) per item: category (choice) — error_fix|feature|routine|admin|research
#   C) ABLATION: the same importance question with the P<n> priority label
#      REMOVED from the state. If the ranking barely moves it is reading the
#      label; if it moves a lot it is reading the content.
#
# Writes nothing. Reads the live cache for the window, so the rows match the page.
use strict;
use warnings;
use FindBin;
use lib '/home/shanta/.comserv/worktrees/aisystem/Comserv/Comserv/lib';
use JSON qw(decode_json);
use LWP::UserAgent;
use Comserv::Util::TodoRanking;
use Comserv::Util::FocusRanking;
use Comserv::Util::AI::DecisionRank;
use Comserv::Model::Ollama;
binmode(STDOUT, ':utf8');

my $MODEL = $ARGV[0] // 'nimble:latest';
my $ROOT  = '/home/shanta/.comserv/worktrees/aisystem/Comserv/Comserv';
my @PIDS  = (280, 281, 282, 283, 284, 287);
my %scope = map { $_ => 1 } @PIDS;

my $ua = LWP::UserAgent->new(timeout => 60);
sub api { my ($p) = @_; my $r = $ua->get("http://127.0.0.1:4006$p");
          die $r->status_line unless $r->is_success;
          my $t = $r->decoded_content; $t =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f]//g; decode_json($t) }

my $todos = api('/api/todos');
my @rows = grep { my $s = $_->{status} // '';
                  $s ne '3' && $s ne '4' && $s !~ /^(done|completed|closed|cancel)/i }
           grep { !($_->{is_recurring} // 0) }
           @{ $todos->{todos} || $todos->{data} || [] };
{
    require Comserv::Util::ProjectDependencies;
    require Comserv::Util::TodoTypes;
    @rows = grep {
        !Comserv::Util::ProjectDependencies::is_audit_panel_todo($_->{subject}, $_->{parent_id})
        && !Comserv::Util::TodoTypes::is_calendar_fixture($_)
    } @rows;
}
Comserv::Util::TodoRanking::score_todo($_, { now_epoch => time }) for @rows;
my @ordered = sort {
    Comserv::Util::FocusRanking::cmp_branch_focus($a, $b,
        { branch => 'aisystem', branch_project_ids => \%scope })
} @rows;
my @win = @ordered[0 .. 19];   # FOCUS_QUEUE_LIMIT

sub state_for {
    my ($rows, $with_prio) = @_;
    my $s = "Comserv2 dev branch open work. Which todo should be worked NEXT? "
          . "Higher = more important now. Work blocked by another todo is low value.\n";
    for my $r (@$rows) {
        my $subj = $r->{subject} // ''; $subj =~ s/\s+/ /g;
        my $p = $with_prio ? sprintf('P%s ', $r->{priority} // '?') : '';
        $s .= sprintf("t%s %ss=%s due=%s %s\n", $r->{record_id}, $p,
            ($r->{status} // '?'), ($r->{due_date} // '-'), substr($subj, 0, 52));
    }
    return $s;
}

sub ask {
    my ($state, $questions) = @_;
    my $o = Comserv::Model::Ollama->new(host => '127.0.0.1', port => 11434);
    $o->model($MODEL); $o->timeout(900);
    my $t0 = time;
    my $r  = $o->systemone(state => $state, questions => $questions);
    printf "   [%s asked=%d] %s elapsed=%ds\n", $MODEL, scalar(keys %$questions),
        ($r ? 'ok' : 'FAILED: ' . ($o->last_error // '?')), time - $t0;
    return $r;
}

my $state_p = state_for(\@win, 1);
my $state_n = state_for(\@win, 0);

# --- A: importance + is_broken + is_routine (60 questions) -----------------
my (%qA, %qC);
for my $r (@win) {
    my $id = $r->{record_id};
    $qA{"i$id"} = { type => 'score', instructions => "Importance of t$id now",
                    criteria => ['low', 'medium', 'high'] };
    $qA{"b$id"} = { type => 'noul', instructions => "Is t$id currently broken or failing?" };
    $qA{"r$id"} = { type => 'noul', instructions => "Is t$id recurring housekeeping that comes back?" };
    # C: identical importance question, state WITHOUT the P labels
    $qC{"i$id"} = { type => 'score', instructions => "Importance of t$id now",
                    criteria => ['low', 'medium', 'high'] };
}
print "A) importance + is_broken + is_routine (with P labels)\n";
my $respA = ask($state_p, \%qA) or exit 1;
print "C) same importance question, P labels STRIPPED from the state\n";
my $respC = ask($state_n, \%qC);

# --- B: category per item (20 questions) -----------------------------------
my %qB;
for my $r (@win) {
    my $id = $r->{record_id};
    $qB{"c$id"} = {
        type => 'choice', instructions => "Which category fits t$id?",
        criteria => {
            error_fix => 'fixes something broken or failing',
            feature   => 'adds new capability',
            routine   => 'recurring housekeeping',
            admin     => 'admin, docs or process',
            research  => 'investigation or planning',
        },
    };
}
print "B) category per item\n";
my $respB = ask($state_p, \%qB);

# --- analysis ---------------------------------------------------------------
my $o = Comserv::Model::Ollama->new(host => '127.0.0.1', port => 11434);
printf "\n%-5s %-3s %-7s %-8s %-8s %-11s %s\n",
    'id', 'P', 'ap', 'import', 'broken', 'routine', 'category';
print '-' x 96, "\n";
my (@imp, %by_cat, @broken_hi, @broken_lo, @rout_hi, @rout_lo);
for my $r (@win) {
    my $id = $r->{record_id};
    my ($imp)    = $o->systemone_score($respA, "i$id");
    my $broken   = $o->systemone_noul($respA, "b$id");
    my $routine  = $o->systemone_noul($respA, "r$id");
    my ($cat)    = $respB ? $o->systemone_choice($respB, "c$id") : (undef);
    push @imp, $imp if defined $imp;
    push @{ $by_cat{$cat} }, $imp if defined $cat && defined $imp;
    if (defined $broken && defined $imp) {
        push @{ $broken >= 0.5 ? \@broken_hi : \@broken_lo }, $imp;
    }
    if (defined $routine && defined $imp) {
        push @{ $routine >= 0.5 ? \@rout_hi : \@rout_lo }, $imp;
    }
    printf "%-5s %-3s %-7.2f %-8s %-8s %-11s %s\n", $id,
        ($r->{priority} // '?'), ($r->{ap_score} // 0),
        (defined $imp ? sprintf('%.3f', $imp) : '-'),
        (defined $broken ? sprintf('%.2f', $broken) : '-'),
        (defined $routine ? sprintf('%.2f', $routine) : '-'),
        ($cat // '-');
}

sub mean { my @v = @_; return @v ? (eval(join('+', @v)) / @v) : undef }
printf "\nmean importance overall: %.3f (n=%d)\n", mean(@imp), scalar(@imp);
for my $c (sort keys %by_cat) {
    printf "  category %-9s n=%-3d mean importance %.3f\n", $c,
        scalar(@{ $by_cat{$c} }), mean(@{ $by_cat{$c} });
}
printf "  is_broken>=0.5: n=%d mean %.3f   |  is_broken<0.5: n=%d mean %.3f\n",
    scalar(@broken_hi), mean(@broken_hi), scalar(@broken_lo), mean(@broken_lo);
printf "  is_routine>=0.5: n=%d mean %.3f  |  is_routine<0.5: n=%d mean %.3f\n",
    scalar(@rout_hi), mean(@rout_hi), scalar(@rout_lo), mean(@rout_lo);

# --- ablation: does removing the P label change the order? ------------------
if ($respC) {
    my (%impA, %impC);
    for my $r (@win) {
        my $id = $r->{record_id};
        ($impA{$id}) = $o->systemone_score($respA, "i$id");
        ($impC{$id}) = $o->systemone_score($respC, "i$id");
    }
    my @rkA = sort { $impA{$b} <=> $impA{$a} } grep { defined $impA{$_} } keys %impA;
    my @rkC = sort { $impC{$b} <=> $impC{$a} } grep { defined $impC{$_} } keys %impC;
    my %posA; $posA{ $rkA[$_] } = $_ + 1 for 0 .. $#rkA;
    my $moved = grep { ($posA{ $rkC[$_] } // 0) != $_ + 1 } 0 .. $#rkC;
    printf "\nP-label ablation: %d of %d positions changed when the P label was removed\n",
        $moved, scalar(@rkC);
    print "  with P : ", join(',', map { "#$_" } @rkA[0 .. 6]), "\n";
    print "  without: ", join(',', map { "#$_" } @rkC[0 .. 6]), "\n";
}
