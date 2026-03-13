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

    my $sys_id = _get_app_instance();
    eval {
        my $schema = $c->model('DBEncy');
        $schema->resultset('SystemLog')->create({
            timestamp         => $now,
            level             => $level,
            file              => $src_file,
            line              => $src_line,
            subroutine        => $sub_name,
            message           => $full_message,
            sitename          => $sitename || undef,
            username          => $username || undef,
            system_identifier => $sys_id,
        });
    };
    if ($@) {
        # Retry without system_identifier in case column not yet in DB
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
            columns  => [qw(id timestamp level file line subroutine message sitename username)],
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

# Prune system_log records using per-level retention policies.
# Default retention: DEBUG=1d, INFO=2d, WARN=7d, ERROR=30d, CRITICAL=90d
# Also caps total rows at $max_records by removing oldest first.
# Operates on ALL system_log rows (not just [HEALTH] prefixed).
sub prune_old_records {
    my ($class, $schema, %opts) = @_;
    my $max_records = $opts{max_records} // 10000;

    my %retention_days = (
        DEBUG    => $opts{debug_days}    // 1,
        INFO     => $opts{info_days}     // 2,
        WARN     => $opts{warn_days}     // 7,
        ERROR    => $opts{error_days}    // 30,
        CRITICAL => $opts{critical_days} // 90,
    );

    my $deleted = 0;
    eval {
        for my $level (keys %retention_days) {
            my $cutoff = strftime('%Y-%m-%d %H:%M:%S',
                localtime(time() - $retention_days{$level} * 86400));
            $deleted += $schema->resultset('SystemLog')->search({
                level     => $level,
                timestamp => { '<' => $cutoff },
            })->delete;
        }

        my $total = $schema->resultset('SystemLog')->count;
        if ($total > $max_records) {
            my $to_delete = $total - $max_records;
            $deleted += $schema->resultset('SystemLog')->search(
                {},
                { order_by => 'id', rows => $to_delete }
            )->delete;
        }
    };
    if ($@) {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__,
            'prune_old_records', "prune_old_records failed: $@");
    }
    return $deleted;
}

# Upsert a health_alert record for a detected issue.
# If an OPEN alert with the same category+level+system_identifier exists,
# increments occurrence_count and updates last_seen.
# Otherwise inserts a new OPEN alert.
# Returns silently if the health_alert table doesn't exist yet.
sub upsert_health_alert {
    my ($class, $schema, %args) = @_;
    my $level       = uc($args{level}       || 'MEDIUM');
    my $category    = uc($args{category}    || 'GENERAL');
    my $description = $args{description}    || 'No description';
    my $sys_id      = $args{system_identifier} || _get_app_instance();
    my $sitename    = $args{sitename}       || undef;
    my $now         = strftime('%Y-%m-%d %H:%M:%S', localtime);

    eval {
        my $existing = $schema->resultset('HealthAlert')->search({
            level             => $level,
            category          => $category,
            system_identifier => $sys_id,
            status            => { -in => ['OPEN', 'ACKNOWLEDGED'] },
        }, { rows => 1, order_by => { -desc => 'id' } })->single;

        if ($existing) {
            $existing->update({
                last_seen        => $now,
                occurrence_count => ($existing->occurrence_count || 1) + 1,
                description      => $description,
            });
        } else {
            $schema->resultset('HealthAlert')->create({
                first_seen        => $now,
                last_seen         => $now,
                level             => $level,
                category          => $category,
                description       => $description,
                occurrence_count  => 1,
                status            => 'OPEN',
                system_identifier => $sys_id,
                sitename          => $sitename,
            });
        }
    };
    # silently ignore if table not yet created
    return;
}

