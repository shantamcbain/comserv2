package Comserv::Util::HealthLogger;

# Comserv Server Health Logger
#
# Records health events to the application_log table so that
# comserv_server.pl can evaluate health trends, alert CSC admins,
# and prune repetitive entries.
#
# Usage:
#   Comserv::Util::HealthLogger->log_event($c,
#       level    => 'ERROR',
#       category => 'FILE_UPLOAD',
#       event    => 'upload_failed',
#       message  => 'Upload of foo.txt failed',
#       details  => $detailed_error_string,
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

# Log levels with numeric severity (higher = more severe)
my %LEVEL_SCORE = (
    DEBUG    => 1,
    INFO     => 2,
    WARN     => 4,
    ERROR    => 7,
    CRITICAL => 10,
);

# Category base scores for prioritization
my %CATEGORY_SCORE = (
    CAT_HEALTH()        => 8,
    CAT_DB_ERROR()      => 7,
    CAT_HTTP_ERROR()    => 5,
    CAT_ERROR()         => 6,
    CAT_AUTH()          => 5,
    CAT_FILE_UPLOAD()   => 3,
    CAT_FILE_DOWNLOAD() => 3,
    CAT_EMAIL()         => 3,
    CAT_MEMORY()        => 6,
    CAT_GENERAL()       => 1,
);

my $_app_instance;

sub _get_app_instance {
    return $_app_instance if defined $_app_instance;
    my $hostname = eval { hostname() } || 'unknown';
    my $pid = $$;
    my $port = $ENV{WEB_PORT} || $ENV{CATALYST_PORT} || '3000';
    $_app_instance = "$hostname:$port (PID:$pid)";
    return $_app_instance;
}

sub log_event {
    my ($class, $c, %args) = @_;

    my $level    = uc($args{level}    || 'INFO');
    my $category = uc($args{category} || CAT_GENERAL);
    my $event    = $args{event}   || '';
    my $message  = $args{message} || 'No message';
    my $details  = $args{details} || undef;
    my $src_file = $args{file}    || '';
    my $src_line = $args{line}    || undef;
    my $sub_name = $args{sub}     || '';

    my $app_instance = _get_app_instance();
    my $hostname     = eval { hostname() } || 'unknown';

    my $score = ($LEVEL_SCORE{$level} || 2) * ($CATEGORY_SCORE{$category} || 1);

    eval {
        my $schema = $c->model('DBEncy');
        $schema->resultset('ApplicationLog')->create({
            app_instance     => $app_instance,
            log_level        => $level,
            category         => $category,
            event_type       => $event,
            message          => $message,
            details          => $details,
            source_file      => $src_file,
            source_line      => $src_line,
            subroutine       => $sub_name,
            hostname         => $hostname,
            pid              => $$,
            evaluated        => 0,
            evaluation_score => $score,
            pruned           => 0,
            occurrence_count => 1,
        });
    };
    if ($@) {
        $logging->log_with_details(
            $c, 'error', __FILE__, __LINE__, 'log_event',
            "HealthLogger: Failed to write application_log record: $@"
        );
    }

    return;
}

sub log_file_upload {
    my ($class, $c, %args) = @_;
    $class->log_event($c,
        level    => $args{success} ? 'INFO' : 'ERROR',
        category => CAT_FILE_UPLOAD,
        event    => $args{success} ? 'upload_success' : 'upload_failed',
        message  => $args{message} || ($args{success}
            ? "File uploaded: " . ($args{filename} || 'unknown')
            : "File upload failed: " . ($args{filename} || 'unknown')),
        details  => $args{details},
        file     => $args{file} || '',
        line     => $args{line},
        sub      => $args{sub} || 'upload',
    );
}

sub log_file_download {
    my ($class, $c, %args) = @_;
    $class->log_event($c,
        level    => $args{success} ? 'INFO' : 'ERROR',
        category => CAT_FILE_DOWNLOAD,
        event    => $args{success} ? 'download_success' : 'download_failed',
        message  => $args{message} || ($args{success}
            ? "File downloaded: " . ($args{filename} || 'unknown')
            : "File download failed: " . ($args{filename} || 'unknown')),
        details  => $args{details},
        file     => $args{file} || '',
        line     => $args{line},
        sub      => $args{sub} || 'download',
    );
}

sub log_email {
    my ($class, $c, %args) = @_;
    $class->log_event($c,
        level    => $args{success} ? 'INFO' : 'ERROR',
        category => CAT_EMAIL,
        event    => $args{success} ? 'email_sent' : 'email_failed',
        message  => $args{message} || ($args{success}
            ? "Email sent to: " . ($args{to} || 'unknown')
            : "Email send failed to: " . ($args{to} || 'unknown')),
        details  => $args{details},
        file     => $args{file} || '',
        line     => $args{line},
        sub      => $args{sub} || 'send_email',
    );
}

sub log_error {
    my ($class, $c, %args) = @_;
    $class->log_event($c,
        level    => $args{level} || 'ERROR',
        category => $args{category} || CAT_ERROR,
        event    => $args{event} || 'application_error',
        message  => $args{message} || 'Application error',
        details  => $args{details},
        file     => $args{file} || '',
        line     => $args{line},
        sub      => $args{sub} || '',
    );
}

