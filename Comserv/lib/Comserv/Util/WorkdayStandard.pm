package Comserv::Util::WorkdayStandard;
use strict;
use warnings;
use POSIX ();

# One workstation standard for the day.
# A check is read-only. End of day is the only action, and it never stops :4006.
# Hermes dashboards are not branch servers: one host lock, many ports. Leaving
# them up overnight is what makes the next morning's open observe-only.

our $KEEP_PORT     = 4006;
our $STALE_LOG_H   = 12;
our $STALE_COMMIT_D = 14;

sub keep_port { return $KEEP_PORT }

# guest/normal: the log records the assist. developer/admin: the log records
# what was done on the todo. editor is treated as developer.
sub role_class {
    my ($class, @roles) = @_;
    my %r = map { lc($_) => 1 } grep { defined && length } @roles;
    return 'admin'     if $r{admin};
    return 'developer' if $r{developer} || $r{editor};
    return 'normal'    if $r{user} || $r{normal} || $r{member};
    return 'guest';
}

sub log_style {
    my ($class, $role) = @_;
    $role = $class->role_class($role) if !defined $role || $role =~ /,/;
    return ($role eq 'admin' || $role eq 'developer') ? 'work' : 'assist';
}

sub _row_epoch {
    my ($row) = @_;
    my $d = $row->{start_date} // '';
    my $t = $row->{start_time} // '';
    return undef unless $d =~ /^(\d{4})-(\d{2})-(\d{2})/;
    my ($Y, $Mo, $Da) = ($1, $2, $3);
    my ($H, $M, $S) = (0, 0, 0);
    ($H, $M, $S) = ($1, $2, $3) if $t =~ /^(\d{2}):(\d{2}):(\d{2})/;
    require Time::Local;
    return eval { Time::Local::timelocal($S, $M, $H, $Da, $Mo - 1, $Y) };
}

# Pure. Rows are TodoLog work_status active rows.
sub classify_work_rows {
    my ($class, $rows, $now) = @_;
    $rows ||= [];
    $now //= time;
    my (@stale, @nolog);
    for my $r (@$rows) {
        next unless $r && ref $r eq 'HASH';
        my $status = defined $r->{todo_status} ? "$r->{todo_status}" : '';
        my $has_log = $r->{log_id};
        if (!$has_log && $status eq '5') {
            push @nolog, { %$r, reason => 'status 5 with no log row' };
            next;
        }
        next unless $has_log;
        my $start = _row_epoch($r);
        my $age_h = (defined $start) ? int(($now - $start) / 3600) : undef;
        if (!defined $age_h || $age_h >= $STALE_LOG_H) {
            push @stale, {
                %$r,
                age_hours => $age_h,
                reason => defined $age_h
                    ? "open log ${age_h}h (over ${STALE_LOG_H}h)"
                    : 'open log with no start time',
            };
        }
    }
    return { stale_logs => \@stale, started_without_log => \@nolog };
}

sub _listening {
    my ($port) = @_;
    return 0 unless $port && $port =~ /^\d+$/;
    require Comserv::Util::AI::StalePreflight;
    my $pid = Comserv::Util::AI::StalePreflight::pid_for_port($port);
    return $pid ? $pid : 0;
}

sub _proc_cmd {
    my ($pid) = @_;
    return '' unless $pid && $pid =~ /^\d+$/ && -r "/proc/$pid/cmdline";
    open my $fh, '<', "/proc/$pid/cmdline" or return '';
    local $/;
    my $raw = <$fh> // '';
    close $fh;
    return join ' ', split /\0/, $raw;
}

# Dashboard and gateway processes. Not the branch-server perl.
sub hermes_processes {
    my ($class) = @_;
    my @out;
    opendir my $dh, '/proc' or return \@out;
    for my $pid (grep { /^\d+$/ } readdir $dh) {
        next if $pid == $$ || $pid == ($ENV{WORKDAY_PARENT_PID} || getppid() || 0);
        my $cmd = _proc_cmd($pid);
        next unless length $cmd;
        my $kind;
        $kind = 'dashboard' if $cmd =~ /dashboard --isolated/;
        $kind = 'gateway'   if !$kind && $cmd =~ /gateway run/;
        $kind = 'tui'       if !$kind && $cmd =~ m{ui-tui/dist/entry\.js};
        next unless $kind;
        my ($port) = $cmd =~ /--port\s+(\d+)/;
        push @out, { pid => 0 + $pid, kind => $kind, port => ($port ? 0 + $port : undef), cmd => substr($cmd, 0, 180) };
    }
    closedir $dh;
    return \@out;
}

