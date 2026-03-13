package Comserv::Util::HealthLogger;

# Comserv Server Health Logger
#
# Writes health events to the shared system_log table so that
# comserv_server.pl can evaluate health trends, alert CSC admins,
# and prune old entries to keep the table manageable.
#
# Messages are prefixed with [HEALTH][CATEGORY][APP_INSTANCE] so the
# evaluator can distinguish health events from other log entries and
# identify which container/server recorded them.
#
# Usage:
#   Comserv::Util::HealthLogger->log_event($c,
#       level    => 'ERROR',
#       category => 'FILE_UPLOAD',
#       message  => 'Upload of foo.txt failed',
#       file     => __FILE__,
#       line     => __LINE__,
#       sub      => 'upload_file',
#   );

use strict;
use warnings;
use POSIX qw(strftime);
use Sys::Hostname;
use Comserv::Util::Logging;

my $logging = Comserv::Util::Logging->instance;

# Event categories
use constant {
    CAT_FILE_UPLOAD   => 'FILE_UPLOAD',
    CAT_FILE_DOWNLOAD => 'FILE_DOWNLOAD',
    CAT_EMAIL         => 'EMAIL',
    CAT_DB_ERROR      => 'DB_ERROR',
    CAT_HTTP_ERROR    => 'HTTP_ERROR',
    CAT_AUTH          => 'AUTH',
    CAT_MEMORY        => 'MEMORY',
    CAT_HEALTH        => 'HEALTH',
    CAT_ERROR         => 'ERROR',
    CAT_GENERAL       => 'GENERAL',
};

# Numeric severity per log level — used for health scoring
my %LEVEL_SCORE = (
    DEBUG    => 1,
    INFO     => 2,
    WARN     => 4,
    ERROR    => 7,
    CRITICAL => 10,
);

# Category weight for scoring
my %CATEGORY_SCORE = (
    CAT_HEALTH()        => 8,
    CAT_DB_ERROR()      => 7,
    CAT_ERROR()         => 6,
    CAT_MEMORY()        => 6,
    CAT_HTTP_ERROR()    => 5,
    CAT_AUTH()          => 5,
    CAT_FILE_UPLOAD()   => 3,
    CAT_FILE_DOWNLOAD() => 3,
    CAT_EMAIL()         => 3,
    CAT_GENERAL()       => 1,
);

my $_app_instance;

sub _get_app_instance {
    return $_app_instance if defined $_app_instance;
    my $hostname = eval { hostname() } || 'unknown';
    my $port = $ENV{WEB_PORT} || $ENV{CATALYST_PORT} || '3000';
    $_app_instance = "$hostname:$port(PID:$$)";
    return $_app_instance;
}

# Build the structured message prefix embedded into system_log.message
# Format: [HEALTH][CATEGORY][app_instance] original message
sub _build_message {
    my ($category, $message) = @_;
    my $instance = _get_app_instance();
    return "[HEALTH][$category][$instance] $message";
}

sub log_event {
    my ($class, $c, %args) = @_;

    my $level    = uc($args{level}    || 'INFO');
    my $category = uc($args{category} || CAT_GENERAL);
    my $message  = $args{message} || 'No message';
    my $src_file = $args{file}    || '';
    my $src_line = int($args{line} || 0);
    my $sub_name = $args{sub}     || '';

    my $full_message = _build_message($category, $message);

    my $sitename = '';
    my $username = '';
    if ($c && ref $c) {
        eval {
            $sitename = $c->session->{SiteName} // '';
            $username = $c->session->{username} // '';
        };
    }

    my $now = strftime('%Y-%m-%d %H:%M:%S', localtime);

    eval {
        my $schema = $c->model('DBEncy');
        $schema->resultset('SystemLog')->create({
            timestamp  => $now,
            level      => $level,
            file       => $src_file,
            line       => $src_line,
            subroutine => $sub_name,
            message    => $full_message,
            sitename   => $sitename || undef,
            username   => $username || undef,
        });
    };
    if ($@) {
        $logging->log_with_details(
            $c, 'error', __FILE__, __LINE__, 'HealthLogger::log_event',
            "Failed to write system_log record: $@"
        );
    }

    return;
}

