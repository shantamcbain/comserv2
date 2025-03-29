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
use File::Spec;
use File::Copy;
use FindBin;
use File::Path qw(make_path);
use Fcntl qw(:flock LOCK_EX LOCK_UN O_WRONLY O_APPEND O_CREAT);
use POSIX qw(strftime);
use File::Spec;
use Fcntl qw(:flock O_WRONLY O_APPEND O_CREAT);
use POSIX qw(strftime); # For timestamp formatting


my $MAX_LOG_SIZE = 100 * 1024; # 100 KB max size for easier AI analysis
my $ROTATION_THRESHOLD = 80 * 1024; # Rotate at 80 KB to prevent exceeding max size
my $MAX_LOG_FILES = 20; # Maximum number of archived log files to keep

# Declare package variables
our $LOG_FH;
our $LOG_FILE;
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

# Log rotation method
sub rotate_log {
    my ($class) = @_;
    return unless defined $LOG_FILE && -e $LOG_FILE;

    my $file_size = -s $LOG_FILE;
    _print_log("Current log file size: $file_size bytes, max size: $MAX_LOG_SIZE bytes");
    return if $file_size < $MAX_LOG_SIZE;

    # Log that we're rotating the file
    _print_log("Log file size ($file_size bytes) exceeds maximum size ($MAX_LOG_SIZE bytes). Rotating log file.");

    # Generate timestamped filename
    my $timestamp = strftime("%Y%m%d_%H%M%S", localtime);
    my ($volume, $directories, $filename) = File::Spec->splitpath($LOG_FILE);
    my $archive_dir = File::Spec->catdir($directories, 'archive');
    make_path($archive_dir) unless -d $archive_dir;

    my $archived_log = File::Spec->catfile($archive_dir, "${filename}_${timestamp}");

    # Close current log file handle
    close $LOG_FH if $LOG_FH;

    # For very large files, we'll split them into chunks
    if ($file_size > $MAX_LOG_SIZE * 2) {
        _print_log("Log file is very large ($file_size bytes). Splitting into chunks of $MAX_LOG_SIZE bytes.");
        # Simplified approach - just move the file without splitting
        move($LOG_FILE, $archived_log) or die "Could not rotate log: $!";
    } else {
        # For smaller files, just move the whole file
        move($LOG_FILE, $archived_log) or die "Could not rotate log: $!";
    }

    # Reopen log file
    sysopen($LOG_FH, $LOG_FILE, O_WRONLY | O_APPEND | O_CREAT, 0644)
        or die "Cannot reopen log file after rotation: $!";

    # Clean up old log files if we have too many
    _cleanup_old_logs($archive_dir, $filename);

    _print_log("Log rotated: $archived_log");
}

# Helper function to clean up old log files
sub _cleanup_old_logs {
    my ($archive_dir, $base_filename) = @_;

    # Get all archived log files for this base filename
    opendir(my $dh, $archive_dir) or do {
        _print_log("Cannot open archive directory $archive_dir: $!");
        return;
    };

    my @log_files = grep { /^${base_filename}_\d{8}_\d{6}(_chunk\d+)?$/ } readdir($dh);
    closedir($dh);

    # If we have more than MAX_LOG_FILES, delete the oldest ones
    if (scalar(@log_files) > $MAX_LOG_FILES) {
        # Extract timestamps from filenames for better sorting
        my %file_timestamps;
        foreach my $file (@log_files) {
            if ($file =~ /^${base_filename}_(\d{8}_\d{6})(?:_chunk\d+)?$/) {
                $file_timestamps{$file} = $1;
            } else {
                # Fallback to modification time if filename doesn't match expected pattern
                $file_timestamps{$file} = strftime("%Y%m%d_%H%M%S", localtime((stat(File::Spec->catfile($archive_dir, $file)))[9]));
            }
        }

        # Sort files by timestamp (oldest first)
        @log_files = sort {
            $file_timestamps{$a} cmp $file_timestamps{$b} ||
            $a cmp $b  # Secondary sort by filename for chunks with same timestamp
        } @log_files;

        # Delete the oldest files
        my $files_to_delete = scalar(@log_files) - $MAX_LOG_FILES;
        for (my $i = 0; $i < $files_to_delete; $i++) {
            my $file_to_delete = File::Spec->catfile($archive_dir, $log_files[$i]);
            if (unlink($file_to_delete)) {
                _print_log("Deleted old log file: $file_to_delete");
            } else {
                _print_log("Failed to delete old log file: $file_to_delete - $!");
            }
        }
    }
}