# Return audit statistics about what is currently being recorded in system_log.
# Groups by level, subroutine, and file to show what's generating the most noise.
sub audit_stats {
    my ($class, $schema, %opts) = @_;
    my $hours = $opts{hours} // 24;
    my $limit = $opts{limit} // 20;

    my $cutoff = strftime('%Y-%m-%d %H:%M:%S',
        localtime(time() - $hours * 3600));

    my %stats;
    eval {
        # Total count
        $stats{total}    = $schema->resultset('SystemLog')->count;
        $stats{recent}   = $schema->resultset('SystemLog')->search({ timestamp => { '>=' => $cutoff } })->count;
        $stats{hours}    = $hours;

        # Counts by level
        my @level_rows;
        for my $lvl (qw(DEBUG INFO WARN ERROR CRITICAL)) {
            my $n = $schema->resultset('SystemLog')->search({ level => $lvl })->count;
            my $n_recent = $schema->resultset('SystemLog')->search({ level => $lvl, timestamp => { '>=' => $cutoff } })->count;
            push @level_rows, { level => $lvl, total => $n, recent => $n_recent };
        }
        $stats{by_level} = \@level_rows;

        # Top subroutines generating records (last $hours hours)
        my @sub_rows;
        {
            my $rs = $schema->resultset('SystemLog')->search(
                { timestamp => { '>=' => $cutoff } },
                {
                    select   => [ 'subroutine', 'level', { count => 'id', -as => 'cnt' } ],
                    as       => [ 'subroutine', 'level', 'cnt' ],
                    group_by => [ 'subroutine', 'level' ],
                    order_by => { -desc => 'cnt' },
                    rows     => $limit,
                }
            );
            while (my $r = $rs->next) {
                push @sub_rows, {
                    subroutine => $r->get_column('subroutine'),
                    level      => $r->get_column('level'),
                    count      => $r->get_column('cnt'),
                };
            }
        }
        $stats{top_subroutines} = \@sub_rows;

        # Top source files generating records (last $hours hours)
        my @file_rows;
        {
            my $rs = $schema->resultset('SystemLog')->search(
                { timestamp => { '>=' => $cutoff } },
                {
                    select   => [ 'file', { count => 'id', -as => 'cnt' } ],
                    as       => [ 'file', 'cnt' ],
                    group_by => ['file'],
                    order_by => { -desc => 'cnt' },
                    rows     => $limit,
                }
            );
            while (my $r = $rs->next) {
                push @file_rows, {
                    file  => $r->get_column('file'),
                    count => $r->get_column('cnt'),
                };
            }
        }
        $stats{top_files} = \@file_rows;

        # Top system_identifiers (which server/container is logging the most)
        my @inst_rows;
        eval {
            my $rs = $schema->resultset('SystemLog')->search(
                { timestamp => { '>=' => $cutoff } },
                {
                    select   => [ 'system_identifier', { count => 'id', -as => 'cnt' } ],
                    as       => [ 'system_identifier', 'cnt' ],
                    group_by => ['system_identifier'],
                    order_by => { -desc => 'cnt' },
                    rows     => 10,
                }
            );
            while (my $r = $rs->next) {
                push @inst_rows, {
                    instance => $r->get_column('system_identifier') // '(unknown)',
                    count    => $r->get_column('cnt'),
                };
            }
        };
        $stats{top_instances} = \@inst_rows;

        # Pruning estimates: how many rows would be removed per level
        my %prune_est;
        my %retention = (DEBUG => 1, INFO => 2, WARN => 7, ERROR => 30, CRITICAL => 90);
        for my $lvl (keys %retention) {
            my $cutoff_lvl = strftime('%Y-%m-%d %H:%M:%S',
                localtime(time() - $retention{$lvl} * 86400));
            $prune_est{$lvl} = $schema->resultset('SystemLog')->search({
                level     => $lvl,
                timestamp => { '<' => $cutoff_lvl },
            })->count;
        }
        $stats{prune_estimates} = \%prune_est;
        $stats{prune_total} = 0;
        $stats{prune_total} += $_ for values %prune_est;
    };
    if ($@) {
        $stats{error} = "$@";
    }
    return \%stats;
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
