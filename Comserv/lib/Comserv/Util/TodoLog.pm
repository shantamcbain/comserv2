package Comserv::Util::TodoLog;
use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use DateTime;

=head1 NAME

Comserv::Util::TodoLog — ONE shared implementation of the todo work-log lifecycle.

Used by BOTH the UI (Controller::Todo open_log/close_log/done_with_log) and the
API (Controller::Api api_todo_*), so a Start/Stop/Done button click and its API
equivalent behave identically. This is the single source of truth for:

Status semantics:
  5 = ACTIVE (log open)   — Start pressed (or log opened)
  2 = IN PROGRESS (idle)  — Stop pressed (log closed, todo not done)
  3 = DONE                — Done pressed

Summary placement rules:
  toggle_start : opens log + todo -> 5; if already active it STOPS instead
                 (closes log + todo -> 2) writing the summary into BOTH
                 the log comments AND the todo comments.
  close_log    : closes the open log + todo -> 2, summary into BOTH the
                 log comments AND the todo comments. If no log is open this is
                 GRACEFUL (warn level, success:0/graceful flag) — never an
                 ERROR audit todo.
  done_with_log: closes the open log (or inserts a completed one if none was
                 open) with the summary in the log comments, todo -> 3.

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

# Internal: insert a completed (status=3) log row for a todo that had no open log.
sub _insert_completed_log {
    my ($c, %args) = @_;
    my ($dbh, $todo, $proj_code) = _todo_ctx($c, $args{record_id});
    my $now      = DateTime->now(time_zone => 'local');
    my $today    = $now->ymd;
    my $now_hms  = $now->hms;
    my $est_mins = $args{duration_mins}
                   // eval { $todo->estimated_man_hours * 60 } // 15;
    $est_mins = 15 if $est_mins < 1;
    my ($dur_hms, undef) = _duration_hms('09:00', '00:' . sprintf('%02d', $est_mins % 60));
    $dur_hms = sprintf('%02d:%02d:00', int($est_mins / 60), $est_mins % 60);

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

# ===========================================================================
# PUBLIC: toggle_start — mirrors what the UI "Start" button should do.
#   { action => 'opened'|'stopped', log_id, duration_mins?, already_active? }
# ===========================================================================
sub toggle_start {
    my ($class, $c, %args) = @_;
    my $record_id = $args{record_id} or die "Missing record_id\n";
    my $username  = $args{username} // 'api';
    my $summary   = $args{summary} // '';

    my $now     = DateTime->now(time_zone => 'local');
    my $today   = $now->ymd;
    my $now_hms = $now->hms;

    my $result = try {
        my ($dbh, $todo, $proj_code) = _todo_ctx($c, $record_id);

        # Already active? Then Start acts as STOP: close log, todo -> 2,
        # summary into BOTH the log comments and the todo comments.
        my $open_row = $dbh->selectrow_hashref(
            "SELECT record_id, start_time FROM log WHERE todo_record_id=? AND end_time='00:00:00' AND status!=3 ORDER BY record_id DESC LIMIT 1",
            undef, $record_id
        );
        if ($open_row) {
            my ($dur_hms, $dur_mins) = _duration_hms($open_row->{start_time}, $now_hms);
            my $stop_summary = $summary ne '' ? $summary
                               : ('Stopped: ' . ($todo->subject // '') . " by $username");
            $dbh->do(
                'UPDATE log SET end_time=?, time=?, status=3, last_mod_by=?, last_mod_date=?, comments=? WHERE record_id=?',
                undef, $now_hms, $dur_hms, $username, $today, $stop_summary, $open_row->{record_id}
            );
            # Summary ALSO into the todo comments.
            $dbh->do("UPDATE todo SET status=2, last_mod_by=?, last_mod_date=?, comments=? WHERE record_id=?",
                undef, $username, $today, $stop_summary, $record_id);
            return { success => 1, action => 'stopped', log_id => $open_row->{record_id},
                     duration_mins => $dur_mins };
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
        return { success => 1, action => 'opened', log_id => ($new_log_id // 0) };
    } catch {
        die $_;  # caller logs via log_with_details (audit trail requirement)
    };
    return $result;
}

# ===========================================================================
# PUBLIC: close_log — stop work WITHOUT marking done. Graceful when no log
# is open (returns graceful flag; caller logs at warn, never error).
#   { success, log_id, duration_mins } or { success=>0, graceful=>1 }
# ===========================================================================
sub close_log {
    my ($class, $c, %args) = @_;
    my $record_id = $args{record_id} or die "Missing record_id\n";
    my $username  = $args{username} // 'api';
    my $summary   = $args{summary} // '';

    my $now_dt  = DateTime->now(time_zone => 'local');
    my $today   = $now_dt->ymd;
    my $now_hms = $now_dt->strftime('%H:%M:%S');

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

        my $open_row = $dbh->selectrow_hashref(
            "SELECT record_id, start_time FROM log WHERE todo_record_id=? AND end_time='00:00:00' AND status!=3 ORDER BY record_id DESC LIMIT 1",
            undef, $record_id
        );
        unless ($open_row) {
            # Graceful: nothing open to close. NOT an error condition.
            return { success => 0, graceful => 1,
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

        return { success => 1, log_id => $open_row->{record_id}, duration_mins => $dur_mins };
    } catch {
        die $_;  # caller logs via log_with_details
    };
    return $result;
}

# ===========================================================================
# PUBLIC: done_with_log — mark DONE (status 3). Closes any open log with the
# summary; if none open, inserts a completed log. Summary lives in the LOG;
# the todo status becomes 3.
#   { success, log_closed }
# ===========================================================================
sub done_with_log {
    my ($class, $c, %args) = @_;
    my $record_id = $args{record_id} or die "Missing record_id\n";
    my $username  = $args{username} // 'api';
    my $summary   = $args{summary} // '';

    my $now_dt  = DateTime->now(time_zone => 'local');
    my $today   = $now_dt->ymd;
    my $now_hms = $now_dt->strftime('%H:%M:%S');

    my $result = try {
        my ($dbh, $todo, undef) = _todo_ctx($c, $record_id);

        my $done_summary = $summary ne '' ? $summary
                           : ('Done: ' . ($todo->subject // '') . " by $username");

        my $open_row = $dbh->selectrow_hashref(
            "SELECT record_id, start_time FROM log WHERE todo_record_id=? AND end_time='00:00:00' AND status!=3 ORDER BY record_id DESC LIMIT 1",
            undef, $record_id
        );
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

        return { success => 1, log_closed => $log_closed };
    } catch {
        die $_;  # caller logs via log_with_details
    };
    return $result;
}

__PACKAGE__->meta->make_immutable;
1;
