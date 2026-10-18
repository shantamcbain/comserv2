package Comserv::Util::AI::StalePreflight;

# Stale-server preflight (AISYSTEM plan §5g). Before AI debugging, compare a
# serving process's start time with the newest code-file mtime and the latest
# commit in its worktree. A process older than either is STALE: it is not
# running the code on disk. Read-only: /proc, `ss -ltnpH`, `git log`. It never
# signals, restarts or connects to the target. Works for any port/worktree
# pair (app ports, the Hermes dashboard, the 3d worktree).
#
# First draft by Hermes (deepseek-v4-pro, session 20261001_090927_a9624f);
# reviewed and corrected (port->pid for any process, directory pruning,
# oldest-pid selection for cmdline targets, default targets).

use strict;
use warnings;
use POSIX ();
use File::Find ();
use File::Spec ();
use DateTime;

our $VERSION = '0.2';

our @DEFAULT_DIRS = qw(lib script);
# Code a running server only picks up on restart. Templates (.tt/.inc), CSS
# and JS are read per request, so they never make a server STALE.
our @DEFAULT_EXTS = qw(pm conf yml yaml py);   # same set the Catalyst -r restarter watches (+ py for Hermes)
# Directory names (any depth) or relative paths that are never code.
our @PRUNE = qw(.git node_modules tmp logs data static/ai __pycache__ .venv venv session);

sub _run {
    my (@cmd) = @_;
    my $pid = open(my $fh, '-|') // return;
    if (!$pid) {
        open STDERR, '>', File::Spec->devnull;
        exec { $cmd[0] } @cmd or POSIX::_exit(127);
    }
    local $/;
    my $out = <$fh>;
    close $fh;
    return $out;
}

# pid_for_port($port) -> pid of the LISTEN socket owner (any process name).
sub pid_for_port {
    my ($port) = @_;
    return undef unless defined $port && $port =~ /^\d+$/;
    my $out = _run('ss', '-ltnpH') // '';
    for my $line (split /\n/, $out) {
        my @f = split /\s+/, $line;
        next unless @f >= 4 && $f[3] =~ /:(\d+)$/ && $1 == $port;
        return 0 + $1 if $line =~ /pid=(\d+)/;
    }
    return undef;
}

sub pids_by_cmdline {
    my ($re) = @_;
    my @pids;
    opendir my $dh, '/proc' or return;
    for my $pid (grep { /^\d+$/ } readdir $dh) {
        next if $pid == $$;
        open my $fh, '<', "/proc/$pid/cmdline" or next;
        my $raw = do { local $/; <$fh> } // '';
        close $fh;
        next unless length $raw;
        push @pids, 0 + $pid if join(' ', split /\0/, $raw) =~ $re;
    }
    closedir $dh;
    return @pids;
}

sub _btime {
    local $/ = "\n";
    open my $fh, '<', '/proc/stat' or return;
    while (my $l = <$fh>) { return 0 + $1 if $l =~ /^btime\s+(\d+)/ }
    return;
}

