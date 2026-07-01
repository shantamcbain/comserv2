package Comserv::Util::QuietHealthLog;
use Moose;
use namespace::autoclean;
extends 'Catalyst::Log';

# When COMSERV_NO_HEALTH_LOG=1, these paths produce ZERO output
my %QUIET = map { $_ => 1 } qw(
    admin/health/check
    chat/user_heartbeat
    chat/admin_heartbeat
    HelpDesk/admin/tickets_alert
);

my $_silent = 0;

sub _maybe_silence {
    my ($self, $msg) = @_;
    return 0 unless ($ENV{COMSERV_NO_HEALTH_LOG} // '') eq '1';

    # Detect request start
    if ($msg =~ /\*\*\* Request \d+/) {
        $_silent = 0;
    }

    # Check for quiet paths
    for my $p (keys %QUIET) {
        if ($msg =~ /Path is "$p"/ || $msg =~ /request for "$p"/) {
            $_silent = 1;
            return 1;  # suppress this line too
        }
    }

    return $_silent;
}

# Intercept at the lowest level - _log() is what all other methods call
around '_log' => sub {
    my $orig = shift;
    my $self = shift;
    my $msg  = join(' ', @_);
    return if $self->_maybe_silence($msg);
    $self->$orig(@_);
};

__PACKAGE__->meta->make_immutable;
1;