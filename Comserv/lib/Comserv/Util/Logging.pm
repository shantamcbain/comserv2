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
use File::Copy;
use FindBin;
use File::Path qw(make_path);
use File::Spec;
use Comserv::Util::NfsPath;
use Fcntl qw(:flock O_WRONLY O_APPEND O_CREAT);
use POSIX qw(strftime); # For timestamp formatting

my $LOG_FH; # Global file handle for logging
my $LOG_FILE; # Global log file path

my $MAX_LOG_SIZE = 100 * 1024; # 100 KB max size for easier AI analysis
my $ROTATION_THRESHOLD = 80 * 1024; # Rotate at 80 KB to prevent exceeding max size
my $MAX_LOG_FILES = 20; # Maximum number of archived log files to keep

# Level threshold for sending email notifications
our %LEVEL_PRIORITY = (
    'CRITICAL' => 5,
    'ERROR'    => 4,
    'WARN'     => 3,
    'INFO'     => 2,
    'DEBUG'    => 1,
);
our $EMAIL_NOTIFY_THRESHOLD = 'ERROR';

# Minimum level to write to the DB system_log table.
# DEBUG and INFO go only to the file log; WARN/ERROR/CRITICAL go to DB.
# This prevents millions of low-value rows from filling the table.
our $DB_LOG_MIN_LEVEL = 'WARN';