sub proc_info {
    my ($pid) = @_;
    return undef unless defined $pid && $pid =~ /^\d+$/ && -d "/proc/$pid";
    my %i = (pid => 0 + $pid);
    if (open my $fh, '<', "/proc/$pid/cmdline") {
        local $/;
        $i{cmd} = join ' ', split /\0/, (<$fh> // '');
    }
    $i{cwd} = readlink("/proc/$pid/cwd");
    if (open my $fh, '<', "/proc/$pid/stat") {
        local $/;
        my $stat = <$fh> // '';
        my $rp = rindex $stat, ')';           # comm may contain spaces / ')'
        if ($rp > 0) {
            my @f = split ' ', substr($stat, $rp + 2);   # f[0] = field 3 (state)
            my $clk = POSIX::sysconf(POSIX::_SC_CLK_TCK()) || 100;
            my $bt  = _btime();
            $i{start_epoch} = $bt + int($f[19] / $clk) if defined $bt && defined $f[19];
        }
    }
    return \%i;
}

sub git_info {
    my ($dir) = @_;
    return {} unless defined $dir && -d $dir;
    my %g;
    my $t = _run('git', '-C', $dir, 'rev-parse', '--show-toplevel');
    return {} unless defined $t && length $t;
    chomp($g{toplevel} = $t);
    chomp($g{branch} = _run('git', '-C', $dir, 'rev-parse', '--abbrev-ref', 'HEAD') // '');
    my $h = _run('git', '-C', $dir, 'log', '-1', '--format=%h%x09%ct%x09%s') // '';
    if ($h =~ /^(\S+)\t(\d+)\t(.*)/) { @g{qw(head_short commit_epoch subject)} = ($1, 0 + $2, $3) }
    return \%g;
}

sub newest_file {
    my ($base, %o) = @_;
    my @dirs = @{ $o{dirs} || \@DEFAULT_DIRS };
    my %ext  = map { $_ => 1 } @{ $o{exts} || \@DEFAULT_EXTS };
    my %name = map { $_ => 1 } grep { !m{/} } @PRUNE;
    my @rel  = grep { m{/} } @PRUNE;
    my ($best, $best_m, $n) = (undef, undef, 0);
    my $wanted = sub {
        my $p = $File::Find::name;
        if (-d $_) {
            return if $p eq $File::Find::topdir;
            my $r = substr($p, length($base) + 1);
            if ($name{$_} || grep { $r eq $_ || $r =~ m{(?:^|/)\Q$_\E$} } @rel) {
                $File::Find::prune = 1;
            }
            return;
        }
        return unless -f _ && /\.([^.\/]+)$/ && $ext{$1};
        my $m = (lstat $_)[9] // return;
        $n++;
        ($best, $best_m) = ($p, $m) if !defined $best_m || $m > $best_m;
    };
    for my $d (@dirs) {
        my $path = $d =~ m{^/} ? $d : ($d eq '.' ? $base : "$base/$d");
        File::Find::find({ wanted => $wanted, no_chdir => 0 }, $path) if -d $path;
    }
    return { path => $best, mtime_epoch => $best_m, scanned => $n };
}

# evaluate(proc_start_epoch, newest_mtime_epoch, newest_file_path, commit_epoch, grace_s)
sub evaluate {
    my (%a) = @_;
    my $g = $a{grace_s} // 2;
    return { status => 'DOWN', reasons => ['no serving process found'] } unless defined $a{proc_start_epoch};
    my @r;
    push @r, 'file newer than process: ' . ($a{newest_file_path} // '(unknown)')
        if defined $a{newest_mtime_epoch} && $a{newest_mtime_epoch} > $a{proc_start_epoch} + $g;
    my $commit_newer = defined $a{commit_epoch} && $a{commit_epoch} > $a{proc_start_epoch} + $g;
    # A checkout/merge rewrites the files it changes, so a newer commit with
    # every code file still older than the process changed no restart-needing
    # code (docs, templates, data): note it, but the server is not stale.
    if ($commit_newer && !@r && defined $a{newest_mtime_epoch}) {
        return { status => 'OK', reasons => [ 'commit newer than process, but no code file changed since start (templates/docs only)' ] };
    }
    push @r, 'commit newer than process' if $commit_newer;
    return { status => (@r ? 'STALE' : 'OK'), reasons => \@r };
}

sub pt {
    my ($e) = @_;
    return undef unless defined $e;
    return DateTime->from_epoch(epoch => $e, time_zone => 'America/Vancouver')->strftime('%Y-%m-%d %H:%M:%S PT');
}

# check(port|pid|cmdline_re, worktree?, label?, dirs?, exts?, grace_s?)
sub check {
    my (%a) = @_;
    my ($pid, $n_pids);
    if    (defined $a{port}) { $pid = pid_for_port($a{port}) }
    elsif (defined $a{pid})  { $pid = $a{pid} }
    elsif ($a{cmdline_re}) {
        # Several processes (e.g. Hermes CLIs): judge the OLDEST - it is the
        # one most likely to be running stale code.
        my @p = map { [ $_, (proc_info($_) || {})->{start_epoch} // 9e9 ] } pids_by_cmdline($a{cmdline_re});
        @p = sort { $a->[1] <=> $b->[1] } @p;
        $n_pids = @p;
        $pid = @p ? $p[0][0] : undef;
    }
    my $info = $pid ? proc_info($pid) : undef;
    my $cwd  = $info ? $info->{cwd} : undef;
    my $wt   = $a{worktree};
    $wt = (git_info($cwd)->{toplevel} || $cwd) if !defined $wt && $cwd;
    my $gi = $wt ? git_info($wt) : {};
    # Scan the app dir the process runs in when it sits inside the worktree
    # (the Comserv app lives one level below the git toplevel).
    my $scan = $a{scan_root}
        // (($cwd && $wt && index("$cwd/", "$wt/") == 0 && -d "$cwd/lib") ? $cwd : $wt);
    my $nf = $scan ? newest_file($scan, ($a{dirs} ? (dirs => $a{dirs}) : ()), ($a{exts} ? (exts => $a{exts}) : ())) : {};
    my $ev = evaluate(proc_start_epoch => ($info ? $info->{start_epoch} : undef),
        newest_mtime_epoch => $nf->{mtime_epoch}, newest_file_path => $nf->{path},
        commit_epoch => $gi->{commit_epoch}, grace_s => $a{grace_s});
    return {
        label => $a{label} // (defined $a{port} ? ":$a{port}" : 'process'),
        port => $a{port}, pid => $pid, (defined $n_pids ? (matching_pids => $n_pids) : ()),
        cmd => ($info ? $info->{cmd} : undef), cwd => $cwd,
        worktree => $wt, scan_root => $scan, branch => $gi->{branch}, head_short => $gi->{head_short}, subject => $gi->{subject},
        proc_start_epoch => ($info ? $info->{start_epoch} : undef),
        proc_start_pt    => pt($info ? $info->{start_epoch} : undef),
        newest_file => $nf->{path}, newest_mtime_epoch => $nf->{mtime_epoch}, newest_mtime_pt => pt($nf->{mtime_epoch}),
        files_scanned => $nf->{scanned},
        commit_epoch => $gi->{commit_epoch}, commit_pt => pt($gi->{commit_epoch}),
        status => $ev->{status}, reasons => $ev->{reasons}, checked_pt => pt(time),
        ($a{note} ? (note => $a{note}) : ()),
    };
}

sub default_targets {
    my (%o) = @_;
    return @{ $o{targets} } if $o{targets};
    my $home = $ENV{HOME} || '/home/shanta';
    return (
        { port => 4006, label => 'aisystem :4006 (app, AI Chat, AI Editor)' },
        { port => 3001, label => 'main :3001 (app, AI Chat, AI Editor)' },
        { port => 4003, label => '3d :4003', note => 'read-only /proc check; never touched' },
        { port => 9119, label => 'Hermes UI :9119', worktree => "$home/.hermes/hermes-agent",
          dirs => [qw(hermes_cli agent gateway)], exts => [qw(py)] },
        { cmdline_re => qr{(?:^|/)hermes(?:\s|$)|hermes_cli|\.hermes/tools/python\S*/bin/python3 -I -c}, label => 'Hermes CLI (oldest running)',
          worktree => "$home/.hermes/hermes-agent", dirs => [qw(hermes_cli agent gateway)], exts => [qw(py)] },
    );
}

sub check_all {
    my (%o) = @_;
    my @out;
    for my $t (default_targets(%o)) {
        my $r = eval { check(%$t) };
        push @out, $r || { label => $t->{label}, status => 'UNKNOWN', reasons => ["check failed: $@"] };
    }
    return \@out;
}

1;

__END__

=head1 NAME

Comserv::Util::AI::StalePreflight - is the serving process running the code on disk?

=head1 SYNOPSIS

  my $r = Comserv::Util::AI::StalePreflight::check(port => 4006);
  my $r = Comserv::Util::AI::StalePreflight::check(port => 4003,
              worktree => '/home/shanta/.comserv/worktrees/3d/Comserv');
  my $all = Comserv::Util::AI::StalePreflight::check_all();
  # CLI: script/stale_preflight.pl --all | --port N [--worktree DIR] [--json]

=head1 RETURN SHAPE

  { label, port, pid, matching_pids?, cmd, cwd, worktree, branch, head_short, subject,
    proc_start_epoch, proc_start_pt, newest_file, newest_mtime_epoch, newest_mtime_pt,
    files_scanned, commit_epoch, commit_pt, status => OK|STALE|DOWN|UNKNOWN,
    reasons => [...], checked_pt, note? }

Times are America/Vancouver ("... PT"). With C<-r> auto-reload the listening
child restarts on save, so its start time is the one compared.

=cut
