package Comserv::Util::FreshnessSource;

use strict;
use warnings;

# The I/O half of the freshness audit: read the rows, scan the doc pages, walk
# git once, and hand plain data to Comserv::Util::FreshnessAudit, which owns the
# verdict. Nothing in this file decides what is stale.
#
# Scope is the branch and its responsibilities (Shanta, 2026-11-09): the project
# ids that worktrees.json gives this checkout. A branch with no project_id runs
# unscoped and the report says so, rather than inventing an owner.

our $GIT_WINDOW_DAYS = 90;
our $CACHE_SECONDS   = 60;
our $MAX_TODOS       = 5000;

my $_cache;

sub _git {
    my ($dir, @args) = @_;
    return '' unless $dir && -d $dir;
    require IPC::Run3;
    my ($out, $err) = ('', '');
    eval { IPC::Run3::run3(['git', '-C', $dir, @args], \undef, \$out, \$err); 1 };
    return $out // '';
}

# Parsed META of every served doc page: path (repo-relative), project_id,
# last_updated. Only the head of each file is read; the fields live there.
sub doc_pages {
    my ($class, $app_root, $repo_root) = @_;
    my $dir = "$app_root/root/Documentation";
    return [] unless -d $dir;
    my @files;
    my @stack = ($dir);
    while (@stack) {
        my $d = pop @stack;
        opendir(my $dh, $d) or next;
        for my $e (readdir $dh) {
            next if $e eq '.' || $e eq '..';
            my $p = "$d/$e";
            if (-d $p) { push @stack, $p }
            elsif ($p =~ /\.tt$/) { push @files, $p }
        }
        closedir $dh;
    }
    my @pages;
    for my $f (sort @files) {
        next if $f =~ m{/changelog/} || $f =~ m{/AuditReports/};
        open my $fh, '<', $f or next;
        my $head = '';
        read($fh, $head, 4096);
        close $fh;
        (my $rel = $f) =~ s{^\Q$repo_root\E/+}{};
        my ($pid) = $head =~ /project_id\s*=\s*"?\s*(\d+)/;
        my ($upd) = $head =~ /last_updated\s*=\s*"([^"]+)"/;
        push @pages, { path => $rel, project_id => ($pid ? 0 + $pid : undef), last_updated => $upd };
    }
    return \@pages;
}

# One git walk for the whole window. worktree-standard paths only: docs, lib and
# the app root's templates/JS - that is what a plan page can fall behind.
sub git_touch {
    my ($class, $repo_root, $days) = @_;
    $days //= $GIT_WINDOW_DAYS;
    my $text = _git($repo_root, 'log', "--format=%ct", '--name-only',
                    "--since=$days.days", '--',
                    'Comserv/root/Documentation', 'Comserv/lib', 'Comserv/root');
    require Comserv::Util::FreshnessAudit;
    return Comserv::Util::FreshnessAudit->git_touch_map($text);
}

sub current_branch {
    my ($class, $repo_root) = @_;
    my $b = _git($repo_root, 'rev-parse', '--abbrev-ref', 'HEAD');
    $b =~ s/\s+//g;
    return length $b ? $b : 'unknown';
}

# Project ids this branch answers for, from the worktree registry.
#
# A feature branch declares one project_id and is audited only against it.
# `scope: "all"` is the integration branch (main): it is the merge point for
# every branch and the proving ground before the production build, so it is
# responsible for every project - not just the one its audit todos are filed to.
sub scope_for_branch {
    my ($class, $branch) = @_;
    require Comserv::Util::Git;
    my $cfg = eval { Comserv::Util::Git->_worktree_config() } || {};
    my $b = $cfg->{branches}{$branch} // {};
    if (defined $b->{scope} && $b->{scope} eq 'all') {
        return { project_ids => [], declared => 1, aggregate => 1, branch => $branch,
                 filed_under => $b->{project_id} };
    }
    my @ids = grep { defined && /^\d+$/ } ($b->{project_id});
    return { project_ids => \@ids, declared => scalar(@ids) ? 1 : 0, branch => $branch };
}

