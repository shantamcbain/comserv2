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

my $INITIALIZED = 0;

sub init {
    my ($class) = @_;

    return if $INITIALIZED;

    my $base_dir = $ENV{'COMSERV_LOG_DIR'} // File::Spec->catdir($FindBin::Bin, '..');
    my $log_dir  = File::Spec->catdir($base_dir, "logs");
    $LOG_FILE = File::Spec->catfile($log_dir, "application.log");

    unless (-d $log_dir) {
        make_path($log_dir) or die "Failed to create log directory $log_dir: $@\n";
    }

    sysopen($LOG_FH, $LOG_FILE, O_WRONLY | O_APPEND | O_CREAT, 0644)
        or die "Can't open log file $LOG_FILE: $!";

    select((select($LOG_FH), $| = 1)[0]);

    $INITIALIZED = 1;
}

sub log_with_details {
    my ($self, $c, $level, $file, $line, $subroutine, $message) = @_;

    unless (defined $LOG_FILE) {
        warn "Logging system not initialized. Initializing now.";
        __PACKAGE__->init();
    }

    $message //= 'No message provided';
    $level   //= 'INFO';

    my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
    my $log_message = sprintf("[%s] [%s:%d] %s - %s", $timestamp, $file, $line, ($subroutine // 'unknown'), $message);

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