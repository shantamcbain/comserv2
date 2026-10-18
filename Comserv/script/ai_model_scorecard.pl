#!/usr/bin/env perl
# Model scorecard (Oct 10 2026): print the per model x task scorecard and,
# with --inbox, write data/ai_eval_inbox/<date>-model-scorecard.json (one
# summary line for the daily eval). Read-only on Hermes data.
#   perl script/ai_model_scorecard.pl [--inbox] [--days N] [--data-dir D]
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Getopt::Long;
use JSON::PP ();
use POSIX qw(strftime);
use Comserv::Model::AI2::ModelScorecard;

my ($inbox, $root) = (0, "$FindBin::Bin/..");
GetOptions('inbox' => \$inbox, 'root=s' => \$root) or die "usage: $0 [--inbox] [--root DIR]\n";
my $sc = Comserv::Model::AI2::ModelScorecard->new(root => $root)->build(force => 1);
my @rows = @{ $sc->{rows} };
my %sp = map { $_->{model} => $_ } @{ $sc->{speed} };
my $speed = join(', ', map { "$_ $sp{$_}{median_s}s/turn ($sp{$_}{calls_per_turn} calls)" }
                       grep { $sp{$_} } 'grok-4.7', 'grok-build-0.1', 'z-ai/glm-5.3-flash');
my %best;
for my $r (grep { defined $_->{rating} && $_->{task} ne 'aux' } @rows) {
    $best{ $r->{task} } = $r if !$best{ $r->{task} } || $r->{rating} > $best{ $r->{task} }{rating};
}
my $bestline = join('; ', map { "$_: $best{$_}{model} ($best{$_}{rating})" } sort keys %best);
my $line = "Model scorecard ($sc->{cfg}{days}d): median time-to-done $speed. Best cost-per-result by task: $bestline. Heuristic outcomes - see /ai/eval#model-scorecard.";
print "$line\n";
printf "%-14s %-32s %6s %5s %6s %7s %6s %6s %s\n", qw(task model rating sess calls quota% usd med_s outcomes);
for my $r (@rows) {
    my $oc = join(',', map { "$_=$r->{outcomes}{$_}" } sort keys %{ $r->{outcomes} });
    printf "%-14s %-32s %6s %5d %6d %7s %6s %6s %s\n", $r->{task}, substr($r->{model}, 0, 32), $r->{rating} // '-', $r->{sessions},
        $r->{calls}, $r->{quota_pct}, $r->{usd}, $r->{median_turn_s} // '-', $oc;
}
if ($inbox) {
    my $date = do { local $ENV{TZ} = 'America/Vancouver'; POSIX::tzset(); strftime('%Y-%m-%d', localtime) };
    my $dir = "$root/data/ai_eval_inbox";
    mkdir $dir unless -d $dir;
    my $f = "$dir/$date-model-scorecard.json";
    open my $fh, '>', $f or die "write $f: $!";
    print $fh JSON::PP->new->canonical->pretty->encode({
        report_date => $date, source => 'Model scorecard', created_by => 'script/ai_model_scorecard.pl',
        summary => $line,
        metrics => { model_scorecard => { speed => $sc->{speed}, rows => [ map { my %r = %$_; \%r } grep { $_->{task} ne 'aux' } @rows ], cfg => $sc->{cfg} } },
        markdown => "# Model scorecard $date\n\n$line\n",
    });
    close $fh;
    print "wrote $f\n";
}
