#!/usr/bin/env perl
# Safe AI auto-improver (AISYSTEM plan §5d/§5e). Demotes open-circuit /
# repeated-429 models to the end of their chain via the eval apply/revert
# machinery (Model::AI2::EvalReports->auto_apply). Only re-orderings and cap
# decreases are ever applied; everything is logged and revertable on /ai/eval.
#   perl script/ai_eval_auto_improve.pl [--dry-run] [--json]
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Getopt::Long;
use JSON ();
my ($dry, $json) = (0, 0);
GetOptions('dry-run' => \$dry, 'json' => \$json) or die "usage: $0 [--dry-run] [--json]\n";
{ local $SIG{__WARN__} = sub {}; local *STDERR; open STDERR, '>', '/dev/null'; require Comserv; Comserv->import; }
require Comserv::Model::AI2::EvalReports;
my $r = Comserv::Model::AI2::EvalReports->new->auto_apply('Comserv', dry_run => $dry, reason => 'auto-improver (open circuit / repeated 429)');
if ($json) { print JSON->new->canonical->pretty->encode($r); exit($r->{ok} ? 0 : 1) }
printf "auto-improver%s: %d planned, %d applied, %d skipped%s\n", ($dry ? ' (dry run)' : ''),
    scalar @{ $r->{planned} }, scalar @{ $r->{applied} }, scalar @{ $r->{skipped} },
    ($r->{report_id} ? " (report #$r->{report_id})" : '');
print "  plan:  $_->{target} -> [@{ $_->{value} }]  ($_->{rationale})\n" for @{ $r->{planned} };
print "  apply: #$_->{proposal_id} $_->{target}\n" for @{ $r->{applied} };
print "  skip:  $_->{target}: $_->{why}\n" for @{ $r->{skipped} };
print "  error: $r->{error}\n" if $r->{error};
exit($r->{ok} ? 0 : 1);
