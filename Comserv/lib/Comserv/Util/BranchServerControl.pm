package Comserv::Util::BranchServerControl;

use strict;
use warnings;
use JSON qw(encode_json);
use Fcntl qw(:DEFAULT :flock);
use Time::HiRes qw(time sleep);
use Comserv::Util::Git;

our %DEFAULT_COMMANDS = (
    'main' => 'cd /home/shanta/PycharmProjects/comserv2/Comserv && CATALYST_DEBUG=1 DISABLE_HEALTH_MONITOR=1 perl script/comserv_server.pl -p 3001 -r',
);

sub new { bless {}, shift }

our $START_TIMEOUT = 20;
our $START_POLL_INTERVAL = 0.25;

# Hermes launches return as soon as the process is spawned: the dashboard page
# reports "starting", and /admin/branch_server_log streams the boot output. A
# worktree start can take longer than this request should ever occupy the
# single-process web server.
our $HERMES_BIN = '/home/shanta/.local/bin/hermes';

# Overridable so tests can point the launcher at a stub and never start a real
# dashboard. Deliberately NOT read from the environment: a branch launch must be
# the same command however the web server was started.
our $HERMES_LAUNCHER = undef;   # sub ($self, $cmd) -> exit code; undef = system()

# Where the launcher writes its boot log. Overridable so tests never touch the
# live console log of a running branch.
our $HERMES_LOG_DIR = '/tmp';

sub _spawn {
    my ($self, $cmd) = @_;
    return $HERMES_LAUNCHER->($self, $cmd) if $HERMES_LAUNCHER;
    return system('/bin/bash', '-c', $cmd);
}

# Non-blocking startup lock. A second click while the first is still starting
# must get an immediate "already in progress" answer, not sit on a blocking
# flock that freezes the single-process (Twiggy) server for every other request
# — including the log poll that feeds the browser console.
sub _start_lock {
    my ($self, $path) = @_;
    sysopen(my $fh, $path, O_WRONLY | O_CREAT | O_APPEND, 0644)
        or return;
    return $fh if flock($fh, LOCK_EX | LOCK_NB);
    close $fh;
    return;
}

sub _unlock {
    my ($self, $fh) = @_;
    return unless $fh;
    flock($fh, LOCK_UN);
    close $fh;
}