sub log_health {
    my ($class, $c, %args) = @_;
    $class->log_event($c,
        level    => $args{level} || 'INFO',
        category => CAT_HEALTH,
        event    => $args{event} || 'health_check',
        message  => $args{message} || 'Health check',
        details  => $args{details},
        file     => __FILE__,
        line     => __LINE__,
        sub      => 'log_health',
    );
}

# Evaluate unevaluated records and return summary
# Called by comserv_server.pl's health evaluation loop
sub evaluate_records {
    my ($class, $schema, $since_minutes) = @_;
    $since_minutes //= 60;

    my @results;

    eval {
        my $cutoff = strftime('%Y-%m-%d %H:%M:%S',
            localtime(time() - $since_minutes * 60));

        my $rs = $schema->resultset('ApplicationLog')->search({
            evaluated => 0,
            pruned    => 0,
            created_at => { '>=' => $cutoff },
        }, {
            order_by => { -desc => 'evaluation_score' },
        });

        my %event_counts;
        my @all_records;

        while (my $rec = $rs->next) {
            push @all_records, $rec;
            my $key = join('|', $rec->category, $rec->event_type || '', $rec->log_level);
            $event_counts{$key} //= { count => 0, score => 0, first_rec => $rec };
            $event_counts{$key}{count}++;
            $event_counts{$key}{score} += $rec->evaluation_score || 0;
        }

        for my $key (sort { $event_counts{$b}{score} <=> $event_counts{$a}{score} }
                     keys %event_counts) {
            push @results, {
                key   => $key,
                count => $event_counts{$key}{count},
                score => $event_counts{$key}{score},
                rec   => $event_counts{$key}{first_rec},
            };
        }

        # Mark all as evaluated
        for my $rec (@all_records) {
            eval { $rec->update({ evaluated => 1 }) };
        }
    };
    if ($@) {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'evaluate_records',
            "HealthLogger::evaluate_records failed: $@");
    }

    return \@results;
}

# Prune old evaluated records to keep table size manageable
# Keeps the most recent $keep_days days of unevaluated records,
# and removes evaluated+pruned records older than $prune_days.
sub prune_old_records {
    my ($class, $schema, %opts) = @_;
    my $prune_days  = $opts{prune_days}  // 7;
    my $max_records = $opts{max_records} // 10000;

    my $deleted = 0;
    eval {
        my $cutoff = strftime('%Y-%m-%d %H:%M:%S',
            localtime(time() - $prune_days * 86400));

        $deleted = $schema->resultset('ApplicationLog')->search({
            evaluated  => 1,
            created_at => { '<' => $cutoff },
        })->delete;

        my $total = $schema->resultset('ApplicationLog')->count;
        if ($total > $max_records) {
            my $to_delete = $total - $max_records;
            my @oldest = $schema->resultset('ApplicationLog')->search(
                { evaluated => 1 },
                { order_by => 'created_at', rows => $to_delete }
            )->all;
            for my $rec (@oldest) {
                eval { $rec->delete };
                $deleted++;
            }
        }
    };
    if ($@) {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'prune_old_records',
            "HealthLogger::prune_old_records failed: $@");
    }
    return $deleted;
}

# Compute an overall health score from recent log events
# Returns hashref: { score => 0-100, status => 'OK'|'WARN'|'CRITICAL', summary => [...] }
sub compute_health_score {
    my ($class, $schema, $minutes) = @_;
    $minutes //= 30;

    my $score  = 100;
    my @issues;

    eval {
        my $cutoff = strftime('%Y-%m-%d %H:%M:%S',
            localtime(time() - $minutes * 60));

        my $error_count = $schema->resultset('ApplicationLog')->search({
            log_level  => { -in => ['ERROR', 'CRITICAL'] },
            created_at => { '>=' => $cutoff },
            pruned     => 0,
        })->count;

        my $warn_count = $schema->resultset('ApplicationLog')->search({
            log_level  => 'WARN',
            created_at => { '>=' => $cutoff },
            pruned     => 0,
        })->count;

        my $total = $schema->resultset('ApplicationLog')->search({
            created_at => { '>=' => $cutoff },
            pruned     => 0,
        })->count;

        $score -= $error_count * 5;
        $score -= $warn_count * 1;
        $score = 0 if $score < 0;
        $score = 100 if $score > 100;

        push @issues, "Errors last ${minutes}m: $error_count"   if $error_count;
        push @issues, "Warnings last ${minutes}m: $warn_count"  if $warn_count;
        push @issues, "Total events last ${minutes}m: $total";

        # Category breakdown
        for my $cat (CAT_DB_ERROR, CAT_HTTP_ERROR, CAT_FILE_UPLOAD, CAT_EMAIL, CAT_MEMORY) {
            my $cat_errors = $schema->resultset('ApplicationLog')->search({
                category   => $cat,
                log_level  => { -in => ['ERROR', 'CRITICAL'] },
                created_at => { '>=' => $cutoff },
                pruned     => 0,
            })->count;
            push @issues, "$cat errors: $cat_errors" if $cat_errors;
        }
    };
    if ($@) {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'compute_health_score',
            "HealthLogger::compute_health_score failed: $@");
        return { score => 0, status => 'UNKNOWN', summary => ["Health check failed: $@"] };
    }

    my $status = $score >= 80 ? 'OK' : ($score >= 50 ? 'WARN' : 'CRITICAL');
    return { score => $score, status => $status, summary => \@issues };
}

1;
