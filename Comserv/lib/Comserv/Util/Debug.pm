package Comserv::Util::Debug;

use Moose;
use namespace::autoclean;

# Function to log with detailed information
sub log_with_details {
    my ($class, $message) = @_;
    my ($package, $filename, $line) = caller(1);
    my $caller = caller(0);

    # Instead of directly using $c, we'll assume it's passed as an argument
    my $c = shift if scalar @_ > 1;  # If there's more than one argument, the first is $c

    if ($c) {
        push @{$c->stash->{error_msg}}, "Entered log_with_details method in $caller";

        $c->log->debug(sprintf("[%s:%d] %s", $filename, $line, $message));
        push @{$c->stash->{error_msg}}, sprintf("[%s:%d] %s", $filename, $line, $message);
    }
    print STDERR sprintf("[%s:%d] %s\n", $filename, $line, $message);
}

# Make this module available as a singleton
__PACKAGE__->meta->make_immutable;
1;