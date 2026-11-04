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

sub _start_lock {
    my ($self, $path) = @_;
    sysopen(my $fh, $path, O_WRONLY | O_CREAT | O_APPEND, 0644)
        or return;
    flock($fh, LOCK_EX) or do { close $fh; return; };
    return $fh;
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
        error => 'could not acquire branch startup lock',
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
# --isolated is required: without it a second --port is refused while :9119 is up.
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

    if ($self->_port_listening($hport)) {
        return {
            ok => 1, running => 1, started => 0,
            branch => $branch, hermes_port => $hport, cwd => $cwd,
        };
    }

    my $bin = -x '/home/shanta/.local/bin/hermes' ? '/home/shanta/.local/bin/hermes' : 'hermes';
    my $log = "/tmp/hermes-dash-$branch.log";
    my $lock = $self->_start_lock("/tmp/hermes-dash-$branch.start.lock");
    return {
        ok => 0, error => 'could not acquire Hermes startup lock',
        branch => $branch, hermes_port => $hport, cwd => $cwd, log => $log,
    } unless $lock;

    if ($self->_port_listening($hport)) {
        return {
            ok => 1, running => 1, started => 0,
            branch => $branch, hermes_port => $hport, cwd => $cwd,
        };
    }

    # Pin TERMINAL_CWD to this worktree. Unset session/update leftovers so a
    # spawn from 9119 cannot leak InventoryAccounting (or any other) cwd into
    # the new isolated dashboard. bash -c not -l: login profiles often cd away.
    # Use single quotes for reliable shell quoting of paths (avoids quotemeta regex escapes).
    my $cmd = "cd '$cwd' && env -u HERMES_SESSION_ID -u HERMES_UPDATE_POST_SWAP -u HERMES_UPDATE_REEXEC TERMINAL_CWD='$cwd' nohup '$bin' dashboard --isolated --host 0.0.0.0 --port $hport --no-open --skip-build >> '$log' 2>&1 &";
    my $rc = system('/bin/bash', '-c', $cmd);
    if ($rc != 0) {
        return {
            ok => 0, error => "spawn exit $rc",
            branch => $branch, hermes_port => $hport, cwd => $cwd, log => $log,
        };
    }
    return {
        ok => 1, running => 1, started => 1,
        branch => $branch, hermes_port => $hport, cwd => $cwd, log => $log,
    } if $self->_wait_for_port($hport);

    return {
        ok => 0, running => 0, started => 1,
        branch => $branch, hermes_port => $hport, cwd => $cwd, log => $log,
        error => "Hermes dashboard did not listen on port $hport within ${START_TIMEOUT}s",
    };
}

1;