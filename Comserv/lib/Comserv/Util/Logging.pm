package Comserv::Util::Logging;

use strict;
use warnings;
use namespace::autoclean;

sub new {
    my ($class) = @_;
    my $self = bless { }, $class;
    return $self;
}

sub instance {
    my $class = shift;
    my $instance = $class->new();
    return $instance;
}

sub log_with_details {
    my ($self, $c, $file, $line, $subroutine, $message) = @_;

    unless ($c && ref($c) && $c->can('stash')) {
        warn "log_with_details called without a valid context object";
        return;
    }

    # Ensure message is defined
    $message //= 'No message provided';

    my $log_message = sprintf("[%s:%d] %s - %s", $file, $line, $subroutine // 'unknown', $message);

    # Log to Catalyst's debug log if available
    if ($c->can('log')) {
        $c->log->debug($log_message);
    } else {
        warn "Logging object not available in context";
    }

    # Add log message to stash
    my $debug_errors = $c->stash->{debug_errors} ||= [];
    push @$debug_errors, $log_message;

    # Print to STDERR for immediate visibility (optional, for debugging)
    print STDERR "$log_message\n";
}

sub log_error {
    my ($self, $c, $file, $line, $error_message) = @_;

    if (defined $c && ref($c) eq 'Catalyst') {
        my $log_message = "[ERROR] - $file:$line - $error_message";

        push @{$c->stash->{debug_errors}}, $log_message;

        $c->log->error($log_message);
    } else {
        warn "Attempted to log error with an invalid Catalyst context: $c";
    }
}

1; # End of module