sub _wait_for_port {
    my ($self, $port, $timeout) = @_;
    my $deadline = time() + ($timeout // $START_TIMEOUT);
    while (time() < $deadline) {
        return 1 if $self->_port_listening($port);
        sleep($START_POLL_INTERVAL);
    }
    return $self->_port_listening($port);
}

sub get_command {
    my ($self, $branch, $port) = @_;
    return $DEFAULT_COMMANDS{$branch}
        || do {
            my $base = Comserv::Util::Git->worktree_base_dir;
            "cd $base/$branch/Comserv/Comserv && CATALYST_DEBUG=1 COMSERV_NO_HEALTH_LOG=1 perl script/comserv_server.pl -p $port -r";
        };
}

sub _log {
    my ($level, $msg) = @_;
    eval {
        require Comserv::Util::Logging;
        Comserv::Util::Logging->instance->log_with_details(undef, $level, __FILE__, __LINE__, 'branch_server', $msg);
    };
}

# Branch names come from the dashboard POST. Only a registered worktree port is
# startable or stoppable. main is the primary checkout on 3001.
sub _check_target {
    my ($self, $branch, $port) = @_;
    return { ok => 0, error => 'invalid branch' }
        unless defined $branch && $branch =~ /\A[A-Za-z0-9._-]+\z/;
    return { ok => 0, error => 'invalid port' }
        unless defined $port && $port =~ /\A\d{2,5}\z/;
    $port = int($port);
    my $want;
    if ($branch eq 'main') {
        $want = 3001;
    } else {
        my $cfg = eval { Comserv::Util::Git->_worktree_config() } || {};
        $want = $cfg->{branches}{$branch}{port};
    }
    return { ok => 0, error => "branch $branch is not in worktrees.json" }
        unless defined $want && $want =~ /\A\d+\z/;
    return { ok => 0, error => "port $port is not the registered port for $branch ($want)" }
        if $port != int($want);
    return { ok => 1, branch => $branch, port => $port };
}

# comserv-<branch>-<port>.service, and only if that unit's ExecStart names this port.
sub unit_name {
    my ($self, $branch, $port) = @_;
    my $checked = $self->_check_target($branch, $port);
    return undef unless $checked->{ok};
    my $home = $ENV{HOME} || (getpwuid($<))[7] || '';
    return undef unless $home;
    my $name = "comserv-$checked->{branch}-$checked->{port}.service";
    my $path = "$home/.config/systemd/user/$name";
    return undef unless -f $path;
    open my $fh, '<', $path or return undef;
    local $/;
    my $txt = <$fh> // '';
    close $fh;
    return undef unless $txt =~ /-p\s+\Q$checked->{port}\E\b/;
    return $name;
}

sub _systemctl {
    my ($self, @args) = @_;
    my $quiet = 0;
    if (@args && ref $args[0] eq 'HASH') {
        my $opt = shift @args;
        $quiet = $opt->{quiet} ? 1 : 0;
    }
    my $runtime = '/run/user/' . $<;
    local $ENV{XDG_RUNTIME_DIR} = $runtime if !($ENV{XDG_RUNTIME_DIR} && -d $ENV{XDG_RUNTIME_DIR}) && -d $runtime;
    local $ENV{DBUS_SESSION_BUS_ADDRESS} = "unix:path=$runtime/bus"
        unless $ENV{DBUS_SESSION_BUS_ADDRESS};
    require IPC::Run3;
    my ($out, $err) = ('', '');
    my $ok = eval { IPC::Run3::run3(['systemctl', '--user', @args], \undef, \$out, \$err); 1 };
    my $rc = $ok ? ($? >> 8) : 127;
    my $err_s = $err // '';
    $err_s =~ s/\s+\z//;
    if (!$quiet && (!$ok || $rc != 0)) {
        _log('error', 'systemctl --user ' . join(' ', @args) . " failed: $err_s");
    }
    return { ok => $ok && $rc == 0 ? 1 : 0, rc => $rc, output => $out // '', error => $err_s };
}

# PIDs of comserv_server.pl bound to this port, plus the -r restarter parent and
# its server children. Never a pid whose command line is some other program.
sub _server_pids {
    my ($self, $port) = @_;
    require IPC::Run3;
    my $out = '';
    eval { IPC::Run3::run3(['ss', '-ltnp'], \undef, \$out, \undef); 1 };
    my %keep;
    for my $line (split /\n/, $out // '') {
        next unless $line =~ /:$port\b/;
        while ($line =~ /pid=(\d+)/g) {
            my $pid = $1;
            my $cmd = _cmdline($pid);
            $keep{$pid} = 1 if $cmd =~ /comserv_server\.pl/ && $cmd =~ /-p\s+\Q$port\E\b/;
        }
    }
    for my $pid (keys %keep) {
        my $ppid = _ppid($pid);
        next unless $ppid;
        my $pcmd = _cmdline($ppid);
        $keep{$ppid} = 1 if $pcmd =~ /comserv_server\.pl/ && $pcmd =~ /-p\s+\Q$port\E\b/;
    }
    if (opendir my $dh, '/proc') {
        my @nums = grep { /\A\d+\z/ } readdir $dh;
        closedir $dh;
        for my $cand (@nums) {
            my $ppid = _ppid($cand) or next;
            next unless $keep{$ppid};
            my $cmd = _cmdline($cand);
            $keep{$cand} = 1 if $cmd =~ /comserv_server\.pl/;
        }
    }
    return [ sort { $a <=> $b } keys %keep ];
}

sub _cmdline {
    my ($pid) = @_;
    return '' unless defined $pid && $pid =~ /\A\d+\z/;
    open my $fh, '<', "/proc/$pid/cmdline" or return '';
    local $/;
    my $cmd = <$fh> // '';
    close $fh;
    $cmd =~ s/\0/ /g;
    return $cmd;
}

sub _ppid {
    my ($pid) = @_;
    return undef unless defined $pid && $pid =~ /\A\d+\z/;
    open my $fh, '<', "/proc/$pid/stat" or return undef;
    my $stat = <$fh> // '';
    close $fh;
    return $1 if $stat =~ /\)\s+\S\s+(\d+)/;
    return undef;
}

sub _free_port {
    my ($self, $port) = @_;
    my $pids = $self->_server_pids($port);
    return { cleared => [], still => $self->_port_listening($port) ? 1 : 0 } unless @$pids;
    kill 'TERM', @$pids;
    my $deadline = time() + 3;
    while (time() < $deadline && $self->_port_listening($port)) {
        sleep 0.2;
    }
    if ($self->_port_listening($port)) {
        my $left = $self->_server_pids($port);
        kill 'KILL', @$left if @$left;
        sleep 0.3;
    }
    return { cleared => $pids, still => $self->_port_listening($port) ? 1 : 0 };
}

sub start {
    my ($self, $branch, $port) = @_;
    my $t = $self->_check_target($branch, $port);
    return { %$t, action => 'start' } unless $t->{ok};
    $branch = $t->{branch};
    $port   = $t->{port};
    my $log = "/tmp/branch-$branch.log";
    my $unit = $self->unit_name($branch, $port);
    my $lock = $self->_start_lock("/tmp/branch-$branch.start.lock");
    return {
        ok => 0, action => 'start', branch => $branch, port => $port, log => $log,
        error => "a start for $branch is already in progress",
    } unless $lock;

    if ($self->_port_listening($port)) {
        my $ours = $self->_server_pids($port);
        return {
            ok => 1, action => 'start', branch => $branch, port => $port,
            running => 1, started => 0, log => $log, via => $unit ? 'systemd' : 'process',
            unit => $unit // '',
        } if @$ours;
        _log('error', "start refused: port $port is in use by another process");
        return {
            ok => 0, action => 'start', branch => $branch, port => $port,
            error => "port $port is in use by another process",
        };
    }

    if ($unit) {
        my $sys = $self->_systemctl('start', $unit);
        if (!$sys->{ok}) {
            return {
                ok => 0, action => 'start', branch => $branch, port => $port,
                via => 'systemd', unit => $unit,
                error => 'systemctl start failed: ' . ($sys->{error} || "exit $sys->{rc}"),
            };
        }
        return {
            ok => 1, action => 'start', branch => $branch, port => $port,
            running => 1, started => 1, via => 'systemd', unit => $unit, log => $log,
        } if $self->_wait_for_port($port);
        my $active = $self->_systemctl({ quiet => 1 }, 'is-active', $unit);
        my $state = $active->{output} // '';
        $state =~ s/\s+\z//;
        _log('error', "unit $unit did not listen on $port (is-active=$state)");
        return {
            ok => 0, action => 'start', branch => $branch, port => $port,
            running => 0, started => 1, via => 'systemd', unit => $unit,
            error => "unit $unit did not listen on port $port (is-active=$state)",
        };
    }

    my $cmd = $self->get_command($branch, $port);
    my $res = system('/bin/bash', '-c', "$cmd > '$log' 2>&1 &");
    if ($res != 0) {
        _log('error', "spawn exit $res for $branch:$port");
        return {
            ok => 0, action => 'start', branch => $branch, port => $port, log => $log,
            via => 'process', error => "spawn exit $res",
        };
    }
    return {
        ok => 1, action => 'start', branch => $branch, port => $port,
        running => 1, started => 1, via => 'process', log => $log,
    } if $self->_wait_for_port($port);

    _log('error', "server did not listen on port $port within ${START_TIMEOUT}s");
    return {
        ok => 0, action => 'start', branch => $branch, port => $port,
        running => 0, started => 1, via => 'process', log => $log,
        error => "server did not listen on port $port within ${START_TIMEOUT}s",
    };
}

sub stop {
    my ($self, $branch, $port) = @_;
    my $t = $self->_check_target($branch, $port);
    return { %$t, action => 'stop' } unless $t->{ok};
    $branch = $t->{branch};
    $port   = $t->{port};
    my $unit = $self->unit_name($branch, $port);
    my $sys;
    if ($unit) {
        $sys = $self->_systemctl('stop', $unit);
    }
    my $freed = $self->_free_port($port);
    if ($freed->{still}) {
        _log('error', "port $port still listening after stop of $branch");
        return {
            ok => 0, action => 'stop', branch => $branch, port => $port,
            unit => $unit // '', via => $unit ? 'systemd' : 'process',
            cleared => $freed->{cleared},
            error => "port $port still listening after stop",
        };
    }
    return {
        ok => 1, action => 'stop', branch => $branch, port => $port,
        unit => $unit // '', via => $unit ? 'systemd' : 'process',
        cleared => $freed->{cleared}, running => 0,
        ($sys ? (systemd_stop => $sys->{ok}) : ()),
    };
}

sub restart {
    my ($self, $branch, $port) = @_;
    my $stopped = $self->stop($branch, $port);
    return $stopped unless $stopped->{ok};
    my $started = $self->start($branch, $port);
    $started->{action} = 'restart';
    $started->{cleared} = $stopped->{cleared} if $stopped->{cleared};
    return $started;
}

sub open_or_start {
    my ($self, $branch, $port) = @_;

    # More reliable check: try to connect to the port
    my $is_running = 0;
    eval {
        require IO::Socket::INET;
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 1,
        );
        $is_running = 1 if $sock;
        close($sock) if $sock;
    };

    if ($is_running) {
        return { ok => 1, running => 1, branch => $branch, port => $port };
    } else {
        my $res = $self->start($branch, $port);
        $res->{started} = 1 unless exists $res->{started};
        $res->{running} = 1 if $res->{ok} && !defined $res->{running};
        $res->{running} = 0 unless $res->{running};
        return $res;
    }
}

