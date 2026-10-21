package Comserv::Util::TodoLog;
use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use Comserv::Util::AppTime;

=head1 NAME

Comserv::Util::TodoLog — ONE shared implementation of the todo work-log lifecycle.

Used by BOTH the UI (Controller::Todo open_log/close_log/done_with_log) and the
API (Controller::Api api_todo_*), so a Start/Stop/Done button click and its API
equivalent behave identically. This is the single source of truth for:

Status semantics:
  5 = ACTIVE (being worked — log open)  — Start pressed (or log opened)
  2 = IN PROGRESS (idle)                — Stop pressed (log closed, todo not done)
  3 = DONE                              — Done pressed

Summary placement rules:
  work_status  : read-only report. One todo (record_id) or all currently
                 being-worked rows (todo status 5 and/or open log).
  toggle_start : opens log + todo -> 5. If already being worked (status 5
                 or an open log), REPORT already_active and do NOT stop.
                 Stop is close_log only — a stale Start click must not
                 kill a running session.
  close_log    : closes the open log + todo -> 2, summary into BOTH the
                 log comments AND the todo comments. If no log is open this is
                 GRACEFUL (warn level, success:0/graceful flag) — never an
                 ERROR audit todo.
  done_with_log: closes the open log (or inserts a completed one if none was
                 open) with the summary in the log comments, todo -> 3.
                 If already status 3 and no open log: already_done, no insert.

Time (AppTime):
  start_time / end_time / last_mod_date on log rows are UTC.
  Calendar "today" for day buckets uses the viewer's zone via AppTime.

=cut

