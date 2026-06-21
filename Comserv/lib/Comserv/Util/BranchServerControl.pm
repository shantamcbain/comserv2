package Comserv::Util::BranchServerControl;

use strict;
use warnings;
use JSON qw(encode_json);

our %DEFAULT_COMMANDS = (
    'main' => 'cd /home/shanta/PycharmProjects/comserv2/Comserv && CATALYST_DEBUG=1 DISABLE_HEALTH_MONITOR=1 perl script/comserv_server.pl -p 3001 -r',
);

sub new { bless {}, shift }

sub get_command {
    my ($self, $branch, $port) = @_;
    return $DEFAULT_COMMANDS{$branch}
        || "cd /home/shanta/.zenflow/worktrees/$branch/Comserv && CATALYST_DEBUG=1 perl script/comserv_server.pl -p $port -r";
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

1;