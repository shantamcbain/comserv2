package Comserv::Controller::Status;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

=head1 NAME

Comserv::Controller::Status - Catalyst Controller for application status monitoring

=head1 DESCRIPTION

Exposes endpoints for monitoring application health, memory usage, and performance.

=cut

sub memory :Local {
    my ($self, $c) = @_;
    
    my $status = {
        pid => $$,
        time => scalar localtime(),
        memory => $self->_get_memory_usage(),
    };
    
    $c->stash->{json} = $status;
    $c->forward($c->view('JSON'));
}

sub _get_memory_usage {
    my $self = shift;
    
    # Try to read /proc/self/status on Linux
    if (-f "/proc/self/status") {
        my %stats;
        my $data = eval {
            open my $fh, '<', "/proc/self/status" or return { error => "Cannot open /proc/self/status: $!" };
            while (<$fh>) {
                if (/^(VmRSS|VmSize|VmData|VmStack|VmExe|VmLib):\s+(\d+)\s+kB/) {
                    $stats{$1} = $2 . " kB";
                }
            }
            close $fh;
            return \%stats;
        };
        return $data if ref($data) eq 'HASH';
        return { error => "Could not read memory statistics: $@" };
    }
    
    # Fallback for non-Linux or failures
    return { error => "Memory statistics not available (not Linux or /proc not mounted)" };
}

__PACKAGE__->meta->make_immutable;

1;
