use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use POSIX ();
use Time::HiRes qw(time);

BEGIN {
    eval { require DBI; require DBD::SQLite; 1 }
        or plan skip_all => 'DBI + DBD::SQLite required';
}
use_ok('Comserv::Util::ForkSafe');

my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1, AutoCommit => 1 });
$dbh->do('create table t (x int)');
my $sth = $dbh->prepare('select count(*) from t');

my $pid = fork();
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    # child: record whether InactiveDestroy got set, then leave without END/destructors
    my $rc = 3;
    eval {
        Comserv::Util::ForkSafe::child_prepare();
        $rc = ($dbh->{InactiveDestroy} && $sth->{InactiveDestroy}) ? 0 : 7;
        1;
    } or $rc = 9;
    Comserv::Util::ForkSafe::child_exit($rc);
}
waitpid($pid, 0);
is($? >> 8, 0, 'child: InactiveDestroy set on inherited dbh and sth; exited via _exit(0)');

ok($dbh->ping, 'parent handle still connected');
is($dbh->{InactiveDestroy} ? 1 : 0, 0, 'parent InactiveDestroy untouched');
$dbh->do('insert into t values (1)');
is($dbh->selectrow_array('select count(*) from t'), 1, 'parent can still use handle');

my $t0 = time;
DBI->disconnect_all;
ok(time - $t0 < 2, 'parent DBI->disconnect_all completes quickly');

# child_exit must skip END blocks
my $marker = "/tmp/fork_safe_end_$$";
unlink $marker;
my $p2 = fork();
if ($p2 == 0) {
    eval q{ END { if (open my $f, '>', $ENV{FS_MARKER}) { print $f "ran"; close $f } } };
    $ENV{FS_MARKER} = $marker;
    Comserv::Util::ForkSafe::child_exit(0);
}
waitpid($p2, 0);
ok(!-e $marker, 'child_exit skipped END blocks');
unlink $marker;

done_testing;