# project_id -> owning branch, for routing a finding to the branch that owns it.
# A feature branch declares one project; main is the integration branch and owns
# only what no branch declares. Two branches pointing at one project id is drift
# (schema said 138, the same as planning) - the extra branch is listed under
# `also` so the check can point at it instead of silently picking one.
sub owner_map {
    my ($class) = @_;
    require Comserv::Util::Git;
    my $cfg = eval { Comserv::Util::Git->_worktree_config() } || {};
    my %map;
    for my $b (sort keys %{ $cfg->{branches} || {} }) {
        my $v = $cfg->{branches}{$b} || {};
        my $pid = $v->{project_id};
        next unless defined $pid && $pid =~ /^\d+$/;
        next if $b eq 'main';                    # main is the fallback, not an owner
        $pid = 0 + $pid;
        $map{$pid} ||= { branch => $b, project_id => $pid, label => $v->{label} // $b, also => [] };
        push @{ $map{$pid}{also} }, $b unless $map{$pid}{branch} eq $b;
    }
    return \%map;
}

# Where findings with no owning branch go: main, under Release Engineering.
sub routing_fallback {
    my ($class) = @_;
    require Comserv::Util::Git;
    my $cfg = eval { Comserv::Util::Git->_worktree_config() } || {};
    my $main = $cfg->{branches}{main} || {};
    return { branch => 'main', project_id => $main->{project_id} };
}

# Plain-data bundle for FreshnessAudit::collect. Cache is 60 s so a dashboard
# request cannot make the scan expensive; the cron path reuses it too.
sub build {
    my ($class, $c, %o) = @_;
    my $now = time;
    if ($_cache && !$o{refresh} && ($now - $_cache->{at}) < $CACHE_SECONDS) {
        return $_cache->{report};
    }

    my $repo_root  = $o{repo_root}  // _repo_root($c);
    my $app_root   = $o{app_root}   // "$repo_root/Comserv";
    my $branch     = $o{branch}     // $class->current_branch($repo_root);
    my $scope      = $class->scope_for_branch($branch);
    my $today      = $o{today}      // _today($c);

    my $schema = eval { $c->model('DBEncy') };
    my (@todos, @projects);
    if ($schema) {
        my $trs = eval { $schema->resultset('Todo') };
        if ($trs) {
            my $n = 0;
            my $it = $trs->search({}, { columns => [qw(record_id subject status project_id last_mod_date)] });
            while (my $r = $it->next) {
                last if ++$n > $MAX_TODOS;
                push @todos, {
                    record_id     => 0 + $r->record_id,
                    subject       => $r->subject,
                    status        => (defined $r->status ? '' . $r->status : ''),
                    project_id    => (defined $r->project_id ? 0 + $r->project_id : undef),
                    last_mod_date => $r->last_mod_date,
                };
            }
        }
        my $prs = eval { $schema->resultset('Project') };
        if ($prs) {
            my $it = $prs->search({}, { columns => [qw(id name status)] });
            while (my $p = $it->next) {
                push @projects, { id => 0 + $p->id, name => $p->name, status => $p->status };
            }
        }
    }

    require Comserv::Util::FreshnessAudit;
    require Comserv::Util::TodoLog;
    my %open;
    my $ws = eval { Comserv::Util::TodoLog->work_status($c) };
    for my $r (@{ ($ws && $ws->{active}) ? $ws->{active} : [] }) {
        next unless $r->{log_id};
        $open{ $r->{record_id} } = { log_id => $r->{log_id}, start_date => $r->{start_date},
                                     start_time => $r->{start_time} };
    }

    my $pages = $class->doc_pages($app_root, $repo_root);
    my $touch = $class->git_touch($repo_root);
    my %plan_pages;
    for my $p (@$pages) { $plan_pages{ $p->{project_id} }++ if $p->{project_id} }

    # Newest todo change per project, so a plan can be judged against its rows.
    my %proj_last;
    for my $t (@todos) {
        next unless defined $t->{project_id};
        my $e = Comserv::Util::FreshnessAudit->date_epoch($t->{last_mod_date}) or next;
        $proj_last{ $t->{project_id} } = $e
            if !defined $proj_last{ $t->{project_id} } || $e > $proj_last{ $t->{project_id} };
    }

    # Changed code surfaces inside the window, from the same git walk.
    my $cutoff = $now - $GIT_WINDOW_DAYS * 86400;
    my @changed = grep { $touch->{$_} >= $cutoff } keys %$touch;

    my $report = Comserv::Util::FreshnessAudit->collect(
        branch              => $branch,
        scope               => $scope,
        todos               => \@todos,
        projects            => \@projects,
        open_by_id          => \%open,
        pages               => $pages,
        plan_pages          => \%plan_pages,
        touch               => $touch,
        project_last_change => \%proj_last,
        changed_paths       => \@changed,
        today               => $today,
        stale_days          => $o{stale_days} // $Comserv::Util::FreshnessAudit::STALE_TODO_D,
        fresh_days          => $o{fresh_days} // $Comserv::Util::FreshnessAudit::STALE_DOC_D,
    );
    $report->{source} = {
        repo_root => $repo_root, pages => scalar @$pages,
        todos => scalar @todos, projects => scalar @projects,
        touched_paths => scalar keys %$touch, git_window_days => $GIT_WINDOW_DAYS,
        scope_declared => $scope->{declared},
    };
    # Routing data travels with the report so the caller (and the cron script)
    # files each finding against the branch that owns it, not against main.
    my $owners = $class->owner_map();
    $report->{owners}   = $owners;
    $report->{fallback} = $class->routing_fallback();
    $report->{drift}    = [ map { { project_id => $_, branch => $owners->{$_}{branch},
                                    also => $owners->{$_}{also} } }
                            grep { @{ $owners->{$_}{also} || [] } } keys %$owners ];

    $_cache = { at => $now, report => $report };
    return $report;
}

sub _repo_root {
    my ($c) = @_;
    my $root = eval { $c->path_to('..')->stringify };
    return $root if defined $root;
    require Comserv::Util::Git;
    return Comserv::Util::Git->repo_path($c) // '/home/shanta/PycharmProjects/comserv2';
}

sub _today {
    my ($c) = @_;
    my $t = eval { $c->stash->{AppTime} };
    return $t->{today} if $t && $t->{today};
    my @lt = localtime;
    return sprintf('%04d-%02d-%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3]);
}

1;
