package Comserv::Util::Logging;

use Moose;
use namespace::autoclean;

my $instance;

sub instance {
    return $instance //= __PACKAGE__->new;
}

# Fixed the log_with_details method to handle undefined message
sub log_with_details {
    my ($self, $c, $file, $line, $subroutine, $message) = @_;

    unless ($c && ref($c) && $c->can('stash')) {
        warn "log_with_details called without a valid context object";
        return;
    }

    # Ensure message is defined
    $message //= '';

    my $log_message = sprintf("[%s:%d] %s - %s", $file, $line, $subroutine, $message);

    if ($c->can('log')) {
        $c->log->debug($log_message);
    } else {
        warn "Logging object not available in context";
    }

    my $debug_error = $c->stash->{debug_error} ||= [];
    my $debug_errors = $c->stash->{debug_errors} ||= [];  # Ensure debug_errors is initialized
    push @$debug_error, $log_message;
    push @$debug_errors, $log_message;  # Add log message to debug_errors

    print STDERR "$log_message\n";
}


sub log_error {
    my ($self, $c, $error) = @_;
    my ($package, $filename, $line) = caller(2); # Adjusted to caller(2) for correct context
    my $log_message = sprintf("[%s:%d] Error: %s", $filename, $line, $error);

    if ($c->can('log')) {
        $c->log->error($log_message);
    } else {
        warn "Logging object not available in context";
    }

    my $debug_error = $c->stash->{debug_error} ||= [];
    my $debug_errors = $c->stash->{debug_errors} ||= [];  # Ensure debug_errors is initialized
    push @$debug_error, $log_message;
    push @$debug_errors, $log_message;  # Add log message to debug_errors

    print STDERR "From log_error: $log_message\n";
}

__PACKAGE__->meta->make_immutable;

1;
