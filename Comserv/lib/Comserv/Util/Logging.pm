package Comserv::Util::Logging;

use strict;
use warnings;
use namespace::autoclean;
use File::Spec;
use FindBin;
use File::Path qw(make_path);
use Fcntl qw(:flock O_WRONLY O_APPEND O_CREAT);
use POSIX qw(strftime);

my $LOG_FH;
my $LOG_FILE;
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

    unless (defined $LOG_FILE) {
        warn "Logging system not initialized. Initializing now.";
        __PACKAGE__->init();
    }

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
    log_to_file($log_message, undef, $level);

    if ($c && ref($c) && ref($c->stash) eq 'HASH') {
        my $debug_errors = $c->stash->{debug_errors} ||= [];
        push @$debug_errors, $log_message;
    }

    return $log_message;
}

sub log_error {
    my ($self, $c, $file, $line, $error_message) = @_;

    unless (defined $LOG_FILE) {
        warn "Logging system not initialized. Initializing now.";
        __PACKAGE__->init();
    }

    $error_message //= 'No error message provided';

    my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
    my $log_message = sprintf("[%s] [ERROR] - %s:%d - %s", $timestamp, $file, $line, $error_message);

    log_to_file($log_message, undef, 'ERROR');

    if ($c && ref($c) && ref($c->stash) eq 'HASH') {
        my $debug_errors = $c->stash->{debug_errors} ||= [];
        push @$debug_errors, $log_message;
    }

    return $log_message;
}

sub log_to_file {
    my ($message, $file_path, $level) = @_;

    # Initialize logging if not already done
    unless (defined $LOG_FILE) {
        warn "Logging system not initialized. Initializing now.";
        __PACKAGE__->init();
    }

    $file_path //= $LOG_FILE;
    $level    //= 'INFO';

    my $file;
    unless (open $file, '>>', $file_path) {
        warn "Failed to open file: $file_path\n";
        return;
    }


    flock($file, LOCK_EX);
    print $file "$level: $message\n";
    flock($file, LOCK_UN);

    close $file;
}

1;