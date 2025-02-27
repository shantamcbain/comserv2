package Comserv::Util::Logging;

use strict;
use warnings;
use namespace::autoclean;
use FindBin;
use File::Path qw(make_path);

# Declare $LOG_FH at the package level
our $LOG_FH;

# Define the log file path
my $log_file = "$FindBin::Bin/logs/application.log";
print "Logging to $log_file\n";

# Ensure the logs directory exists
my $log_dir = "$FindBin::Bin/logs";
unless (-d $log_dir) {
    eval { make_path($log_dir) };
    if ($@) {
        warn "Failed to create log directory $log_dir: $@";
        $log_file = '/tmp/comserv_app.log'; # Fallback to a temporary location
    }
}

# Open the log file
open $LOG_FH, '>>', $log_file or do {
    warn "Can't open $log_file: $!";
    $log_file = '/tmp/comserv_app.log'; # Fallback to a temporary location
    open $LOG_FH, '>>', $log_file or warn "Fallback log failed: $!";
};

select((select($LOG_FH), $| = 1)[0]); # Autoflush




sub new {
    my ($class) = @_;
    my $self = bless {}, $class;
    return $self;
}

sub instance {
    my $class = shift;
    my $instance = $class->new();
    return $instance;
}

sub log_with_details {
    my ($self, $c, $level, $file, $line, $subroutine, $message) = @_;

    $message //= 'No message provided';
    my $log_message = sprintf("[%s:%d] %s - %s", $file, $line, $subroutine // 'unknown', $message);
    print $LOG_FH "$log_message\n"; # Always log to file

    if ($c && ref($c) && $c->can('stash')) {
        $c->log->debug($log_message) if $c->can('log');
        my $debug_errors = $c->stash->{debug_errors} ||= [];
        push @$debug_errors, $log_message;
    } else {
        print $LOG_FH "No context: $log_message\n";
    }
}

sub log_error {
    my ($self, $c, $file, $line, $error_message) = @_;

    my $log_message = "[ERROR] - $file:$line - $error_message";
    print $LOG_FH "$log_message\n";

    if ($c && ref($c) eq 'Catalyst') {
        push @{$c->stash->{debug_errors}}, $log_message;
        $c->log->error($log_message) if $c->can('log');
    } else {
        print $LOG_FH "No context for error: $log_message\n";
    }
}

1;