# Hermes dashboard port for a Catalyst branch server.
# main/:3001 stays on the fleet dashboard :9119.
# Worktrees: 9100 + (app_port % 100) so :4001 -> :9101, :4006 -> :9106.
# worktrees.json may set hermes_port to override.
sub hermes_port_for {
    my ($self, $branch, $app_port) = @_;
    $app_port = int($app_port || 0);
    my $ext = eval { Comserv::Util::Git->external_repo($branch) };
    return int($ext->{hermes_port}) if $ext && $ext->{hermes_port};
    return 9119 if !$branch || $branch eq 'main' || $app_port == 3001;
    my $cfg = eval { Comserv::Util::Git->_worktree_config() } || {};
    my $override = eval { $cfg->{branches}{$branch}{hermes_port} };
    return int($override) if $override && $override >= 9100 && $override < 9200;
    return 9100 + ($app_port % 100);
}

sub hermes_cwd_for {
    my ($self, $branch) = @_;
    my $ext = eval { Comserv::Util::Git->external_repo($branch) };
    return $ext->{repo} if $ext && $ext->{repo} && -d $ext->{repo};
    return '/home/shanta/PycharmProjects/comserv2' if !$branch || $branch eq 'main';
    my $base = eval { Comserv::Util::Git->worktree_base_dir } // "$ENV{HOME}/.comserv/worktrees";
    my $direct = "$base/$branch/Comserv";
    return $direct if -d $direct;
    # Dir name can disagree with the branch (git-dev is checked out in worktrees/git).
    return $direct unless $base && -d $base;
    opendir(my $dh, $base) or return $direct;
    my @entries = grep { $_ !~ /^\./ && -e "$base/$_/Comserv/.git" } readdir($dh);
    closedir($dh);
    for my $name (@entries) {
        my $dir = "$base/$name/Comserv";
        my $got = `git -C \Q$dir\E branch --show-current 2>/dev/null`;
        chomp $got if defined $got;
        return $dir if defined $got && $got eq $branch;
    }
    return $direct;
}

