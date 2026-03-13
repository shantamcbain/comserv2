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
    my $name = Comserv::Util::Logging->get_system_identifier();
    my $port = $ENV{WEB_PORT} || $ENV{CATALYST_PORT} || '3000';
    $_app_instance = "$name:$port";
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
    my @detail_msgs;

    eval {
        my $dbh = $schema->storage->dbh;
        $dbh->do('SET SESSION innodb_lock_wait_timeout = 10');

        # --- Phase 1: retention-based pruning ---
        # Scan oldest 2000 rows by PK (fast — uses PK index, no full-table scan).
        # For each row, if its level's retention period has expired, mark for deletion.
        # This avoids slow full-table scans caused by non-indexed (level, timestamp) lookups.
        my $now = time();
        my %cutoffs;
        for my $lvl (keys %retention_days) {
            $cutoffs{lc $lvl} = strftime('%Y-%m-%d %H:%M:%S',
                localtime($now - $retention_days{$lvl} * 86400));
        }

        eval {
            my $sel = $dbh->prepare(
                "SELECT id, level, timestamp FROM system_log ORDER BY id ASC LIMIT 2000"
            );
            $sel->execute;
            my @to_delete;
            while (my ($id, $level, $ts) = $sel->fetchrow_array) {
                my $cutoff = $cutoffs{lc($level // '')} // $cutoffs{debug};
                push @to_delete, $id if defined $cutoff && ($ts // '') lt $cutoff;
                last if @to_delete >= 500;
            }
            if (@to_delete) {
                my $ph = join(',', ('?') x scalar @to_delete);
                my $n  = $dbh->do("DELETE FROM system_log WHERE id IN ($ph)",
                                   undef, @to_delete) // 0;
                $n = 0 unless $n =~ /^\d+$/;
                $deleted += $n;
                push @detail_msgs, "retention_prune: found=" . scalar(@to_delete) . " deleted=$n";
            } else {
                push @detail_msgs, "retention_prune: no eligible rows in oldest 2000";
            }
        };
        if ($@) {
            my $e = $@;
            $logging->log_with_details(undef, 'warn', __FILE__, __LINE__,
                'prune_old_records', "retention prune failed: $e");
            push @detail_msgs, "retention_prune error: $e";
        }

        # --- Phase 2: max-records cap ---
        # Use information_schema estimate (fast) to decide whether culling is needed.
        # Exact COUNT(*) on a 3M-row InnoDB table under active writes can take 10-20s.
        eval {
            my ($total) = $dbh->selectrow_array(
                "SELECT TABLE_ROWS FROM information_schema.TABLES
                 WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'system_log'"
            );
            push @detail_msgs, "total_count=$total max_records=$max_records";
            if (($total // 0) > $max_records) {
                my $to_delete = $total - $max_records;
                $to_delete = 500 if $to_delete > 500;
                my $sel = $dbh->prepare(
                    "SELECT id FROM system_log ORDER BY id ASC LIMIT ?"
                );
                $sel->execute($to_delete);
                my @ids = map { $_->[0] } @{ $sel->fetchall_arrayref // [] };
                if (@ids) {
                    my $ph = join(',', ('?') x scalar @ids);
                    my $n  = $dbh->do("DELETE FROM system_log WHERE id IN ($ph)",
                                       undef, @ids) // 0;
                    $n = 0 unless $n =~ /^\d+$/;
                    $deleted += $n;
                    push @detail_msgs, "cap_prune: cap=$to_delete deleted=$n";
                }
            }
        };
        if ($@) {
            my $e = $@;
            $logging->log_with_details(undef, 'warn', __FILE__, __LINE__,
                'prune_old_records', "cap prune failed: $e");
            push @detail_msgs, "cap_prune error: $e";
        }
    };
    if ($@) {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__,
            'prune_old_records', "prune_old_records outer failed: $@");
    }

    $logging->log_with_details(undef, 'info', __FILE__, __LINE__,
        'prune_old_records',
        "prune complete: deleted=$deleted | " . join(' | ', @detail_msgs));

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
    $stats{hours} = $hours;

    eval {
        my $dbh = $schema->storage->dbh;

        # --- 1. Total (fast estimate) + recent count ---
        my ($total) = $dbh->selectrow_array(
            "SELECT TABLE_ROWS FROM information_schema.TABLES
             WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'system_log'"
        );
        $stats{total} = $total // 0;

        # --- 2. Counts by level (total + recent) in one query; derive recent total from results ---
        my %retention = (DEBUG => 1, INFO => 2, WARN => 7, ERROR => 30, CRITICAL => 90);
        my $now = time();
        my %prune_est;

        my $level_sth = $dbh->prepare(
            "SELECT level, COUNT(*) as total, SUM(timestamp >= ?) as recent FROM system_log GROUP BY level"
        );
        $level_sth->execute($cutoff);
        my %level_map;
        my $recent_total = 0;
        while (my $row = $level_sth->fetchrow_hashref) {
            my $rec = $row->{recent} // 0;
            $recent_total += $rec;
            $level_map{ uc($row->{level}) } = {
                level  => uc($row->{level}),
                total  => $row->{total}  // 0,
                recent => $rec,
            };
        }
        $stats{recent} = $recent_total;
        my @level_rows;
        for my $lvl (qw(DEBUG INFO WARN ERROR CRITICAL)) {
            push @level_rows, $level_map{$lvl} // { level => $lvl, total => 0, recent => 0 };
        }
        $stats{by_level} = \@level_rows;

        # --- 3. Pruning estimates: one combined scan instead of 5 separate COUNT queries ---
        my %cutoffs_for_est;
        for my $lvl (keys %retention) {
            $cutoffs_for_est{$lvl} = strftime('%Y-%m-%d %H:%M:%S',
                localtime($now - $retention{$lvl} * 86400));
        }
        my $prune_sql = "SELECT level,
            SUM(CASE
                WHEN UPPER(level)='DEBUG'    AND timestamp < ? THEN 1
                WHEN UPPER(level)='INFO'     AND timestamp < ? THEN 1
                WHEN UPPER(level)='WARN'     AND timestamp < ? THEN 1
                WHEN UPPER(level)='ERROR'    AND timestamp < ? THEN 1
                WHEN UPPER(level)='CRITICAL' AND timestamp < ? THEN 1
                ELSE 0 END) AS prune_cnt
            FROM system_log GROUP BY level";
        my $prune_sth = $dbh->prepare($prune_sql);
        $prune_sth->execute(
            $cutoffs_for_est{DEBUG},
            $cutoffs_for_est{INFO},
            $cutoffs_for_est{WARN},
            $cutoffs_for_est{ERROR},
            $cutoffs_for_est{CRITICAL},
        );
        while (my $row = $prune_sth->fetchrow_hashref) {
            $prune_est{ uc($row->{level}) } = $row->{prune_cnt} // 0;
        }
        $stats{prune_estimates} = \%prune_est;
        $stats{prune_total}     = 0;
        $stats{prune_total}    += $_ for values %prune_est;

        # --- 4. Top subroutines (last $hours hours) ---
        my $sub_sth = $dbh->prepare(
            "SELECT subroutine, level, COUNT(*) as cnt FROM system_log
             WHERE timestamp >= ? GROUP BY subroutine, level ORDER BY cnt DESC LIMIT ?"
        );
        $sub_sth->execute($cutoff, $limit);
        my @sub_rows;
        while (my $row = $sub_sth->fetchrow_hashref) {
            push @sub_rows, {
                subroutine => $row->{subroutine},
                level      => $row->{level},
                count      => $row->{cnt},
            };
        }
        $stats{top_subroutines} = \@sub_rows;

        # --- 5. Top source files (last $hours hours) ---
        my $file_sth = $dbh->prepare(
            "SELECT file, COUNT(*) as cnt FROM system_log
             WHERE timestamp >= ? GROUP BY file ORDER BY cnt DESC LIMIT ?"
        );
        $file_sth->execute($cutoff, $limit);
        my @file_rows;
        while (my $row = $file_sth->fetchrow_hashref) {
            push @file_rows, { file => $row->{file}, count => $row->{cnt} };
        }
        $stats{top_files} = \@file_rows;

        # --- 6. Top system_identifiers ---
        my @inst_rows;
        eval {
            my $inst_sth = $dbh->prepare(
                "SELECT COALESCE(system_identifier, '(unknown)') as inst,
                        COUNT(*) as cnt FROM system_log
                 WHERE timestamp >= ? GROUP BY system_identifier ORDER BY cnt DESC LIMIT 10"
            );
            $inst_sth->execute($cutoff);
            while (my $row = $inst_sth->fetchrow_hashref) {
                push @inst_rows, { instance => $row->{inst}, count => $row->{cnt} };
            }
        };
        $stats{top_instances} = \@inst_rows;

        # --- 7. Top errors by severity (CRITICAL first, then ERROR, then WARN) ---
        my @error_rows;
        eval {
            my $err_sth = $dbh->prepare(
                "SELECT level, subroutine, LEFT(message,200) as msg,
                        COALESCE(system_identifier,'(unknown)') as sys,
                        COUNT(*) as cnt
                 FROM system_log
                 WHERE level IN ('CRITICAL','ERROR','WARN') AND timestamp >= ?
                 GROUP BY level, subroutine, LEFT(message,200), system_identifier
                 ORDER BY
                     FIELD(level,'CRITICAL','ERROR','WARN'),
                     cnt DESC
                 LIMIT 30"
            );
            $err_sth->execute($cutoff);
            while (my $row = $err_sth->fetchrow_hashref) {
                push @error_rows, {
                    level      => $row->{level},
                    subroutine => $row->{subroutine},
                    message    => $row->{msg},
                    system     => $row->{sys},
                    count      => $row->{cnt},
                };
            }
        };
        $stats{top_errors} = \@error_rows;
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

# Return health status of all Docker containers whose name starts with 'comserv'.
# Each entry: { name, image, status, health, uptime, last_check, last_output }
# Returns [] if Docker is not available or no comserv containers found.
# Read the most recent [HEALTH][DOCKER_STATUS] entries from system_log for every
# system_identifier. Used by the admin dashboard so workstation can see production
# container health without needing direct Docker/SSH access.
# Returns [ { system_identifier, containers => [ {name,health,status_str,last_output,timestamp} ] } ]
sub get_docker_health_from_db {
    my ($class, $schema) = @_;
    my @results;
    eval {
        my $dbh = $schema->storage->dbh;
        # Get the latest DOCKER_STATUS entry per (system_identifier, container name)
        # Container name is embedded in message as "container=NAME "
        my $sth = $dbh->prepare(
            "SELECT system_identifier, message, timestamp
             FROM system_log
             WHERE message LIKE '[HEALTH][DOCKER_STATUS]%'
               AND timestamp >= DATE_SUB(NOW(), INTERVAL 2 HOUR)
             ORDER BY timestamp DESC
             LIMIT 500"
        );
        $sth->execute();
        my %seen; # system_identifier -> container_name -> row
        while (my $row = $sth->fetchrow_hashref) {
            my $sys  = $row->{system_identifier} // '(unknown)';
            my $msg  = $row->{message} // '';
            my ($cname)  = $msg =~ /container=(\S+)/;
            my ($health) = $msg =~ /health=(\S+)/;
            my ($status) = $msg =~ /status=([^ ]+(?:\s+\([^)]+\))?)/;
            my ($lcheck) = $msg =~ /last_check=(.+)$/;
            next unless $cname;
            next if exists $seen{$sys}{$cname}; # keep latest only
            $seen{$sys}{$cname} = {
                name        => $cname,
                health      => $health // 'unknown',
                status_str  => $status  // '',
                last_output => $lcheck  // '',
                timestamp   => $row->{timestamp},
            };
        }
        for my $sys (sort keys %seen) {
            push @results, {
                system_identifier => $sys,
                containers        => [ sort { $a->{name} cmp $b->{name} } values %{$seen{$sys}} ],
            };
        }
    };
    return \@results;
}

sub get_docker_health {
    my ($class) = @_;
    my @containers;
    eval {
        # docker ps — one line per container, tab-separated; timeout prevents hangs
        my @ps_lines;
        {
            local $SIG{CHLD} = 'DEFAULT';
            open(my $fh, '-|', qw(timeout 8 docker ps --all --no-trunc
                --format), '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.RunningFor}}')
                or die "docker ps: $!";
            @ps_lines = <$fh>;
            close $fh;
        }

        for my $line (@ps_lines) {
            chomp $line;
            my ($name, $image, $status_str, $running_for) = split /\t/, $line;
            next unless $name && $name =~ /^comserv/i;

            # Parse health from status string: "Up 2 hours (unhealthy)" / "(healthy)"
            my $health = 'none';
            $health = $1 if $status_str =~ /\((\w+)\)/;

            my $container = {
                name        => $name,
                image       => $image,
                status_str  => $status_str,
                uptime      => $running_for,
                health      => $health,
                last_output => '',
            };

            # Get last healthcheck output for unhealthy/starting containers
            if ($health eq 'unhealthy' || $health eq 'starting') {
                eval {
                    local $SIG{CHLD} = 'DEFAULT';
                    open(my $ifh, '-|', 'timeout', '5', 'docker', 'inspect',
                        '--format', '{{range .State.Health.Log}}{{.ExitCode}}:{{.Output}}|{{end}}',
                        $name) or die;
                    my $raw = do { local $/; <$ifh> };
                    close $ifh;
                    # Take only the most recent check (first segment before |)
                    if ($raw && $raw =~ /^(-?\d+):(.+?)\|/s) {
                        my ($exit, $out) = ($1, $2);
                        $out =~ s/\s+/ /g;
                        $out = substr($out, 0, 200);
                        $container->{last_output} = "exit=$exit: $out";
                    }
                };
            }

            push @containers, $container;
        }
    };
    return \@containers;
}

1;
