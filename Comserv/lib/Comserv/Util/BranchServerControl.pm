package Comserv::Util::BranchServerControl;

use strict;
use warnings;
use JSON qw(encode_json);
use Comserv::Util::Git;

our %DEFAULT_COMMANDS = (
    'main' => 'cd /home/shanta/PycharmProjects/comserv2/Comserv && CATALYST_DEBUG=1 DISABLE_HEALTH_MONITOR=1 perl script/comserv_server.pl -p 3001 -r',
);

sub new { bless {}, shift }

sub get_command {
    my ($self, $branch, $port) = @_;
    return $DEFAULT_COMMANDS{$branch}
        || do {
            my $base = Comserv::Util::Git->worktree_base_dir;
            "cd $base/$branch/Comserv/Comserv && CATALYST_DEBUG=1 COMSERV_NO_HEALTH_LOG=1 perl script/comserv_server.pl -p $port -r";
        };
}

sub start {
    my ($self, $branch, $port) = @_;
    my $cmd = $self->get_command($branch, $port);
    my $res = system("$cmd > /tmp/branch-$branch.log 2>&1 &");
    return { ok => $res == 0 ? 1 : 0, action => 'start', branch => $branch };
}

sub stop {
    my ($self, $branch, $port) = @_;
    system("fuser -k ${port}/tcp 2>/dev/null || true");
    return { ok => 1, action => 'stop', branch => $branch };
}

sub restart {
    my ($self, $branch, $port) = @_;
    $self->stop($branch, $port);
    sleep 1;
    return $self->start($branch, $port);
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
        $res->{started} = 1;
        $res->{running} = 0;
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
    return 9119 if !$branch || $branch eq 'main' || $app_port == 3001;
    my $cfg = eval { Comserv::Util::Git->_worktree_config() } || {};
    my $override = eval { $cfg->{branches}{$branch}{hermes_port} };
    return int($override) if $override && $override >= 9100 && $override < 9200;
    return 9100 + ($app_port % 100);
}

sub hermes_cwd_for {
    my ($self, $branch) = @_;
    return '/home/shanta/PycharmProjects/comserv2' if !$branch || $branch eq 'main';
    my $base = eval { Comserv::Util::Git->worktree_base_dir } // "$ENV{HOME}/.comserv/worktrees";
    return "$base/$branch/Comserv";
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
    my $cmd = 'cd ' . quotemeta($cwd)
            . ' && nohup ' . quotemeta($bin)
            . " dashboard --isolated --host 0.0.0.0 --port $hport --no-open --skip-build"
            . ' >> ' . quotemeta($log) . ' 2>&1 &';
    my $rc = system('/bin/bash', '-lc', $cmd);
    if ($rc != 0) {
        return {
            ok => 0, error => "spawn exit $rc",
            branch => $branch, hermes_port => $hport, cwd => $cwd, log => $log,
        };
    }
    return {
        ok => 1, running => 0, started => 1,
        branch => $branch, hermes_port => $hport, cwd => $cwd, log => $log,
    };
}

1;