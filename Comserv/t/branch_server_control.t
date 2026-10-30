use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Comserv::Util::BranchServerControl;

my $c = Comserv::Util::BranchServerControl->new;

is($c->unit_name('aisystem', 4006), 'comserv-aisystem-4006.service', 'registered unit whose ExecStart names the port');
ok(!$c->unit_name('no-such-branch', 4006), 'unknown branch has no unit');
ok(!$c->unit_name('aisystem', 3001), 'wrong port is not this branch unit');
ok(!$c->unit_name('aisystem;id', 4006), 'branch metacharacters are rejected');

my $bad = $c->stop('aisystem', 3001);
ok(!$bad->{ok}, 'stop refuses a port that is not the registered one');
like($bad->{error}, qr/not the registered port/, 'mismatch names the registered port');

my $inject = $c->start('aisystem;rm', 4006);
ok(!$inject->{ok}, 'start refuses a branch that is not a registered name');

done_testing;
