package Comserv::Util::Logging;

use strict;
use warnings;
use namespace::autoclean;
use File::Spec;
use FindBin;
use File::Path qw(make_path);
use Fcntl qw(:flock LOCK_EX LOCK_UN O_WRONLY O_APPEND O_CREAT);
use POSIX qw(strftime);

# Declare package variables
our $LOG_FH;
our $LOG_FILE;

# Initialize the logging system
sub init {
    my ($class) = @_;

    # Define the log file path
    $LOG_FILE = "$FindBin::Bin/../logs/application.log";
    print "Initializing logging to $LOG_FILE\n";

    # Ensure the logs directory exists
    my $log_dir = "$FindBin::Bin/../logs";
    unless (-d $log_dir) {
        eval { make_path($log_dir) };
        if ($@) {
            warn "Failed to create log directory $log_dir: $@";
            $LOG_FILE = '/tmp/comserv_app.log'; # Fallback to a temporary location
        }
    }

    # Open the log file
    open($LOG_FH, '>>', $LOG_FILE) or do {
        warn "Can't open $LOG_FILE: $!";
        $LOG_FILE = '/tmp/comserv_app.log'; # Fallback to a temporary location
        open($LOG_FH, '>>', $LOG_FILE) or warn "Fallback log failed: $!";
    };

    # Set autoflush
    if (defined $LOG_FH) {
        my $old_fh = select($LOG_FH);
        $| = 1;
        select($old_fh);

        # Log initialization
        my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
        print $LOG_FH "[$timestamp] Logging system initialized\n";
    }

    return 1;
}

# Initialize on load
__PACKAGE__->init();

# Constructor
sub new {
    my ($class) = @_;
    my $self = bless {}, $class;
    return $self;
}

# Singleton-like instance method
sub instance {
    my ($class) = @_;
    return $class->new();
}

# Log a message with detailed context
sub log_with_details {
    my ($self, $c, $level, $file, $line, $subroutine, $message) = @_;

    # Default values
    $level //= 'INFO';
    $message //= 'No message provided';

    # Format the log message
    my $formatted_message = sprintf("[%s:%d] %s - %s",
                                   $file || 'unknown',
                                   $line || 0,
                                   $subroutine || 'unknown',
                                   $message);

    # Log to file
    _write_to_log($formatted_message, $level);

    # Log to Catalyst context if available
    if ($c && ref($c)) {
        if ($c->can('log') && $c->log->can($level)) {
            $c->log->$level($formatted_message);
        }

        if ($c->can('stash') && ref($c->stash) eq 'HASH') {
            my $debug_errors = $c->stash->{debug_errors} ||= [];
            push @$debug_errors, $formatted_message;
        }
    }

    return $formatted_message;
}

# Log an error message
sub log_error {
    my ($self, $c, $file, $line, $error_message) = @_;

    # Default values
    $error_message //= 'No error message provided';

    # Format the error message
    my $formatted_message = sprintf("[ERROR] %s:%d - %s",
                                   $file || 'unknown',
                                   $line || 0,
                                   $error_message);

    # Log to file
    _write_to_log($formatted_message, 'ERROR');

    # Log to Catalyst context if available
    if ($c && ref($c)) {
        if ($c->can('log') && $c->log->can('error')) {
            $c->log->error($formatted_message);
        }

        if ($c->can('stash') && ref($c->stash) eq 'HASH') {
            my $debug_errors = $c->stash->{debug_errors} ||= [];
            push @$debug_errors, $formatted_message;
        }
    }

    return $formatted_message;
}

# Internal function to write to the log file
sub _write_to_log {
    my ($message, $level) = @_;

    # Default level
    $level //= 'INFO';

    # Make sure logging is initialized
    unless (defined $LOG_FILE && defined $LOG_FH) {
        warn "Logging system not initialized. Initializing now.";
        __PACKAGE__->init();
    }

    # Return if we still don't have a file handle
    return unless defined $LOG_FH;

    # Add timestamp
    my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
    my $log_entry = "[$timestamp] [$level] $message\n";

    # Write to log file with locking
    eval {
        flock($LOG_FH, LOCK_EX);
        print $LOG_FH $log_entry;
        flock($LOG_FH, LOCK_UN);
    };

    if ($@) {
        warn "Error writing to log: $@";
    }
}

1;