sub extra_servers {
    my ($class) = @_;
    require Comserv::Util::Git;
    my $list = eval { Comserv::Util::Git->build_worktree_list } || [];
    my @out;
    for my $b (@$list) {
        next if $b->{external};
        my $port = int($b->{port} || 0);
        next unless $port && $port != $KEEP_PORT;
        my $pid = _listening($port);
        next unless $pid;
        push @out, {
            name => $b->{name}, port => $port, pid => $pid,
            reason => "branch server :$port still listening (keep only :$KEEP_PORT)",
        };
    }
    return \@out;
}

sub _git {
    my ($dir, @args) = @_;
    return '' unless $dir && -d $dir;
    my $pid = open(my $fh, '-|') // return '';
    if (!$pid) {
        eval { require Comserv::Util::ForkSafe; Comserv::Util::ForkSafe::child_prepare() };
        open STDERR, '>', '/dev/null';
        no warnings 'exec';
        exec { 'git' } 'git', '-C', $dir, @args;
        POSIX::_exit(127);
    }
    local $/;
    my $out = <$fh> // '';
    close $fh;
    return $out;
}

sub stale_commits {
    my ($class, $now) = @_;
    $now //= time;
    require Comserv::Util::Git;
    my $list = eval { Comserv::Util::Git->build_worktree_list } || [];
    my @out;
    for my $b (@$list) {
        my $dir = $b->{hermes_cwd} || $b->{repo} || '';
        next unless $dir && -d $dir;
        my $line = _git($dir, 'log', '-1', '--format=%ct%x09%h%x09%s');
        next unless $line =~ /^(\d+)\t(\S+)\t(.*)/;
        my ($epoch, $sha, $subject) = ($1 + 0, $2, $3);
        my $age_d = int(($now - $epoch) / 86400);
        next if $age_d < $STALE_COMMIT_D;
        my $branch = $b->{name} // '';
        next if $branch eq 'main';
        my $ahead = _git($dir, 'rev-list', '--count', 'main..HEAD');
        chomp $ahead if defined $ahead;
        $ahead = ($ahead =~ /^(\d+)/) ? $1 + 0 : 0;
        next unless $ahead > 0;
        push @out, {
            name => $branch, port => $b->{port}, repo => $dir,
            sha => $sha, age_days => $age_d, ahead => $ahead,
            subject => $subject,
            reason => "HEAD $sha is ${age_d}d old and $ahead commit(s) are not in main",
        };
    }
    return \@out;
}

sub check {
    my ($class, %o) = @_;
    my $work = $class->classify_work_rows($o{work_rows} || [], $o{now});
    my $hermes = $o{skip_proc} ? [] : $class->hermes_processes;
    my $servers = $o{skip_proc} ? [] : $class->extra_servers;
    my $commits = $o{skip_git} ? [] : $class->stale_commits($o{now});
    my $report = {
        success => 1,
        keep_port => $KEEP_PORT,
        %$work,
        hermes => $hermes,
        extra_servers => $servers,
        stale_commits => $commits,
    };
    $report->{counts} = {
        stale_logs => scalar @{ $work->{stale_logs} },
        started_without_log => scalar @{ $work->{started_without_log} },
        hermes => scalar @$hermes,
        extra_servers => scalar @$servers,
        stale_commits => scalar @$commits,
    };
    $report->{keep_listening} = $o{skip_proc} ? undef : (_listening($KEEP_PORT) ? 1 : 0);
    $report->{ok} = (grep { $_ } values %{ $report->{counts} }) ? 0 : 1;
    return $report;
}

# confirm is required. Never stops :4006. Does not invent a log duration.
sub end_of_day {
    my ($class, %o) = @_;
    return { success => 0, error => 'confirm required' } unless $o{confirm};
    my $report = $class->check(%o);
    my @stopped;
    my @errors;
    require Comserv::Util::BranchServerControl;
    my $ctl = Comserv::Util::BranchServerControl->new;
    for my $s (@{ $report->{extra_servers} }) {
        next if int($s->{port} || 0) == $KEEP_PORT;
        my $res = eval { $ctl->stop($s->{name}, $s->{port}) };
        if ($@ || !$res || !$res->{ok}) {
            push @errors, "$s->{name}:$s->{port} " . ($@ || $res->{error} || 'stop failed');
        } else {
            push @stopped, { name => $s->{name}, port => $s->{port} };
        }
    }
    my @signaled;
    if (!$o{keep_hermes}) {
        for my $h (@{ $class->hermes_processes }) {
            next if $h->{pid} == $$;
            my $ok = kill 'TERM', $h->{pid};
            push @signaled, { pid => $h->{pid}, kind => $h->{kind}, signaled => $ok ? 1 : 0 };
        }
    }
    return {
        success => @errors ? 0 : 1,
        keep_port => $KEEP_PORT,
        stopped => \@stopped,
        hermes_signaled => \@signaled,
        errors => \@errors,
        still_open => {
            stale_logs => $report->{stale_logs},
            started_without_log => $report->{started_without_log},
        },
        note => 'Logs were not closed here. Close them with close_log so a stale clock is not billed as work.',
    };
}

1;
