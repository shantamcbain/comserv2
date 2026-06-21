package Comserv::Util::DevServerControl;

use strict;
use warnings;
use JSON qw(encode_json decode_json);
use File::Spec;
use Comserv::Util::Logging;

our $DEFAULT_PORT = 3001;
our $DEFAULT_COMMAND = 'cd /home/shanta/PycharmProjects/comserv2/Comserv && CATALYST_DEBUG=1 DISABLE_HEALTH_MONITOR=1 perl script/comserv_server.pl -p 3001 -r';

sub new { bless {}, shift }

sub logging { Comserv::Util::Logging->instance }

sub _log_file { "/tmp/comserv-dev-$DEFAULT_PORT.log" }
sub _pid_file  { "/tmp/comserv-dev-$DEFAULT_PORT.pid" }

sub status {
    my ($self) = @_;
    my $pid_file = $self->_pid_file;
    return { running => 0 } unless -f $pid_file;

    my $pid = do { local $/; open my $fh, '<', $pid_file or return { running => 0 }; <$fh> };
    chomp $pid;
    return { running => 0 } unless $pid && kill(0, $pid);

    return {
        running => 1,
        pid     => $pid,
        log     => $self->_log_file,
    };
}

sub start {
    my ($self, $command) = @_;
    $command ||= $DEFAULT_COMMAND;

    my $status = $self->status;
    return { ok => 0, error => 'Already running' } if $status->{running};

    my $log  = $self->_log_file;
    my $pidf = $self->_pid_file;

    # Run in background, capture output
    my $full = "$command > $log 2>&1 & echo \$! > $pidf";
    system($full);

    sleep 1;
    my $new_status = $self->status;
    return { ok => 1, status => $new_status };
}

sub stop {
    my ($self) = @_;
    my $status = $self->status;
    return { ok => 1 } unless $status->{running};

    kill 'TERM', $status->{pid};
    unlink $self->_pid_file;
    unlink $self->_log_file;
    return { ok => 1 };
}

sub restart {
    my ($self, $command) = @_;
    $self->stop;
    sleep 1;
    return $self->start($command);
}

1;