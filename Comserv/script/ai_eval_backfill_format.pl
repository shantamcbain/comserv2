#!/usr/bin/env perl
# Backfill Problem/Impact/Solution/Risk (payload.format) on open eval proposals
# (Oct 10 2026). Backs up every touched payload_json first.
#   perl script/ai_eval_backfill_format.pl --dry-run
#   perl script/ai_eval_backfill_format.pl [--set ID --problem .. --impact .. --solution .. --risk .. [--title ..]]
#   perl script/ai_eval_backfill_format.pl --undo data/ai_eval_format_backup-<stamp>.json
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Getopt::Long;
use JSON::PP ();
use POSIX qw(strftime);
use Comserv::Util::AI::ProposalFormat;

my ($dry, $undo, $set, %f, $show) = (0);
GetOptions('dry-run' => \$dry, 'undo=s' => \$undo, 'set=i' => \$set, 'show=i' => \$show,
           map({ ("$_=s" => \$f{$_}) } qw(problem impact solution risk title))) or die "bad args\n";
{ local $SIG{__WARN__} = sub {}; local *STDERR; open STDERR, '>', '/dev/null'; require Comserv; Comserv->import; }
my $schema = Comserv->model('DBEncy')->schema;
my $rs = $schema->resultset('AiEvalProposal');
my $J = JSON::PP->new->canonical;

if ($show) {
    my $p = $rs->find($show) or die "no proposal $show\n";
    print JSON::PP->new->canonical->pretty->encode({ id => $p->id, status => $p->status, title => $p->title, rationale => $p->rationale,
        target => $p->target, change_type => $p->change_type, payload_json => $p->payload_json });
    exit 0;
}
if ($undo) {
    open my $fh, '<', $undo or die "$undo: $!"; local $/; my $b = $J->decode(<$fh>); close $fh;
    for my $id (sort keys %$b) {
        my $p = $rs->find($id) or next;
        $p->update({ payload_json => $b->{$id}{payload_json}, title => $b->{$id}{title} });
        print "restored #$id\n";
    }
    exit 0;
}
my @todo = $set ? ($rs->find($set) // die "no proposal $set\n")
                : $rs->search({ status => { -in => [qw(proposed approved)] } }, { order_by => 'id' })->all;
my (%backup, $n);
for my $p (@todo) {
    my $pl = defined $p->payload_json ? eval { JSON::PP->new->allow_nonref->decode($p->payload_json) } : undef;
    next if defined $pl && ref $pl ne 'HASH';
    next if !$set && ref $pl eq 'HASH' && ref $pl->{format} eq 'HASH';
    my $title = $set && $f{title} ? $f{title} : $p->title;
    my %in = (title => $title, rationale => $p->rationale, target => $p->target, change_type => $p->change_type);
    if ($set) { $in{$_} = $f{$_} for grep { defined $f{$_} } @Comserv::Util::AI::ProposalFormat::FIELDS }
    if ($set && ref $pl eq 'HASH') { delete $pl->{format} }
    my ($new, $derived) = Comserv::Util::AI::ProposalFormat::fold_into_payload(\%in, $pl);
    $backup{ $p->id } = { payload_json => $p->payload_json, title => $p->title };
    printf "#%d %s%s: derived [%s]\n", $p->id, ($dry ? '(dry) ' : ''), $title, join(',', @$derived);
    print "    $_: $new->{format}{$_}\n" for $set ? @Comserv::Util::AI::ProposalFormat::FIELDS : ();
    $n++;
    next if $dry;
    $p->update({ payload_json => $J->encode($new), ($title ne $p->title ? (title => $title) : ()) });
}
if (!$dry && $n) {
    my $f = "$FindBin::Bin/../data/ai_eval_format_backup-" . strftime('%Y%m%d-%H%M%S', localtime) . '.json';
    open my $fh, '>', $f or die "$f: $!"; print $fh JSON::PP->new->canonical->pretty->encode(\%backup); close $fh;
    print "backup: $f (undo: perl script/ai_eval_backfill_format.pl --undo $f)\n";
}
print "touched: ", ($n // 0), "\n";