sub _port_listening {
    my ($self, $port) = @_;
    my $ok = 0;
    eval {
        require IO::Socket::INET;
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 1,
        );
        $ok = 1 if $sock;
        close($sock) if $sock;
    };
    return $ok;
}

# Start (or reuse) an isolated Hermes dashboard bound to this worktree's git root.
# --isolated makes the launch independent of the fleet dashboard on :9119: the CLI
# otherwise attaches to (or refuses behind) a host backend, which is what made a
# branch launch hinge on main's dashboard being up. Keep it for every branch.
#
# The request returns as soon as the process is spawned and the log has its first
# line. It must not wait for the port here: this app serves :3001 from ONE Twiggy
# process, so sleeping in the handler blocks the very /admin/branch_server_log
# poll that feeds the console — the console then sits at "(waiting for output…)"
# with an empty log even though the dashboard is booting.
sub open_or_start_hermes {
    my ($self, $branch, $app_port) = @_;
    $branch = '' unless defined $branch;
    return { ok => 0, error => 'invalid branch' }
        unless $branch eq 'main' || $branch =~ m{^[A-Za-z0-9._-]+$};

    my $cwd = $self->hermes_cwd_for($branch);
    return { ok => 0, error => "worktree git root missing: $cwd" } unless -d $cwd;

    my $hport = $self->hermes_port_for($branch, $app_port);
    return { ok => 0, error => "bad hermes port $hport" }
        unless $hport >= 9100 && $hport < 9200;

    my $log = "$HERMES_LOG_DIR/hermes-dash-$branch.log";
    my %where = (branch => $branch, hermes_port => $hport, cwd => $cwd, log => $log);

    if ($self->_port_listening($hport)) {
        return { %where, ok => 1, running => 1, started => 0 };
    }

    my $lock = $self->_start_lock("$HERMES_LOG_DIR/hermes-dash-$branch.start.lock");
    return {
        %where, ok => 0,
        error => "a Hermes start for $branch is already in progress",
    } unless $lock;

    if ($self->_port_listening($hport)) {
        $self->_unlock($lock);
        return { %where, ok => 1, running => 1, started => 0 };
    }

    my $bin = -x $HERMES_BIN ? $HERMES_BIN : 'hermes';
    my $cmd = $self->hermes_launch_command($branch, $cwd, $bin, $hport);

    # First line lands before the spawn, so the console always shows what was
    # launched even if the process dies before it can print anything.
    my $header_ok = $self->_write_log_header($log, $cmd, $branch, $hport, $bin, $cwd);
    if (!$header_ok) {
        $self->_unlock($lock);
        return { %where, ok => 0, error => "could not write $log: $!" };
    }

    my $rc = $self->_spawn($cmd);
    $self->_unlock($lock);
    if ($rc != 0) {
        _log('error', "hermes spawn exit " . ($rc >> 8) . " for $branch:$hport");
        return { %where, ok => 0, error => 'spawn failed (exit ' . ($rc >> 8) . ')', started => 0 };
    }

    return {
        %where, ok => 1, running => 0, started => 1,
        message => "Hermes dashboard for $branch is starting on port $hport",
    };
}

