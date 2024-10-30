package Comserv::Util::Logging;

use Moose;
use namespace::autoclean;

my $instance;

sub instance {
    return $instance //= __PACKAGE__->new;
}

sub log_with_details {
    my ($self, $c, $message) = @_;

    unless ($c) {
        warn "log_with_details called without a context object";
        return;
    }

    my ($package, $filename, $line) = caller(1);
    my $caller = caller(0);

    # Log entry and exit for method debugging
    $self->_log_method_entry_exit($c, $caller, "Entered log_with_details method");

    # Log the message with file and line number
    $self->_log_message($c, $filename, $line, $message);
}

sub _log_method_entry_exit {
    my ($self, $c, $caller, $action) = @_;
    my $log_message = sprintf("[%s] %s", $caller, $action);
    $c->log->debug($log_message);
    print STDERR "$log_message\n";
}

sub _log_message {
    my ($self, $c, $filename, $line, $message) = @_;
    my $log_message = sprintf("[%s:%d] %s", $filename, $line, $message);
    $c->log->debug($log_message);

    # Append to stash for browser display
    if ($message =~ /error/i || $message =~ /warn/i) {  # or any other condition you want to track
        my $debug_error = $c->stash->{debug_error} || [];
        push @$debug_error, $log_message;
        $c->stash->{debug_error} = $debug_error;
    }

    # Print to STDERR for command line output
    print STDERR "$log_message\n";
}sub log_with_details {
    my ($self, $c, $message) = @_;

    unless ($c) {
        warn "log_with_details called without a context object";
        return;
    }

    my ($package, $filename, $line) = caller(1);
    my $caller = caller(0);

    # Log entry and exit for method debugging
    $self->_log_method_entry_exit($c, $caller, "Entered log_with_details method");

    # Log the message with file and line number
    $self->_log_message($c, $filename, $line, $message);
}

sub _log_method_entry_exit {
    my ($self, $c, $caller, $action) = @_;
    my $log_message = sprintf("[%s] %s", $caller, $action);

    # Ensure $c->log is available and used correctly
    if ($c->can('log')) {
        $c->log->debug($log_message);
    } else {
        warn "Logging object not available in context";
    }

    print STDERR "$log_message\n";
}

sub _log_message {
    my ($self, $c, $filename, $line, $message) = @_;
    my $log_message = sprintf("[%s:%d] %s", $filename, $line, $message);

    # Ensure $c->log is available and used correctly
    if ($c->can('log')) {
        $c->log->debug($log_message);
    } else {
        warn "Logging object not available in context";
    }

    # Append to stash for browser display
    if ($message =~ /error/i || $message =~ /warn/i) {
        my $debug_error = $c->stash->{debug_error} || [];
        push @$debug_error, $log_message;
        $c->stash->{debug_error} = $debug_error;
    }

    # Print to STDERR for command line output
    print STDERR "$log_message\n";
}


# Error handling method
sub log_error {
    my ($self, $c, $error) = @_;
    my ($package, $filename, $line) = caller(1);
    my $log_message = sprintf("[%s:%d] Error: %s", $filename, $line, $error);
    $c->log->error($log_message);
    print STDERR "From log_error: $log_message\n";

    # Push error to stash
    $c->stash->{debug_error} = $log_message;
}

# Make this module available as a singleton
__PACKAGE__->meta->make_immutable;
1;