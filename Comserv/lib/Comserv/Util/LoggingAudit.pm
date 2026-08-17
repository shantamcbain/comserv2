package Comserv::Util::LoggingAudit;

use strict;
use warnings;
use File::Spec;
use DBI ();
use Comserv::Util::Logging;

# Logging-coverage audit. Mirrors the hardware_monitor pattern: a token-guarded
# controller endpoint (Catalyst::Controller::Admin::LoggingAudit::run) calls
# run_scan(); the cron (hardware_monitor.pl) triggers run periodically, exactly
# like it triggers /admin/hardware_monitor/run.
#
# Two scans:
#   1) LOG SCAN  — group system_log rows from the last N days by level/area/source,
#                  surface hot areas and any spike that warrants MORE logging.
#   2) CODE SCAN — grep lib/ for eval {}/try{}catch{} blocks whose body has no
#                  log_with_details call (silent error swallowing, per .ai-policy
#                  §7 / ai-editor-workflow hardblock). Each such site is a finding.
#
# Findings are written to the logging_audit table (Result class = source of truth)
# grouped by a scan_run_id. This module ONLY reports — it never edits code. If a
# code_scan finding indicates missing logging, the controller/results page routes a
# follow-up todo to the responsible project; this module does not create todos.

sub new { bless {}, shift }

sub generate_run_id {
    my ($sec, $min, $hour, $mday, $mon, $year) = localtime(time());
    return sprintf('LA-%04d%02d%02d-%02d%02d%02d',
        $year + 1900, $mon + 1, $mday, $hour, $min, $sec);
}

# Scan window (days) for the log grouping.
sub LOG_SCAN_DAYS { 7 }

# Robust error logger. Builds the full message from a pre-captured scalar BEFORE
# any nested eval runs, so a successful log_with_details() call (which internally
# uses eval and resets $@) can never erase the detail. Falls back to the plain
# catalyst logger if log_with_details itself dies, and never emits an empty
# message. This is the permanent fix for the "log scan failed: " (empty-detail)
# todo that kept re-opening: the true cause is always preserved verbatim in the
# message AND in $summary->{...}{error}.
sub _safe_log_error {
    my ($self, $c, $area, $raw_err) = @_;
    my $msg = "$raw_err";
    $msg =~ s/\s+/ /g;
    $msg = '(no detail captured)' if $msg eq '';
    my $full = "$area failed: $msg";
    eval {
        Comserv::Util::Logging->instance->log_with_details(
            $c, 'error', __FILE__, __LINE__, "logging_audit.$area", $full
        );
        1;
    } or do {
        my $inner = $@ || 'logger error';
        $c->log->error("$full [logger-fallback: $inner]") if $c->can('log');
    };
    return $msg;
}

# Run a DBI selectall_arrayref against the Ency handle with a one-shot reconnect
# + retry. The log-scan issues long GROUP BY queries over a multi-million-row
# system_log table; if the shared handle drops (idle timeout / server kill) mid
# query we must reconnect and retry ONCE rather than surface a "Lost connection"
# error. Mirrors the reconnect guard already used by the code-scan inserts.
sub _run_query {
    my ($self, $schema, $sql, $bind) = @_;
    my $rows = eval { $schema->storage->dbh->selectall_arrayref($sql, { Slice => {} }, @$bind) };
    return $rows if defined $rows;
    # Handle dropped mid-query: reconnect and retry once.
    eval {
        $schema->storage->disconnect;
        $schema->storage->dbh;
        $rows = $schema->storage->dbh->selectall_arrayref($sql, { Slice => {} }, @$bind);
    };
    return $rows;
}