# The exact shell line the console shows. cd + env pinning keep the isolated
# dashboard in its own worktree; --isolated keeps it off the host backend.
#
# setsid gives the dashboard its own session and process group. Without it the
# dashboard joined the dev server's foreground process group in its terminal
# (ps: pgid = the comserv_server.pl pid, STAT "Sl+"). The dashboard installs its
# own SIGINT handler, so the Ctrl-C used to restart a dev server also shut down
# every Hermes dashboard that server had started; the next Hermes click then had
# to cold-start it behind the single-process dev server, and the console sat at
# "(waiting for output…)". nohup alone only covers SIGHUP. stdin is /dev/null
# so the detached process never holds the terminal.
sub hermes_launch_command {
    my ($self, $branch, $cwd, $bin, $hport) = @_;
    return "cd '$cwd'"
        . " && env -u HERMES_SESSION_ID -u HERMES_UPDATE_POST_SWAP -u HERMES_UPDATE_REEXEC"
        . " TERMINAL_CWD='$cwd' setsid nohup '$bin' dashboard --isolated --host 0.0.0.0"
        . " --port $hport --no-open --skip-build < /dev/null >> '$HERMES_LOG_DIR/hermes-dash-$branch.log' 2>&1 &";
}

sub _write_log_header {
    my ($self, $log, $cmd, $branch, $hport, $bin, $cwd) = @_;
    my $stamp = localtime();
    eval {
        open(my $fh, '>>', $log) or die "open $log: $!";
        printf {$fh} "[%s] hermes start branch=%s port=%s bin=%s cwd=%s\n  cmd: %s\n",
            $stamp, $branch, $hport, $bin, $cwd, $cmd;
        close($fh) or die "close $log: $!";
        1;
    } or do {
        my $err = $@ || 'unknown error';
        chomp $err;
        _log('error', "hermes log header failed for $branch: $err");
        return 0;
    };
    return 1;
}

1;