package Comserv::Logging;
use strict;
use warnings;
use Carp;
use Data::Dumper;

sub class_log_with_details {
    my ($class, $c, $file, $line, $subroutine, $message) = @_;
    
    # Ensure line is numeric, default to 0 if not
    $line = 0 unless defined $line && $line =~ /^\d+$/;
    
    # Create a detailed log message
    my $log_message = sprintf("[%s:%d] %s - %s", 
        $file // 'unknown', 
        $line, 
        $subroutine // 'unknown', 
        $message // ''
    );

    # Print to STDERR
    print STDERR "$log_message\n";

    # If a Catalyst context is provided, add to debug_errors in the stash
    if ($c && ref($c)) {
        $c->stash->{debug_errors} //= [];
        push @{$c->stash->{debug_errors}}, $log_message;
    }
}

sub log_with_details {
    my ($self, $c, $file, $line, $message) = @_;
    __PACKAGE__->class_log_with_details($c, $file, $line, (caller(1))[3], $message);
}

1;
