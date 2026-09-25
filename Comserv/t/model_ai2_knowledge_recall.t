use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use File::Spec;

BEGIN { use_ok('Comserv::Model::AI2::KnowledgeRecall'); }

my $m = Comserv::Model::AI2::KnowledgeRecall->new;
ok($m, 'KnowledgeRecall instantiates');

my $dir = tempdir(CLEANUP => 1);
my $tt = File::Spec->catfile($dir, 'AISYSTEMPlan.tt');
open my $fh, '>', $tt or die $!;
print $fh "VERIFIED: Scheduler agent creates blockers. Never bulk-reschedule.\n";
close $fh;

my $pages = [
    { title => 'AISYSTEM Plan', path => 'AISYSTEMPlan.tt', description => 'AI system scheduler', roles => 'admin,developer', site => 'all' },
    { title => 'Secret ops', path => 'Secret.tt', description => 'internal only', roles => 'admin', site => 'CSC' },
];

my $priv = $m->file_docs_from_catalog($dir, $pages, 'scheduler', 1, 'CSC');
ok(@$priv, 'privileged query hits file catalog');
like($priv->[0]{content}, qr/Never bulk-reschedule/, 'reads file body not DB');
is($priv->[0]{source}, 'documentation-files', 'source is files');

my $guest = $m->file_docs_from_catalog($dir, $pages, 'scheduler', 0, 'CSC');
ok(@$guest == 0, 'guest does not see admin-only AISYSTEMPlan');

my $pub = [
    { title => 'Help', path => 'AISYSTEMPlan.tt', description => 'scheduler help', roles => 'all', site => 'all' },
];
my $g2 = $m->file_docs_from_catalog($dir, $pub, 'scheduler', 0, 'CSC');
ok(@$g2, 'guest sees roles=all file docs');

done_testing();