# ---------------------------------------------------------------------------
# Internal: compute duration hms between an open log's start_time and now.
sub _duration_hms {
    my ($raw_start, $now_hms) = @_;
    $raw_start = defined $raw_start ? "$raw_start" : '';
    my $start_hms = ($raw_start =~ /^\d{1,2}:\d{2}/) ? substr($raw_start, 0, 8) : '09:00:00';
    my ($sh, $sm) = ($start_hms =~ /^(\d+):(\d+)/);
    my ($eh, $em) = ($now_hms   =~ /^(\d{2}):(\d{2})/);
    my $dur_mins  = (($eh // 9) * 60 + ($em // 0)) - (($sh // 9) * 60 + ($sm // 0));
    $dur_mins = 1 if !defined $dur_mins || $dur_mins <= 0;
    return (sprintf('%02d:%02d:00', int($dur_mins / 60), $dur_mins % 60), $dur_mins);
}

# Internal: UTC clock for log writes + user-local ymd for last_mod day labels.
sub _clock {
    my ($c) = @_;
    # Storage times always UTC so duration is host-independent.
    my $now_hms = Comserv::Util::AppTime->now_hms_utc;
    # last_mod_date / start_date day bucket: viewer "today" when $c present.
    my $today = $c
        ? Comserv::Util::AppTime->today_ymd_for($c)
        : Comserv::Util::AppTime->today_utc_ymd;
    return ( $today, $now_hms );
}

# Internal: fetch the todo row + project code.
sub _todo_ctx {
    my ($c, $record_id) = @_;
    my $dbh    = $c->model('DBEncy')->storage->dbh;
    my $todo   = $c->model('DBEncy')->resultset('Todo')->find($record_id)
        or die "Todo not found\n";
    my $proj_code = '';
    if ($todo->project_id) {
        my $proj = eval { $c->model('DBEncy')->resultset('Project')->find($todo->project_id) };
        $proj_code = $proj ? ($proj->project_code || '') : '';
    }
    return ($dbh, $todo, $proj_code);
}

# Internal: open work-log row (end_time sentinel, not completed).
sub _open_log_row {
    my ($dbh, $record_id) = @_;
    return $dbh->selectrow_hashref(
        "SELECT record_id, start_time, start_date, username, abstract, status
         FROM log WHERE todo_record_id=? AND end_time='00:00:00' AND status!=3
         ORDER BY record_id DESC LIMIT 1",
        undef, $record_id
    );
}

# Internal: insert a completed (status=3) log row for a todo that had no open log.
sub _insert_completed_log {
    my ($c, %args) = @_;
    my ($dbh, $todo, $proj_code) = _todo_ctx($c, $args{record_id});
    my ( $today, $now_hms ) = _clock($c);
    my $est_mins = $args{duration_mins}
                   // eval { $todo->estimated_man_hours * 60 } // 15;
    $est_mins = 15 if $est_mins < 1;
    # MySQL TIME max is 838:59:59. estimated_man_hours of 840 (todo 2103)
    # produced '840:00:00' and DBI rejected the INSERT (audit todo 2312).
    # Use a sane default (30 min) for the no-open-log fallback path instead of
    # trusting potentially-absurd estimated_man_hours.
    if ($est_mins > 8*60) { $est_mins = 30; }
    my $mysql_time_max_mins = (838 * 60) + 59;
    $est_mins = $mysql_time_max_mins if $est_mins > $mysql_time_max_mins;
    my $dur_hms = sprintf('%02d:%02d:00', int($est_mins / 60), $est_mins % 60);

    $dbh->do(
        'INSERT INTO log (todo_record_id, username, sitename, project_code, abstract, details, start_date, due_date, start_time, end_time, time, status, priority, last_mod_by, last_mod_date, group_of_poster, comments) VALUES (?,?,?,?,?,?,?,?,?,?,?,3,?,?,?,?,?)',
        undef,
        $args{record_id}, $args{username}, (eval { $todo->sitename } || ''), $proj_code,
        'Completed: ' . ($todo->subject // ''),
        $args{summary},
        $today, (eval { my $dd = $todo->due_date; $dd ? (ref($dd) ? $dd->ymd : substr("$dd",0,10)) : $today } // $today),
        $now_hms, $now_hms, $dur_hms,
        (eval { $todo->priority } // 5), $args{username}, $today,
        ($c->session->{group} || ''), $args{summary}
    );
    return $dbh->last_insert_id(undef, undef, 'log', 'record_id');
}

# Pack one active row for work_status (AI report + stale-page sync).
sub _status_payload {
    my ($todo, $open_row) = @_;
    my $todo_status = eval { $todo->status } // '';
    my $active = ($open_row || "$todo_status" eq '5') ? 1 : 0;
    my $out = {
        success      => 1,
        record_id    => eval { $todo->record_id } // 0,
        todo_status  => $todo_status,
        active       => $active,
        subject      => (eval { $todo->subject } // ''),
        last_mod_by  => (eval { $todo->last_mod_by } // ''),
    };
    if ($open_row) {
        $out->{log_id}     = $open_row->{record_id};
        $out->{start_time} = $open_row->{start_time} // '';
        $out->{start_date} = $open_row->{start_date} // '';
        $out->{actor}      = $open_row->{username} // '';
        $out->{abstract}   = $open_row->{abstract} // '';
    }
    return $out;
}

# ===========================================================================
# PUBLIC: work_status — read-only. Status 5 = being worked.
#   record_id => one todo
#   no record_id => { success, active => [ ... ] } all open logs / status 5
# ===========================================================================
sub work_status {
    my ($class, $c, %args) = @_;
    my $record_id = $args{record_id};

    my $result = try {
        my $dbh = $c->model('DBEncy')->storage->dbh;

        if ($record_id) {
            my ($dbh2, $todo, undef) = eval { _todo_ctx($c, $record_id) };
            if ($@ && $@ =~ /Todo not found/) {
                return { success => 0, graceful => 1,
                         message => "Todo $record_id not found" };
            }
            die $@ if $@;
            my $open_row = _open_log_row($dbh2, $record_id);
            return _status_payload($todo, $open_row);
        }

        # All currently-being-worked: open log OR todo.status = 5.
        my $rows = $dbh->selectall_arrayref(
            q{
                SELECT t.record_id, t.status, t.subject, t.last_mod_by,
                       l.record_id AS log_id, l.start_time, l.start_date,
                       l.username AS actor, l.abstract
                FROM todo t
                LEFT JOIN log l
                  ON l.todo_record_id = t.record_id
                 AND l.end_time = '00:00:00'
                 AND l.status != 3
                WHERE t.status = 5
                   OR (l.record_id IS NOT NULL)
                ORDER BY t.record_id
            },
            { Slice => {} }
        ) || [];

        my @active;
        my %seen;
        for my $r (@$rows) {
            my $id = $r->{record_id} // next;
            next if $seen{$id}++;
            push @active, {
                record_id   => 0 + $id,
                todo_status => $r->{status} // '',
                active      => 1,
                subject     => $r->{subject} // '',
                last_mod_by => $r->{last_mod_by} // '',
                log_id      => $r->{log_id} ? 0 + $r->{log_id} : undef,
                start_time  => $r->{start_time} // '',
                start_date  => $r->{start_date} // '',
                actor       => $r->{actor} // '',
                abstract    => $r->{abstract} // '',
            };
        }
        return { success => 1, count => scalar(@active), active => \@active };
    } catch {
        die $_;  # caller logs via log_with_details
    };
    return $result;
}

# ===========================================================================
# PUBLIC: toggle_start — UI/API "Start". Does NOT stop an active session.
#   { action => 'opened'|'already_active', log_id, todo_status }
# ===========================================================================
sub toggle_start {
    my ($class, $c, %args) = @_;
    my $record_id = $args{record_id} or die "Missing record_id\n";
    my $username  = $args{username} // 'api';
    my $summary   = $args{summary} // '';

    my ( $today, $now_hms ) = _clock($c);

    my $result = try {
        my ($dbh, $todo, $proj_code) = _todo_ctx($c, $record_id);

        # Already being worked (status 5 or open log)? Report — do not Stop.
        # Stale ▶ Start and a second API open_log must not kill the session.
        my $open_row = _open_log_row($dbh, $record_id);
        my $todo_status = eval { $todo->status } // '';
        if ($open_row || "$todo_status" eq '5') {
            my $payload = _status_payload($todo, $open_row);
            $payload->{action} = 'already_active';
            $payload->{already_active} = 1;
            return $payload;
        }

        # Not active: open a new log + todo -> 5.
        my $sitename_val = eval { $todo->sitename } || $c->session->{SiteName} || 'CSC';
        my $due_date_val = eval {
            my $dd = $todo->due_date;
            $dd ? (ref($dd) ? $dd->ymd : substr("$dd",0,10)) : $today;
        } // $today;
        $dbh->do(
            'INSERT INTO log (todo_record_id, username, sitename, project_code, abstract, details, start_date, due_date, start_time, end_time, time, status, priority, last_mod_by, last_mod_date, group_of_poster, comments) VALUES (?,?,?,?,?,?,?,?,?,"00:00:00","00:00:00",2,?,?,?,?,?)',
            undef,
            $record_id, $username, $sitename_val, $proj_code,
            'Started: ' . ($todo->subject // ''),
            "Work begun by $username",
            $today, $due_date_val, $now_hms,
            (eval { $todo->priority } // 5), $username, $today,
            ($c->session->{group} || ''), (eval { $todo->comments } // '')
        );
        my $new_log_id = $dbh->last_insert_id(undef, undef, 'log', 'record_id');
        $dbh->do("UPDATE todo SET status=5, last_mod_by=?, last_mod_date=? WHERE record_id=?",
            undef, $username, $today, $record_id);

        # Soft guidance when Start has no executable work order (todo #2350).
        # Append-only — never wipe comments. UI/API Start both use toggle_start.
        my $desc = eval { $todo->description } // '';
        my $has_work_order = ($desc =~ /ROOT\s+CAUSE|CODER_READY|(?m)^\s*DO\s*:/i) ? 1 : 0;
        unless ($has_work_order) {
            my $cmt = eval { $todo->comments } // '';
            unless ($cmt =~ /WORK_ORDER_NEEDED/) {
                my $hint = "WORK_ORDER_NEEDED: description lacks ROOT/DO/DO NOT/ACCEPT — "
                    . "Director must fill a work order before Coder runs ($today).\n";
                $dbh->do("UPDATE todo SET comments=? WHERE record_id=?",
                    undef, $cmt . $hint, $record_id);
            }
        }

        return { success => 1, action => 'opened', log_id => ($new_log_id // 0),
                 todo_status => 5, already_active => 0,
                 work_order_missing => $has_work_order ? 0 : 1 };
    } catch {
        die $_;  # caller logs via log_with_details (audit trail requirement)
    };
    return $result;
}

# ===========================================================================
# PUBLIC: close_log — stop work WITHOUT marking done. Graceful when no log
# is open (returns graceful flag; caller logs at warn, never error).
#   { success, log_id, duration_mins, todo_status } or { success=>0, graceful=>1 }
# ===========================================================================
sub close_log {
    my ($class, $c, %args) = @_;
    my $record_id = $args{record_id} or die "Missing record_id\n";
    my $username  = $args{username} // 'api';
    my $summary   = $args{summary} // '';

    my ( $today, $now_hms ) = _clock($c);

    my $result = try {
        my ($dbh, $todo, undef) = eval { _todo_ctx($c, $record_id) };
        if ($@ && $@ =~ /Todo not found/) {
            # Bad record_id from the caller — a client error, not a server
            # fault. Graceful so it warns instead of creating an error-audit
            # todo (todo 2249: probe with record_id 999999).
            return { success => 0, graceful => 1,
                     message => "Todo $record_id not found" };
        }
        die $@ if $@;
        $todo or die "Todo not found\n";

        my $open_row = _open_log_row($dbh, $record_id);
        unless ($open_row) {
            # Graceful: nothing open to close. NOT an error condition.
            # Status 5 with no log is a stuck "being worked" row (stale page /
            # agent never closed). Clear it to idle (2) so Stop actually recovers.
            my $st = eval { $todo->status } // '';
            if ("$st" eq '5') {
                $dbh->do("UPDATE todo SET status=2, last_mod_by=?, last_mod_date=? WHERE record_id=?",
                    undef, $username, $today, $record_id);
                return { success => 1, graceful => 1, recovered => 1, todo_status => 2,
                         message => "No open log for todo $record_id; cleared stuck status 5 -> 2" };
            }
            return { success => 0, graceful => 1, todo_status => $st,
                     message => "No open log found for todo $record_id" };
        }

        my ($dur_hms, $dur_mins) = _duration_hms($open_row->{start_time}, $now_hms);
        my $close_summary = $summary ne '' ? $summary
                            : ("Stopped: " . ($todo->subject // '') . " after ${dur_mins} min by $username");
        $dbh->do(
            'UPDATE log SET end_time=?, time=?, status=3, last_mod_by=?, last_mod_date=?, comments=? WHERE record_id=?',
            undef, $now_hms, $dur_hms, $username, $today, $close_summary, $open_row->{record_id}
        );
        # Summary ALSO into the todo comments.
        $dbh->do("UPDATE todo SET status=2, last_mod_by=?, last_mod_date=?, comments=? WHERE record_id=?",
            undef, $username, $today, $close_summary, $record_id);

        return { success => 1, log_id => $open_row->{record_id}, duration_mins => $dur_mins,
                 todo_status => 2 };
    } catch {
        die $_;  # caller logs via log_with_details
    };
    return $result;
}

# ===========================================================================
# PUBLIC: done_with_log — mark DONE (status 3). Closes any open log with the
# summary; if none open, inserts a completed log. Summary lives in the LOG;
# the todo status becomes 3.
#   { success, log_closed, todo_status } or { already_done => 1 }
# ===========================================================================
sub done_with_log {
    my ($class, $c, %args) = @_;
    my $record_id = $args{record_id} or die "Missing record_id\n";
    my $username  = $args{username} // 'api';
    my $summary   = $args{summary} // '';

    my ( $today, $now_hms ) = _clock($c);

    my $result = try {
        my ($dbh, $todo, undef) = _todo_ctx($c, $record_id);

        my $done_summary = $summary ne '' ? $summary
                           : ('Done: ' . ($todo->subject // '') . " by $username");

        my $open_row = _open_log_row($dbh, $record_id);
        my $todo_status = eval { $todo->status } // '';

        # Already done and no running log: report, do not insert a second log.
        if ("$todo_status" eq '3' && !$open_row) {
            return { success => 1, already_done => 1, log_closed => 0, todo_status => 3 };
        }

        my $log_closed = 0;
        if ($open_row) {
            my ($dur_hms, $dur_mins) = _duration_hms($open_row->{start_time}, $now_hms);
            $dbh->do(
                'UPDATE log SET end_time=?, time=?, status=3, last_mod_by=?, last_mod_date=?, comments=? WHERE record_id=?',
                undef, $now_hms, $dur_hms, $username, $today, $done_summary, $open_row->{record_id}
            );
            $log_closed = 1;
        } else {
            _insert_completed_log($c,
                record_id => $record_id, username => $username,
                summary   => $done_summary,
                duration_mins => $args{duration_mins});
        }

        $dbh->do("UPDATE todo SET status=3, last_mod_by=?, last_mod_date=? WHERE record_id=?",
            undef, $username, $today, $record_id);

        return { success => 1, log_closed => $log_closed, todo_status => 3,
                 already_done => ("$todo_status" eq '3') ? 1 : 0 };
    } catch {
        die $_;  # caller logs via log_with_details
    };
    return $result;
}

__PACKAGE__->meta->make_immutable;
1;