sub log_file_upload {
    my ($class, $c, %args) = @_;
    $class->log_event($c,
        level    => $args{success} ? 'INFO' : 'ERROR',
        category => CAT_FILE_UPLOAD,
        message  => $args{message} || ($args{success}
            ? "Upload success: " . ($args{filename} || 'unknown')
            : "Upload failed: "  . ($args{filename} || 'unknown')),
        file     => $args{file} || '',
        line     => $args{line} || 0,
        sub      => $args{sub}  || 'upload_file',
    );
}

sub log_file_download {
    my ($class, $c, %args) = @_;
    $class->log_event($c,
        level    => $args{success} ? 'INFO' : 'ERROR',
        category => CAT_FILE_DOWNLOAD,
        message  => $args{message} || ($args{success}
            ? "Download success: " . ($args{filename} || 'unknown')
            : "Download failed: "  . ($args{filename} || 'unknown')),
        file     => $args{file} || '',
        line     => $args{line} || 0,
        sub      => $args{sub}  || 'download',
    );
}

sub log_email {
    my ($class, $c, %args) = @_;
    $class->log_event($c,
        level    => $args{success} ? 'INFO' : 'ERROR',
        category => CAT_EMAIL,
        message  => $args{message} || ($args{success}
            ? "Email sent to: "        . ($args{to} || 'unknown')
            : "Email send failed to: " . ($args{to} || 'unknown')),
        file     => $args{file} || '',
        line     => $args{line} || 0,
        sub      => $args{sub}  || 'send_email',
    );
}

sub log_error {
    my ($class, $c, %args) = @_;
    $class->log_event($c,
        level    => $args{level}    || 'ERROR',
        category => $args{category} || CAT_ERROR,
        message  => $args{message}  || 'Application error',
        file     => $args{file}     || '',
        line     => $args{line}     || 0,
        sub      => $args{sub}      || '',
    );
}

sub log_health {
    my ($class, $c, %args) = @_;
    $class->log_event($c,
        level    => $args{level}   || 'INFO',
        category => CAT_HEALTH,
        message  => $args{message} || 'Health check',
        file     => __FILE__,
        line     => __LINE__,
        sub      => 'log_health',
    );
}

# -------------------------------------------------------------------------
# Methods called by comserv_server.pl's health evaluation daemon.
# These operate on a raw DBIx::Class schema (no Catalyst context).
# -------------------------------------------------------------------------

# Evaluate recent [HEALTH] records and return a summary sorted by severity.
# $schema     - Comserv::Model::Schema::Ency connected instance
# $since_min  - look back this many minutes
sub evaluate_records {
    my ($class, $schema, $since_min) = @_;
    $since_min //= 60;

    my @results;
    eval {
        my $cutoff = strftime('%Y-%m-%d %H:%M:%S',
            localtime(time() - $since_min * 60));

        my $rs = $schema->resultset('SystemLog')->search({
            message    => { -like => '[HEALTH]%' },
            timestamp  => { '>='  => $cutoff },
        }, {
            order_by => { -desc => 'id' },
        });

        my %buckets;
        while (my $rec = $rs->next) {
            # Parse [HEALTH][CATEGORY][instance] prefix
            my ($cat, $inst) = ('GENERAL', 'unknown');
            if ($rec->message =~ /^\[HEALTH\]\[([^\]]+)\]\[([^\]]+)\]/) {
                $cat  = $1;
                $inst = $2;
            }
            my $lvl   = uc($rec->level || 'INFO');
            my $key   = "$lvl|$cat";
            my $score = ($LEVEL_SCORE{$lvl} || 2) * ($CATEGORY_SCORE{$cat} || 1);

            $buckets{$key} //= { count => 0, score => 0, rec => $rec, cat => $cat, lvl => $lvl, inst => $inst };
            $buckets{$key}{count}++;
            $buckets{$key}{score} += $score;
        }

        @results = sort { $b->{score} <=> $a->{score} } values %buckets;
    };
    if ($@) {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__,
            'evaluate_records', "evaluate_records failed: $@");
    }
    return \@results;
}