# Internal subroutine to print log messages to STDERR and the log file
sub _print_log {
    my ($msg) = @_;
    print STDERR "$msg\n";
    if (defined $LOG_FH && fileno($LOG_FH)) {
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
        $archived_log = _split_large_log($LOG_FILE, $archive_dir, $filename, $timestamp, $MAX_LOG_SIZE);
    } else {
        # For smaller files, just move the whole file
        File::Copy::move($LOG_FILE, $archived_log) or die "Could not rotate log: $!";
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

# Helper function to get the system identifier (Production, Workstation2, etc.)
sub get_system_identifier {
    my ($class) = @_;

    # 1. Explicit override via environment variable (set in Docker compose / systemd unit)
    my $identifier = $ENV{SYSTEM_IDENTIFIER};
    return $identifier if $identifier && $identifier ne '';

    # 2. Map known IP addresses to friendly names.
    # Use a UDP connect (no packets sent) to find which local IP the OS would
    # use when routing outbound — the most reliable way to get the primary LAN IP.
    my %IP_NAMES = (
        '192.168.1.126' => 'production',
        '192.168.1.199' => 'workstation',
    );
    eval {
        require Socket;
        socket(my $sock, Socket::AF_INET(), Socket::SOCK_DGRAM(), 0)
            or die "socket: $!";
        connect($sock, Socket::sockaddr_in(53, Socket::inet_aton('8.8.8.8')))
            or die "connect: $!";
        my $local = getsockname($sock);
        my (undef, $local_ip_packed) = Socket::sockaddr_in($local);
        my $ip = Socket::inet_ntoa($local_ip_packed);
        $identifier = $IP_NAMES{$ip} if exists $IP_NAMES{$ip};
    };

    # 3. Fall back to plain hostname
    unless ($identifier && $identifier ne '') {
        eval { require Sys::Hostname; $identifier = Sys::Hostname::hostname() };
        $identifier //= 'unknown';
    }

    return $identifier;
}

# Initialize the logging system
sub init {
    my ($class) = @_;

    # Determine the base directory for logs
    # Priority 1: Configured path in Database (logging_nfs_dir)
    # Priority 2: Standardized NFS shared directory (via Comserv::Util::NfsPath)
    # Priority 3: NFS shared directory from ENV (COMSERV_NFS_LOG_DIR)
    # Priority 4: Specific log directory from ENV (COMSERV_LOG_DIR)
    # Priority 5: Default relative to binary
    my $log_file;
    my $log_dir;

    # Note: DB access in init() might be restricted depending on startup sequence.
    # We use ENV as primary for bootstrap, and refresh_settings() for DB overrides later.
    
    my $nfs_path_util = Comserv::Util::NfsPath->new();
    my $standard_nfs = $nfs_path_util->get_nfs_root();
    my $standard_log_dir = File::Spec->catdir($standard_nfs, 'logs');
    
    my $nfs_log_dir = $ENV{'COMSERV_NFS_LOG_DIR'};
    
    if (-d $standard_log_dir && -w $standard_log_dir) {
        $log_dir  = $standard_log_dir;
        $log_file = File::Spec->catfile($log_dir, "application.log");
        _print_log("Using standardized NFS log directory: $log_dir");
    } elsif ($nfs_log_dir && -d $nfs_log_dir && -w $nfs_log_dir) {
        $log_dir  = $nfs_log_dir;
        $log_file = File::Spec->catfile($log_dir, "application.log");
        _print_log("Using centralized log directory: $log_dir");
    } else {
        my $base_dir = $ENV{'COMSERV_LOG_DIR'} // File::Spec->catdir($FindBin::Bin, '..');
        $log_dir  = File::Spec->catdir($base_dir, "logs");
        $log_file = File::Spec->catfile($log_dir, "application.log");
        _print_log("Using local log directory: $log_dir");
    }

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
    
    # Set global log file path for rotation
    $LOG_FILE = $log_file;
    _print_log("Global log file path set to: $LOG_FILE");

    # Log initialization message
    __PACKAGE__->log_with_details(undef, 'INFO', __FILE__, __LINE__, 'init', "Logging system initialized with log file: $LOG_FILE");
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
    my $system_id = __PACKAGE__->get_system_identifier();

    # Make sure $line is numeric, default to 0 if not
    $line = 0 unless defined $line && $line =~ /^\d+$/;

    my $log_message = sprintf("[%s] [%s] [%s:%d] %s - %s", $timestamp, $system_id, $file, $line, ($subroutine // 'unknown'), $message);

    # Add to debug_errors in stash if Catalyst context is available
    # But avoid calling $c->log methods to prevent recursion
    if ($c && ref($c) && ref($c->stash) eq 'HASH') {
        my $debug_errors = $c->stash->{debug_errors} ||= [];
        push @$debug_errors, $log_message;
    }

    # Restore standard behavior: also write to application log file and STDERR
    log_to_file($log_message, undef, $level);
    _print_log($log_message);

    # Log to database — only WARN and above to keep the table manageable.
    # DEBUG/INFO messages go to file log only.
    my $level_prio    = $LEVEL_PRIORITY{ uc($level) }           // 0;
    my $db_min_prio   = $LEVEL_PRIORITY{ uc($DB_LOG_MIN_LEVEL) } // 3;
    if ($c && ref($c) && $c->can('model') && $level_prio >= $db_min_prio) {
        my $sitename = ($c->can('stash') && $c->stash) ? ($c->stash->{SiteName} || 'CSC') : 'CSC';
        my $username = ($c->can('session') && $c->session) ? $c->session->{username} : undef;
        eval {
            my $dbh = $c->model('DBEncy')->storage->dbh;
            $dbh->do('SET SESSION innodb_lock_wait_timeout = 1');
            $c->model('DBEncy')->resultset('SystemLog')->create({
                timestamp         => $timestamp,
                level             => $level,
                file              => $file,
                line              => $line,
                subroutine        => ($subroutine // 'unknown'),
                message           => $message,
                sitename          => $sitename,
                username          => $username,
                system_identifier => $system_id,
            });
        };
        if ($@) {
            # Retry without system_identifier in case the column hasn't been added yet
            eval {
                my $dbh = $c->model('DBEncy')->storage->dbh;
                $dbh->do('SET SESSION innodb_lock_wait_timeout = 1');
                $c->model('DBEncy')->resultset('SystemLog')->create({
                    timestamp  => $timestamp,
                    level      => $level,
                    file       => $file,
                    line       => $line,
                    subroutine => ($subroutine // 'unknown'),
                    message    => $message,
                    sitename   => $sitename,
                    username   => $username,
                });
            };
            if ($@) {
                _print_log("[DB-LOG-ERROR] Failed to write to system_log table: $@");
            }
        }
    }

    # Automatically send email notification for levels >= $EMAIL_NOTIFY_THRESHOLD
    my $current_prio = $LEVEL_PRIORITY{uc($level)} || 0;
    my $notify_prio  = $LEVEL_PRIORITY{uc($EMAIL_NOTIFY_THRESHOLD)} || 3; # Default to WARN priority
    
    if ($current_prio >= $notify_prio) {
        # We don't want to cause recursion if send_error_notification calls logging
        # So we use a flag or just be careful. 
        # EmailNotification already logs things.
        eval {
            if (ref($self) || ($self && $self eq __PACKAGE__)) {
                $self->send_error_notification($c, "Application Alert: $subroutine ($level)", $log_message);
            } else {
                __PACKAGE__->send_error_notification($c, "Application Alert: $subroutine ($level)", $log_message);
            }
        };
        # Don't log the error of sending the error notification to avoid infinite loop
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
    # Pass 'ERROR' level explicitly
    log_to_file($log_message, undef, 'ERROR');

    # Add to debug_errors in stash if Catalyst context is available
    # But avoid calling $c->log methods to prevent recursion
    if ($c && ref($c) && ref($c->stash) eq 'HASH') {
        my $debug_errors = $c->stash->{debug_errors} ||= [];
        push @$debug_errors, $log_message;
    }

    # Automatically send email notification for ERROR level
    my $current_prio = $LEVEL_PRIORITY{'ERROR'} || 4; # Default ERROR priority
    my $notify_prio  = $LEVEL_PRIORITY{uc($EMAIL_NOTIFY_THRESHOLD)} || 4;
    
    if ($current_prio >= $notify_prio) {
        eval {
            if (ref($self) || ($self && $self eq __PACKAGE__)) {
                $self->send_error_notification($c, "Application Error", $log_message);
            } else {
                __PACKAGE__->send_error_notification($c, "Application Error", $log_message);
            }
        };
    }

    return $log_message;
}

# Send an error notification via email
sub send_error_notification {
    my ($self, $c, $subject, $error_details) = @_;
    
    my $system_id = __PACKAGE__->get_system_identifier();
    $subject = "[$system_id] $subject";
    return if $self->{_sending_email};
    local $self->{_sending_email} = 1;

    # Always notify CSC Admin for all errors
    my $csc_admin_email = 'helpdesk@computersystemconsulting.ca';
    my $site_admin_email;
    my $sitename = 'CSC';

    if ($c && ref($c) && $c->can('model')) {
        eval { # Use eval instead of try if Try::Tiny is not explicitly imported or available
            $sitename = ($c->can('stash') && $c->stash) ? ($c->stash->{SiteName} || 'CSC') : 'CSC';
            my $site = $c->model('DBEncy')->resultset('Site')->search({ name => $sitename })->single;
            if ($site && $site->mail_to_admin) {
                $site_admin_email = $site->mail_to_admin;
            }
        };
        # Ignore errors here, we have fallbacks
    }

    # Use the existing email system
    eval {
        require Comserv::Util::EmailNotification;
        my $notifier = Comserv::Util::EmailNotification->new(logging => $self);
        
        # 1. Notify CSC Admin
        $notifier->send_error_notification($c, $csc_admin_email, $subject, $error_details);
        
        # 2. Notify Site-specific Admin if different
        if ($site_admin_email && $site_admin_email ne $csc_admin_email) {
            $notifier->send_error_notification($c, $site_admin_email, $subject, $error_details);
        }
    };
    if ($@) {
        _print_log("CRITICAL: Failed to send error email: $@");
    }
}

# Log a message to a file (defaults to the global log file)
sub log_to_file {
    my ($message, $file_path, $level) = @_;
    
    # CRITICAL FIX: Ensure we always use a proper log file path
    # If no file_path is provided or it's undefined, use the global log file
    # This prevents creating files with the message as the filename
    if (!defined $file_path || $file_path eq '') {
        # Use the global log file if it's defined, otherwise create a default path
        $file_path = $LOG_FILE;
        
        # If global log file is not defined yet, create a default path
        if (!defined $file_path) {
            my $log_dir = $ENV{'COMSERV_LOG_DIR'} 
                ? $ENV{'COMSERV_LOG_DIR'} 
                : File::Spec->catdir($FindBin::Bin, '..', 'logs');
                
            # Create the log directory if it doesn't exist
            unless (-d $log_dir) {
                eval { make_path($log_dir) };
                if ($@) {
                    _print_log("[ERROR] Failed to create log directory $log_dir: $@");
                    return;
                }
            }
            
            $file_path = File::Spec->catfile($log_dir, 'application.log');
        }
    }
    
    $level //= 'INFO';

    # Check file size before writing to ensure we don't exceed max size
    if (defined $LOG_FILE && $file_path eq $LOG_FILE && -e $file_path) {
        my $file_size = -s $file_path;
        if ($file_size >= $ROTATION_THRESHOLD) {
            _print_log("Pre-emptive log rotation triggered: $file_size bytes >= $ROTATION_THRESHOLD bytes");
            rotate_log();
        }
    }

    # Declare $file with 'my' to fix the scoping issue
    my $file;
    
    # CRITICAL FIX: Check if the file path is a directory
    if (-d $file_path) {
        _print_log("ERROR: File path is a directory: $file_path");
        
        # Use a default log file instead
        $file_path = File::Spec->catfile($ENV{'COMSERV_LOG_DIR'} || 
            File::Spec->catdir($FindBin::Bin, '..', 'logs'), 'application.log');
    }
    
    # CRITICAL FIX: Check if the file path contains invalid characters
    if ($file_path =~ /[\n\r]/) {
        _print_log("ERROR: File path contains invalid characters: $file_path");
        
        # Use a default log file instead
        $file_path = File::Spec->catfile($ENV{'COMSERV_LOG_DIR'} || 
            File::Spec->catdir($FindBin::Bin, '..', 'logs'), 'application.log');
    }
    
    # CRITICAL FIX: Ensure the file path is a valid file path
    # If it doesn't contain a directory separator, it's probably not a valid file path
    if ($file_path !~ /[\/\\]/) {
        _print_log("ERROR: File path does not appear to be a valid path: $file_path");
        
        # Use a default log file instead
        $file_path = File::Spec->catfile($ENV{'COMSERV_LOG_DIR'} || 
            File::Spec->catdir($FindBin::Bin, '..', 'logs'), 'application.log');
    }
    
    unless (open $file, '>>', $file_path) {
        _print_log("Failed to open file: $file_path - $!");
        return;
    }

    # Use non-blocking lock to prevent deadlock in multi-worker environments
    # If lock fails, write anyway (better to lose a log than hang the request)
    my $lock_acquired = flock($file, LOCK_EX | LOCK_NB);
    
    print $file "$level: $message\n";
    
    # Only unlock if we acquired the lock
    if ($lock_acquired) {
        flock($file, LOCK_UN);
    }

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

# Force log rotation regardless of file size
# This can be called from admin interfaces
sub force_log_rotation {
    my ($class) = @_;
    return unless defined $LOG_FILE && -e $LOG_FILE;

    my $file_size = -s $LOG_FILE;
    _print_log("Manual log rotation requested. Current log file size: $file_size bytes");

    # Generate timestamped filename base
    my $timestamp = strftime("%Y%m%d_%H%M%S", localtime);
    my ($volume, $directories, $filename) = File::Spec->splitpath($LOG_FILE);
    my $archive_dir = File::Spec->catdir($directories, 'archive');
    make_path($archive_dir) unless -d $archive_dir;

    # Close current log file handle
    close $LOG_FH if $LOG_FH;

    # For very large files, we'll split them into chunks
    my $archived_log;

    if ($file_size > $MAX_LOG_SIZE * 2) {
        _print_log("Log file is very large ($file_size bytes). Splitting into chunks of $MAX_LOG_SIZE bytes.");
        $archived_log = _split_large_log($LOG_FILE, $archive_dir, $filename, $timestamp, $MAX_LOG_SIZE);
    } else {
        # For smaller files, just move the whole file
        $archived_log = File::Spec->catfile($archive_dir, "${filename}_${timestamp}");
        File::Copy::move($LOG_FILE, $archived_log) or die "Could not rotate log: $!";
    }

    # Reopen log file
    sysopen($LOG_FH, $LOG_FILE, O_WRONLY | O_APPEND | O_CREAT, 0644)
        or die "Cannot reopen log file after rotation: $!";

    # Clean up old log files if we have too many
    _cleanup_old_logs($archive_dir, $filename);

    _print_log("Log manually rotated: $archived_log");
    return $archived_log;
}

# Helper function to split a large log file into smaller chunks
sub _split_large_log {
    my ($log_file, $archive_dir, $filename, $timestamp, $chunk_size) = @_;

    # Open the original log file for reading
    open my $in_fh, '<', $log_file or die "Cannot open log file for reading: $!";

    # Create a temporary file for the new log
    my $temp_log = "${log_file}.new";
    open my $new_log_fh, '>', $temp_log or die "Cannot create new log file: $!";

    my $chunk_num = 1;
    my $bytes_read = 0;
    my $current_chunk_file;
    my $current_out_fh;
    my $first_chunk_file;

    # Read the file in chunks
    while (my $line = <$in_fh>) {
        $bytes_read += length($line);

        # If we've exceeded the chunk size or this is the first chunk, create a new chunk file
        if ($bytes_read > $chunk_size || !defined $current_out_fh) {
            # Close the previous chunk file if it exists
            if (defined $current_out_fh) {
                close $current_out_fh;
            }

            # Create a new chunk file
            $current_chunk_file = File::Spec->catfile($archive_dir, "${filename}_${timestamp}_chunk${chunk_num}");
            $first_chunk_file //= $current_chunk_file; # Save the first chunk file name

            open $current_out_fh, '>', $current_chunk_file or die "Cannot create chunk file: $!";
            _print_log("Created new chunk file: $current_chunk_file");

            $chunk_num++;
            $bytes_read = length($line);
        }

        # Write the line to the current chunk file
        print $current_out_fh $line;
    }

    # Close all file handles
    close $current_out_fh if defined $current_out_fh;
    close $in_fh;
    close $new_log_fh;

    # Replace the original log file with the empty new one
    rename $temp_log, $log_file or die "Cannot replace log file: $!";

    return $first_chunk_file;
}

# Get current log file size in KB
sub get_log_file_size {
    my ($class, $custom_path) = @_;
    my $file_path = $custom_path || $LOG_FILE;

    # If we still don't have a path or the file doesn't exist, return 0
    return 0 unless defined $file_path && -e $file_path;

    my $size_bytes = -s $file_path;
    return sprintf("%.2f", $size_bytes / 1024); # Return size in KB
}

# Refresh settings from database
sub refresh_settings {
    my ($self, $c) = @_;
    return unless $c && ref($c) && $c->can('model');
    
    eval {
        my $sitename = ($c->can('stash') && $c->stash) ? ($c->stash->{SiteName} || 'CSC') : 'CSC';
        my $site = $c->model('DBEncy')->resultset('Site')->search({ name => $sitename })->single;
        if ($site) {
            my $threshold_cfg = $c->model('DBEncy')->resultset('SiteConfig')->find({
                site_id => $site->id,
                config_key => 'logging_email_threshold'
            });
            if ($threshold_cfg) {
                $EMAIL_NOTIFY_THRESHOLD = uc($threshold_cfg->config_value);
            }
            
            my $nfs_cfg = $c->model('DBEncy')->resultset('SiteConfig')->find({
                site_id => $site->id,
                config_key => 'logging_nfs_dir'
            });
            if ($nfs_cfg && $nfs_cfg->config_value && -d $nfs_cfg->config_value && -w $nfs_cfg->config_value) {
                my $new_dir = $nfs_cfg->config_value;
                my $new_file = File::Spec->catfile($new_dir, "application.log");
                if (!defined $LOG_FILE || $LOG_FILE ne $new_file) {
                    _print_log("Updating log directory from database: $new_dir");
                    $LOG_FILE = $new_file;
                    # We might want to call init() or handle handle closure here
                    # but let's keep it simple for now to avoid handle issues
                }
            }
        }
    };
}

1; # Ensure the module returns true