# Helper function to generate a timestamp
sub _get_timestamp {
    return strftime("%Y-%m-%d %H:%M:%S", localtime);
}

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
            _print_log("[ERROR] Failed to create log directory $log_dir: $@");
            die "Failed to create log directory $log_dir: $@\n";
        }
        _print_log("Log directory created: $log_dir");
    } else {
        _print_log("Log directory exists: $log_dir");
    }

    # Open the log file
    open($LOG_FH, '>>', $LOG_FILE) or do {
        warn "Can't open $LOG_FILE: $!";
        $LOG_FILE = '/tmp/comserv_app.log'; # Fallback to a temporary location
        open($LOG_FH, '>>', $LOG_FILE) or warn "Fallback log failed: $!";
    };

    # Ensure the file handle is auto-flushed
    select((select($LOG_FH), $| = 1)[0]);
    _print_log("Log file opened: $LOG_FILE");

    # Log initialization
    my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
    print $LOG_FH "[$timestamp] Logging system initialized\n";

    # Write a test entry to ensure the log file is created
    print $LOG_FH "Test log entry\n";
    _print_log("Wrote test log entry to file");

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

    # Log to file - this is our primary logging mechanism
    log_to_file($formatted_message, undef, $level);

    # Log to Catalyst context if available
    if ($c && ref($c) && ref($c->stash) eq 'HASH') {
        my $debug_errors = $c->stash->{debug_errors} ||= [];
        push @$debug_errors, $formatted_message;
    }

    return $formatted_message;
}

sub log_error {
    my ($self, $c, $file, $line, $error_message) = @_;

    # Default values
    $error_message //= 'No error message provided';

    # Format the error message
    my $formatted_message = sprintf("[ERROR] %s:%d - %s",
                                   $file || 'unknown',
                                   $line || 0,
                                   $error_message);

    # Log to file - this is our primary logging mechanism
    log_to_file($formatted_message, undef, 'ERROR');

    # Add to debug_errors in stash if Catalyst context is available
    if ($c && ref($c) && ref($c->stash) eq 'HASH') {
        my $debug_errors = $c->stash->{debug_errors} ||= [];
        push @$debug_errors, $formatted_message;
    }

    return $formatted_message;
}

# Define the log_dir method
sub log_dir {
    my ($self) = @_;
    my $log_dir = "$FindBin::Bin/../logs";

    # Ensure the logs directory exists
    unless (-d $log_dir) {
        eval { make_path($log_dir) };
        if ($@) {
            warn "[ERROR] Failed to create log directory $log_dir: $@";
            # Fallback to /tmp
            $log_dir = '/tmp';
        }
    }

    return $log_dir;
}

sub log_to_file {
    my ($message, $level, $type) = @_;
    my $self = __PACKAGE__->instance;

    $level //= 'INFO';
    $type //= 'general';

    eval {
        # Use simple timestamp instead of DateTime to avoid dependencies
        my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
        my $date = strftime("%Y-%m-%d", localtime);

        my $log_file = File::Spec->catfile(
            $self->log_dir,
            "${type}_${date}.log"
        );

        open my $fh, '>>', $log_file or die "Cannot open log file $log_file: $!";
        print $fh "[$timestamp] [$level] $message\n";
        close $fh;

        return 1;
    };
    if ($@) {
        warn "Failed to write to log file: $@";
        return 0;
    }
}