# Prune old system_log records to keep the table from growing unbounded.
# Deletes [HEALTH] records older than $prune_days, and caps total [HEALTH]
# rows at $max_records by deleting the oldest first.
sub prune_old_records {
    my ($class, $schema, %opts) = @_;
    my $prune_days  = $opts{prune_days}  // 7;
    my $max_records = $opts{max_records} // 10000;

    my $deleted = 0;
    eval {
        my $cutoff = strftime('%Y-%m-%d %H:%M:%S',
            localtime(time() - $prune_days * 86400));

        $deleted += $schema->resultset('SystemLog')->search({
            message   => { -like => '[HEALTH]%' },
            timestamp => { '<'   => $cutoff },
        })->delete;

        my $total = $schema->resultset('SystemLog')->search({
            message => { -like => '[HEALTH]%' },
        })->count;

        if ($total > $max_records) {
            my $to_delete = $total - $max_records;
            my @oldest = $schema->resultset('SystemLog')->search(
                { message => { -like => '[HEALTH]%' } },
                { order_by => 'id', rows => $to_delete }
            )->all;
            for my $rec (@oldest) {
                eval { $rec->delete };
                $deleted++;
            }
        }
    };
    if ($@) {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__,
            'prune_old_records', "prune_old_records failed: $@");
    }
    return $deleted;
}

# Compute a 0-100 health score from recent [HEALTH] log events.
# Returns { score => N, status => 'OK'|'WARN'|'CRITICAL', summary => [...] }
sub compute_health_score {
    my ($class, $schema, $minutes) = @_;
    $minutes //= 30;

    my $score  = 100;
    my @issues;

    eval {
        my $cutoff = strftime('%Y-%m-%d %H:%M:%S',
            localtime(time() - $minutes * 60));

        my $base = {
            message   => { -like => '[HEALTH]%' },
            timestamp => { '>='  => $cutoff },
        };

        my $error_count = $schema->resultset('SystemLog')->search({
            %$base,
            level => { -in => ['ERROR', 'CRITICAL'] },
        })->count;

        my $warn_count = $schema->resultset('SystemLog')->search({
            %$base,
            level => 'WARN',
        })->count;

        my $total = $schema->resultset('SystemLog')->search($base)->count;

        $score -= $error_count * 5;
        $score -= $warn_count  * 1;
        $score  = 0   if $score < 0;
        $score  = 100 if $score > 100;

        push @issues, "Errors (last ${minutes}m): $error_count"   if $error_count;
        push @issues, "Warnings (last ${minutes}m): $warn_count"  if $warn_count;
        push @issues, "Total health events (last ${minutes}m): $total";

        for my $cat (CAT_DB_ERROR, CAT_HTTP_ERROR, CAT_FILE_UPLOAD, CAT_EMAIL, CAT_MEMORY) {
            my $n = $schema->resultset('SystemLog')->search({
                %$base,
                level   => { -in => ['ERROR', 'CRITICAL'] },
                message => { -like => "[HEALTH][$cat]%" },
            })->count;
            push @issues, "$cat errors: $n" if $n;
        }
    };
    if ($@) {
        return { score => 0, status => 'UNKNOWN', summary => ["Health check failed: $@"] };
    }

    my $status = $score >= 80 ? 'OK' : ($score >= 50 ? 'WARN' : 'CRITICAL');
    return { score => $score, status => $status, summary => \@issues };
}

1;
