package Comserv::Util::Logging;

# IMPORTANT: Always use this logging system throughout the application.
# Do NOT create new logging methods or use direct print statements.
# The preferred logging format is:
#   $self->logging->log_with_details($c, 'level', __FILE__, __LINE__, 'method_name', "Message");
# Where level can be: 'info', 'debug', 'warn', 'error', etc.
# This ensures consistent logging with file, line number, and method context.
#
# NOTE: This logging system has been updated to prevent recursion issues.
# It no longer calls Catalyst's logging methods directly, but instead logs to a file
# and adds messages to the debug_errors array in the stash.

use strict;
use warnings;
use namespace::autoclean;
use FindBin;
use File::Path qw(make_path);
use File::Spec;
use Fcntl qw(:flock O_WRONLY O_APPEND O_CREAT);
use POSIX qw(strftime); # For timestamp formatting

my $LOG_FH; # Global file handle for logging

# Internal subroutine to print log messages to STDERR and the log file
sub _print_log {
    my ($msg) = @_;
    print STDERR "$msg\n";
    if (defined $LOG_FH) {
        flock($LOG_FH, LOCK_EX);
        print $LOG_FH "$msg\n";
        flock($LOG_FH, LOCK_UN);
    }
}

# Helper function to generate a timestamp
sub _get_timestamp {
    return strftime("%Y-%m-%d %H:%M:%S", localtime);
}

# Initialize the logging system
sub init {
    my ($class) = @_;

    # Determine the base directory for logs
    my $base_dir = $ENV{'COMSERV_LOG_DIR'} // File::Spec->catdir($FindBin::Bin, '..');
    _print_log("Base directory: $base_dir");

    my $log_dir  = File::Spec->catdir($base_dir, "logs");
    my $log_file = File::Spec->catfile($log_dir, "application.log");
    _print_log("Log directory: $log_dir");
    _print_log("Log file: $log_file");

    # Create the log directory if it doesn't exist
    unless (-d $log_dir) {
        eval { make_path($log_dir) };
        if ($@) {
            _print_log("[ERROR] Failed to create log directory $log_dir: $@");
            die "Failed to create log directory $log_dir: $@\n";
        }
        _print_log("Log directory created: $log_dir");
    } else {
        _print_log("Log directory exists: $log_dir");
    }

    # Open the log file for appending
    unless (sysopen($LOG_FH, $log_file, O_WRONLY | O_APPEND | O_CREAT, 0644)) {
        my $error_message = "Can't open log file $log_file: $!";
        _print_log("[ERROR] $error_message");
        die $error_message;
    }

    # Ensure the file handle is auto-flushed
    select((select($LOG_FH), $| = 1)[0]);
    _print_log("Log file opened: $log_file");

    # Write a test entry to ensure the log file is created
    print $LOG_FH "Test log entry\n";
    _print_log("Wrote test log entry to file");

    # Log initialization message
    log_with_details(undef, 'INFO', __FILE__, __LINE__, 'init', "Logging system initialized");
}

# Constructor for creating a new instance
sub new {
    my ($class) = @_;
    return bless {}, $class;
}

# Singleton-like instance method
sub instance {
    my ($class) = @_;
    return $class->new();
}

# Log a message with detailed context (file, line, subroutine, etc.)
sub log_with_details {
    my ($self, $c, $level, $file, $line, $subroutine, $message) = @_;
    $message //= 'No message provided';
    $level   //= 'INFO';

    # Format the log message with a timestamp
    my $timestamp = _get_timestamp();
    my $log_message = sprintf("[%s] [%s:%d] %s - %s", $timestamp, $file, $line, ($subroutine // 'unknown'), $message);

    # Log to file - this is our primary logging mechanism
    log_to_file($log_message, undef, $level);

    # Add to debug_errors in stash if Catalyst context is available
    # But avoid calling $c->log methods to prevent recursion
    if ($c && ref($c) && ref($c->stash) eq 'HASH') {
        my $debug_errors = $c->stash->{debug_errors} ||= [];
        push @$debug_errors, $log_message;
    }

    return $log_message;
}

# Log an error message with context
sub log_error {
    my ($self, $c, $file, $line, $error_message) = @_;
    $error_message //= 'No error message provided';

    # Format the error message with a timestamp
    my $timestamp = _get_timestamp();
    my $log_message = sprintf("[%s] [ERROR] - %s:%d - %s", $timestamp, $file, $line, $error_message);

    # Log to file - this is our primary logging mechanism
    log_to_file($log_message, undef, 'ERROR');

    # Add to debug_errors in stash if Catalyst context is available
    # But avoid calling $c->log methods to prevent recursion
    if ($c && ref($c) && ref($c->stash) eq 'HASH') {
        my $debug_errors = $c->stash->{debug_errors} ||= [];
        push @$debug_errors, $log_message;
    }

    return $log_message;
}

# Log a message to a file (defaults to the global log file)
sub log_to_file {
    my ($message, $file_path, $level) = @_;
    $file_path //= File::Spec->catfile($FindBin::Bin, '..', 'logs', 'application.log');
    $level    //= 'INFO';

    # Declare $file with 'my' to fix the scoping issue
    my $file;
    unless (open $file, '>>', $file_path) {
        _print_log("Failed to open file: $file_path\n");
        return;
    }

    flock($file, LOCK_EX);
    print $file "$level: $message\n";
    flock($file, LOCK_UN);

    close $file;
}

# DEPRECATED: Don't use this method directly - use log_with_details instead
# This method is kept for backward compatibility
sub log_to_catalyst {
    my ($message, $c) = @_;
    # Simply log to file to avoid recursion with Catalyst's logging system
    _print_log("CATALYST LOG: $message");
    log_to_file("CATALYST LOG: $message");
}

1; # Ensure the module returns true