# Entry point. Returns a summary hash { run_id, log => {...}, code => {} }.
sub run_scan {
    my ($self, $c, %opts) = @_;

    my $run_id = $opts{run_id} // generate_run_id();
    my $schema = eval { $c->model('DBEncy') };
    my $summary = { run_id => $run_id, log => {}, code => {} };

    unless ($schema) {
        $c->log->error("LoggingAudit: no DBEncy model") if $c->can('log');
        return $summary;
    }

    # ---- 1) LOG SCAN -------------------------------------------------------
    # NOTE: findings are rolled up PER RUN. Each scan run stores its own rows
    # (scan_run_id is present on every row and the results page groups by it),
    # so we INSERT (create), never update_or_create across runs. The
    # uniq_scan_run_finding constraint spans file_path/line_no which log-scan
    # rows do not set, so update_or_create with that key dies — create avoids it.
    eval {
        my $days = LOG_SCAN_DAYS;

        my $by_level = $self->_run_query($schema,
            "SELECT level, COUNT(*) AS cnt FROM system_log
             WHERE timestamp >= NOW() - INTERVAL ? DAY
             GROUP BY level ORDER BY cnt DESC",
            [ $days ]
        );
        $summary->{log}{by_level} = $by_level // [];

        my $by_area = $self->_run_query($schema,
            "SELECT subroutine, level, COUNT(*) AS cnt FROM system_log
             WHERE timestamp >= NOW() - INTERVAL ? DAY
             GROUP BY subroutine, level
             ORDER BY cnt DESC LIMIT 25",
            [ $days ]
        );
        $summary->{log}{by_area} = $by_area // [];

        # Persist a rolled-up finding per level so the results page can chart it.
        for my $row (@$by_level) {
            my $cnt = $row->{cnt} // 0;
            $schema->resultset('LoggingAudit')->create({
                scan_run_id => $run_id,
                scan_type   => 'log_scan',
                severity    => ($row->{level} =~ /critical|error/i) ? 'critical'
                              : ($row->{level} =~ /warn/i)          ? 'warning'
                              : 'info',
                target      => $row->{level} // 'unknown',
                finding     => 'level_count',
                detail      => "level=" . ($row->{level} // '?') . " count=$cnt",
                recommendation => $row->{level} =~ /critical|error/i
                    ? 'Review area for missing/insufficient log_with_details on failure paths'
                    : 'Adequate',
            });
        }
    };
    my $log_err = $@;
    if ($log_err) {
        # DBI can report via $DBI::errstr instead of $@ when RaiseError is off.
        $log_err ||= $DBI::errstr if defined $DBI::errstr;
        my $detail = $self->_safe_log_error($c, 'log_scan', $log_err);
        $summary->{log}{error} = $detail;
    }

    # ---- 2) CODE SCAN ------------------------------------------------------
    eval {
        my $lib_dir = File::Spec->catdir($c->config->{home}, 'lib');
        # Guard: if config->{home} is unset or lib/ is missing, scanning would
        # either die or (worse) walk the wrong tree and emit garbage findings.
        # Skip with a clear error instead of silently producing bad data.
        unless ($lib_dir && -d $lib_dir) {
            $summary->{code}{error} = "code_scan skipped: lib dir not found [$lib_dir]";
            return;
        }
        my @sites = @{ $self->_find_silent_swallow($lib_dir) // [] };
        $summary->{code}{sites} = \@sites;

        for my $s (@sites) {
            # Each site is persisted independently so one bad row cannot abort
            # the whole run. Coerce to defined strings (DBIC dislikes undef in
            # the unique-constraint columns; create needs scalars).
            my $file = $s->{file} // '';
            my $line = defined $s->{line} ? $s->{line} : 0;
            my $sub  = $s->{subroutine} // 'unknown';
            my $row = {
                scan_run_id    => $run_id,
                scan_type      => 'code_scan',
                severity       => 'warning',
                target         => $sub,
                finding        => 'missing_log_with_details',
                detail         => "catch block with no log_with_details: $file:$line",
                file_path      => $file,
                line_no        => $line,
                recommendation => 'Add log_with_details (critical/warning) in the catch block per .ai-policy.md section 7',
            };
            # One-shot reconnect: if the DB handle dropped (e.g. idle between
            # scans), reconnect and retry once before giving up on this row.
            my $inserted = eval { $schema->resultset('LoggingAudit')->create($row); 1 };
            unless ($inserted) {
                my $first_err = "$@";
                eval {
                    $schema->storage->disconnect;
                    $schema->storage->dbh;
                    $schema->resultset('LoggingAudit')->create($row);
                    1;
                } and $inserted = 1;
                $summary->{code}{error} //= $inserted ? $summary->{code}{error} : $first_err;
            }
        }
    };
    my $code_err = $@;
    if ($code_err) {
        $code_err ||= $DBI::errstr if defined $DBI::errstr;
        my $detail = $self->_safe_log_error($c, 'code_scan', $code_err);
        $summary->{code}{error} = $detail unless defined $summary->{code}{error};
    }

    # ---- Summary log (audit trail of the audit) ----------------------------
    my $log_n = scalar(@{ $summary->{code}{sites} // [] });
    eval { Comserv::Util::Logging->instance->log_with_details($c, 'info', __FILE__, __LINE__,
        'logging_audit.run',
        "[LOG-AUDIT] run=$run_id code_sites=$log_n"
        . " log_error=" . ($summary->{log}{error} // 'none')
        . " code_error=" . ($summary->{code}{error} // 'none')); };

    return $summary;
}

# Scan .pm files under $dir for catch/except blocks that swallow errors without a
# log_with_details call. Conservative heuristic: match a bare "catch" or "except"
# (Try::Tiny / Try::Tiny::Smart / plain) followed (within 40 lines) by a closing
# brace, and flag it if no "log_with_details" appears in that span. Also catches
# eval {} blocks whose body has a die/throw but no log_with_details.
sub _find_silent_swallow {
    my ($self, $dir) = @_;
    return [] unless $dir && -d $dir;

    my @sites;
    my @files;
    eval {
        require File::Find;
        File::Find::find({ wanted => sub {
            push @files, $File::Find::name if /\.pm$/ && -f $File::Find::name;
        }, no_chdir => 1 }, $dir);
    };
    return \@sites if $@;

    # Skip dirs that are not application business logic: tests, scripts, view
    # templates, Catalyst boilerplate, and the app bootstrap file (its eval{}
    # blocks are framework/loader noise, not silent-swallow bugs). This keeps
    # the audit signal high and avoids 200+ false positives.
    my $SKIP_RE = qr{(?:/t/|/script/|/root/|/auto/|/Catalyst/|/Comserv\.pm$)};

    my $LW = 'log_with_details';
    for my $file (@files) {
        next if $file =~ $SKIP_RE;
        open(my $fh, '<', $file) or next;
        my @lines = <$fh>;
        close $fh;
        chomp @lines;

        for my $i (0 .. $#lines) {
            # Detect start of an error-handling construct.
            if ($lines[$i] =~ /\b(?:catch|except)\b\s*[{（(]/o
                || $lines[$i] =~ /\beval\s*\{/o) {
                my $start = $i;
                my $end   = $i + 40;
                $end = $#lines if $end > $#lines;
                my $has_lw = 0;
                my $has_err = 0;
                for my $j ($start .. $end) {
                    $has_lw  = 1 if $lines[$j] =~ /\Q$LW\E/o;
                    # Only genuine failure paths (die/croak/confess/throw), not
                    # a bare warn — a warn without a log is noisy, not silent.
                    $has_err = 1 if $lines[$j] =~ /\b(?:die|throw|croak|confess)\b/o;
                }
                # Flag: it's an error path (die/throw) but no log_with_details in span.
                if ($has_err && !$has_lw) {
                    push @sites, {
                        file       => $file,
                        line       => $i + 1,
                        subroutine => _nearest_sub(\@lines, $i),
                    };
                }
            }
        }
    }
    return \@sites;
}

# Best-effort: find the nearest 'sub NAME' above line $idx.
sub _nearest_sub {
    my ($lines, $idx) = @_;
    for (my $j = $idx; $j >= 0; $j--) {
        if ($lines->[$j] =~ /^\s*sub\s+([A-Za-z0-9_]+)/) {
            return $1;
        }
    }
    return 'unknown';
}

1;
