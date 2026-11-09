use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use Comserv::Util::BranchServerControl;

# Launcher contract: start a branch dashboard without a host dashboard on :9119,
# never block the request (single Twiggy process), and report errors clearly.
# The spawn and the port probe are stubbed, and the log dir is temp: no
# dashboard is ever started, and a live :9119 cannot make the test go green
# for the wrong reason.

my $dir = tempdir(CLEANUP => 1);
local $Comserv::Util::BranchServerControl::HERMES_LOG_DIR = $dir;

{
    package TestBSC;
    use parent 'Comserv::Util::BranchServerControl';
    our $listening = 0;
    sub _port_listening { return $TestBSC::listening }
}

my $c = TestBSC->new;

# --- the launch line does not depend on :9119 --------------------------------
my $cmd = $c->hermes_launch_command('3d', '/w/3d/Comserv', '/usr/bin/hermes', 9103);
like($cmd, qr/\bdashboard --isolated\b/, 'launch is --isolated, so no attach/refuse against :9119');
like($cmd, qr/--port 9103\b/, 'launch binds the branch port');
unlike($cmd, qr/--port 9119\b/, 'branch launch never targets the fleet dashboard port');
like($cmd, qr{cd '/w/3d/Comserv'}, 'launch cds into the worktree git root');

# --- lock: a second concurrent start is refused immediately ------------------
my $lock = $Comserv::Util::BranchServerControl::HERMES_LOG_DIR . '/hermes-dash-main.start.lock';
my $held = $c->_start_lock($lock);
ok($held, 'first start takes the lock');

my $t0 = time;
my $blocked = $c->open_or_start_hermes('main', 3001);
my $waited = time - $t0;

is($blocked->{ok}, 0, 'a second start while one is in progress is refused');
like($blocked->{error}, qr/already in progress/, 'refusal says a start is already in progress');
cmp_ok($waited, '<', 2, 'the refusal is immediate, not a blocking flock');

my $again = $c->_start_lock($lock);
ok(!$again, 'LOCK_NB: the lock is refused while held');

$c->_unlock($held);
my $reacquired = $c->_start_lock($lock);
ok($reacquired, 'the lock is available again once released');
$c->_unlock($reacquired);

# --- a start with no host dashboard writes the log line first ---------------
{
    my @spawned;
    local $Comserv::Util::BranchServerControl::HERMES_LAUNCHER = sub {
        my ($self, $command) = @_;
        push @spawned, $command;
        return 0;
    };
    my $res = $c->open_or_start_hermes('main', 3001);
    is($res->{ok}, 1, 'start succeeds without any :9119 involvement');
    is($res->{started}, 1, 'start is reported as started');
    is($res->{running}, 0, 'start does not claim the port is already open');
    is(scalar @spawned, 1, 'exactly one launch was spawned');

    my $log = $res->{log};
    ok(-f $log, 'the log file exists (first line written before the spawn)');
    my $text = '';
    if (-f $log) {
        $text = do { local $/; open my $fh, '<', $log or die $!; <$fh> } // '';
    }
    like($text, qr/hermes start branch=main port=9119/, 'log starts with a timestamped launch line');
    like($text, qr/--isolated/, 'log line shows the --isolated command');
}

# --- a spawn failure is reported, not swallowed -----------------------------
{
    local $Comserv::Util::BranchServerControl::HERMES_LAUNCHER = sub { return 256 };  # exit 1
    my $res = $c->open_or_start_hermes('main', 3001);
    is($res->{ok}, 0, 'spawn failure is not reported as success');
    like($res->{error}, qr/spawn failed \(exit 1\)/, 'spawn failure names the exit code');
}

# --- input validation -------------------------------------------------------
{
    my $bad = $c->open_or_start_hermes('bad;branch', 3001);
    is($bad->{ok}, 0, 'branch metacharacters are refused');
    like($bad->{error}, qr/invalid branch/, 'refusal names the reason');
}

# --- branch server control keeps its guards ---------------------------------
# These refuse before any unit/port/process work, so they need no live server.
is($c->hermes_port_for('main', 3001), 9119, 'main keeps the fleet dashboard port');
is($c->hermes_port_for('', 0), 9119, 'no branch falls back to the fleet port');

my $inject = $c->start('aisystem;rm', 4006);
ok(!$inject->{ok}, 'start refuses a branch that is not a registered name');
like($inject->{error}, qr/invalid branch/, 'start refusal names the branch');

ok(!$c->unit_name('aisystem;id', 4006), 'unit_name rejects branch metacharacters');

my $wrong_port = $c->stop('main', 4000);
ok(!$wrong_port->{ok}, 'stop refuses a port that is not the registered one');
like($wrong_port->{error}, qr/not the registered port/, 'mismatch names the registered port');

my $bad_port = $c->start('main', 'abc');
ok(!$bad_port->{ok}, 'start refuses a non-numeric port');
like($bad_port->{error}, qr/invalid port/, 'non-numeric port refusal names the reason');

done_testing;
