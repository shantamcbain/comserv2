package Comserv::Util::FreshnessAudit;

use strict;
use warnings;

# Read-only staleness audit for one branch's own responsibilities.
#
# Everything here is a pure function over rows that the caller fetched (todo rows,
# project rows, doc pages, git touch times). No Catalyst, no DB handle, no git
# subprocess: the composition layer owns I/O, this file owns the rules, so the
# rules can be tested with fixed rows and a fixed "now".
#
# Scope rule (Shanta, 2026-11-09): a branch check only reports what that branch is
# responsible for - its own project ids, its own pages, its own todos. Rows outside
# the scope are counted as skipped, never listed as findings.
#
# Thresholds start loose so the existing backlog can be cleared, then tighten.
our $STALE_TODO_D    = 30;   # status 2 with no activity for this long is abandoned
our $STALE_PROJECT_D = 30;   # a project whose todos are all quiet this long is dormant
our $STALE_DOC_D     = 14;   # a plan behind its own project rows by this long is stale
our $TARGET_TODO_D   = 7;    # tighten to this once the backlog pass is done

# Raw statuses seen in the live table (2026-11-09). Numeric 1-5 is canonical;
# everything else is mapped here so those rows stop being invisible, and an
# unknown value is reported rather than guessed.
my %STATUS_MAP = (
    '1' => 1, '2' => 2, '3' => 3, '4' => 4, '5' => 5,
    'new'          => 1,
    'not-started'  => 1,
    'not started'  => 1,
    'open'         => 1,
    'task'         => 1,
    'requested'    => 1,
    'pending'      => 2,
    'in progress'  => 2,
    'in-progress'  => 2,
    'inprocess'    => 2,
    'in-process'   => 2,
    'started'      => 2,
    'done'         => 3,
    'completed'    => 3,
    'complete'     => 3,
    'closed'       => 3,
    'cancelled'    => 4,
    'canceled'     => 4,
);

# One raw value -> { code, raw, canonical, unknown }. Canonical means the stored
# value already is the number the checks compare against.
sub normalize_status {
    my ($class, $raw) = @_;
    $raw = defined $raw ? "$raw" : '';
    (my $key = $raw) =~ s/^\s+|\s+$//g;
    $key = lc $key;
    my $code = $STATUS_MAP{$key};
    return {
        raw       => $raw,
        code      => $code,
        canonical => (defined $code && $raw =~ /^\s*[1-5]\s*$/) ? 1 : 0,
        unknown   => defined $code ? 0 : 1,
    };
}

sub _days_since {
    my ($ymd, $today) = @_;
    return undef unless defined $ymd && $ymd =~ /^(\d{4})-(\d{2})-(\d{2})/;
    my ($y, $m, $d) = ($1, $2, $3);
    my ($ty, $tm, $td) = ($today // '') =~ /^(\d{4})-(\d{2})-(\d{2})/;
    return undef unless defined $ty;
    require Time::Local;
    my $a = eval { Time::Local::timegm(0, 0, 12, $d,  $m  - 1, $y)  };
    my $b = eval { Time::Local::timegm(0, 0, 12, $td, $tm - 1, $ty) };
    return undef unless defined $a && defined $b;
    return int(($b - $a) / 86400);
}

sub _in_scope {
    my ($row, $scope) = @_;
    # The integration branch is declared responsible for every project.
    return 1 if $scope && $scope->{aggregate};
    return 1 unless $scope && ref $scope->{project_ids} eq 'ARRAY' && @{ $scope->{project_ids} };
    my %want = map { $_ => 1 } grep { defined } @{ $scope->{project_ids} };
    my $pid = $row->{project_id};
    return 0 unless defined $pid;
    return $want{$pid} ? 1 : 0;
}

# Todo staleness. Rows are the raw /api/todos rows (status may be any string).
# open_by_id maps record_id => { start_date, start_time, log_id } for open clocks.
sub todo_staleness {
    my ($class, %a) = @_;
    my $rows   = $a{rows} || [];
    my $open   = $a{open_by_id} || {};
    my $today  = $a{today} || '';
    my $stale  = defined $a{stale_days} ? $a{stale_days} : $STALE_TODO_D;
    my $scope  = $a{scope};
    my (@out, $skipped);
    for my $r (@$rows) {
        next unless $r && ref $r eq 'HASH';
        # The audit's own todos must never count as stale work: they are the
        # queue this report produces.
        next if ($r->{subject} // '') =~ /^Stale (?:todos|projects|documentation) on /;
        unless (_in_scope($r, $scope)) { $skipped++; next; }
        my $st  = $class->normalize_status($r->{status});
        my $id  = $r->{record_id};
        my $age = _days_since($r->{last_mod_date}, $today);

        if ($st->{unknown}) {
            push @out, {
                record_id => $id, project_id => $r->{project_id},
                subject => $r->{subject}, status_raw => $st->{raw},
                reason => "unmapped status '$st->{raw}'", action => 'normalize',
            };
            next;
        }
        # A status stored as a word ('Pending', 'NEW', 'open') is invisible to every
        # numeric check, so it is its own finding even when it maps cleanly.
        if (!$st->{canonical}) {
            push @out, {
                record_id => $id, project_id => $r->{project_id},
                subject => $r->{subject}, status_raw => $st->{raw}, status_code => $st->{code},
                reason => "non-canonical status '$st->{raw}' (means $st->{code})",
                action => 'normalize',
            };
        }
        if ($st->{code} == 5) {
            my $clock = $open->{$id};
            if (!$clock) {
                push @out, {
                    record_id => $id, project_id => $r->{project_id},
                    subject => $r->{subject}, status_raw => $st->{raw},
                    reason => 'status 5 with no open log', action => 'close_log',
                };
            } else {
                push @out, {
                    record_id => $id, project_id => $r->{project_id},
                    subject => $r->{subject}, status_raw => $st->{raw},
                    start_date => $clock->{start_date}, start_time => $clock->{start_time},
                    reason => 'open clock needs a real end time', action => 'close_log_with_duration',
                };
            }
            next;
        }
        if ($st->{code} == 2 && defined $age && $age > $stale) {
            push @out, {
                record_id => $id, project_id => $r->{project_id},
                subject => $r->{subject}, status_raw => $st->{raw},
                age_days => $age,
                reason => "in progress ${age}d with no activity (over ${stale}d)", action => 'decide',
            };
        }
    }
    return {
        rows => \@out,
        counts => {
            findings => scalar @out,
            unmapped => scalar(grep { $_->{action} eq 'normalize' } @out),
            dangling_clocks => scalar(grep { $_->{action} eq 'close_log' } @out),
            open_clocks => scalar(grep { $_->{action} eq 'close_log_with_duration' } @out),
            abandoned_starts => scalar(grep { $_->{action} eq 'decide' } @out),
        },
        skipped_out_of_scope => ($skipped // 0),
        thresholds => { stale_days => $stale },
    };
}

# Project staleness. projects are /api/projects rows (status is a word),
# todos the same rows todo_staleness used, plan_pages a project_id -> page count.
sub project_staleness {
    my ($class, %a) = @_;
    my $projects = $a{projects} || [];
    my $todos    = $a{todos} || [];
    my $pages    = $a{plan_pages} || {};
    my $today    = $a{today} || '';
    my $stale    = defined $a{stale_days} ? $a{stale_days} : $STALE_PROJECT_D;

    my %by_project;
    for my $t (@$todos) {
        next unless $t && ref $t eq 'HASH' && defined $t->{project_id};
        push @{ $by_project{ $t->{project_id} } }, $t;
    }

    my @out;
    for my $p (@$projects) {
        next unless $p && ref $p eq 'HASH';
        my $id     = $p->{id} // $p->{project_id};
        my $status = $p->{status} // '';
        next if $status =~ /^(done|complete|completed|closed|cancelled|canceled)$/i;
        my $mine = $by_project{$id} || [];
        my $newest;
        for my $t (@$mine) {
            my $age = _days_since($t->{last_mod_date}, $today);
            next unless defined $age;
            $newest = $age if !defined $newest || $age < $newest;
        }
        my @open = grep { my $c = $class->normalize_status($_->{status})->{code};
                          defined $c && ($c == 1 || $c == 2 || $c == 5) } @$mine;
        my $row = { project_id => $id, name => $p->{name}, status => $status,
                    todos => scalar @$mine, open_todos => scalar @open };
        if (@$mine && !@open) {
            push @out, { %$row, reason => 'every todo is done or cancelled',
                         action => 'close_project' };
        } elsif (!@$mine || (defined $newest && $newest > $stale)) {
            push @out, { %$row, reason => @$mine
                            ? "no todo activity in ${newest}d (over ${stale}d)"
                            : 'no todos at all',
                         action => 'dormant' };
        }
        if (!$pages->{$id}) {
            push @out, { %$row, reason => 'no documentation page carries this project_id',
                         action => 'no_plan_page' };
        }
    }
    return {
        rows => \@out,
        counts => {
            findings => scalar @out,
            close_project => scalar(grep { $_->{action} eq 'close_project' } @out),
            dormant => scalar(grep { $_->{action} eq 'dormant' } @out),
            no_plan_page => scalar(grep { $_->{action} eq 'no_plan_page' } @out),
        },
        thresholds => { stale_days => $stale },
    };
}

# Parse `git log --format=%ct --name-only` output into path -> epoch of the
# newest commit that touched the path. Newest comes first, so the first
# occurrence wins. Kept text-in, not git-out, so the rule is testable.
sub git_touch_map {
    my ($class, $text) = @_;
    my %map;
    my $epoch;
    for my $line (split /\n/, $text // '') {
        if ($line =~ /^\s*(\d{9,})\s*$/) { $epoch = $1 + 0; next; }
        next unless defined $epoch && $line =~ /\S/;
        next if $line =~ /^\s/;             # indented log bodies are not paths
        $map{$line} = $epoch unless exists $map{$line};
    }
    return \%map;
}

sub _date_epoch {
    my ($ymd) = @_;
    return undef unless defined $ymd && $ymd =~ /^(\d{4})-(\d{2})-(\d{2})/;
    require Time::Local;
    return eval { Time::Local::timegm(0, 0, 0, $3, $2 - 1, $1) };
}

# Public alias: the composition layer converts todo dates to epochs with it.
sub date_epoch { return _date_epoch($_[1]) }

# Documentation freshness, from git touch times rather than the META field
# (535 of 596 pages have no parseable last_updated, so the field cannot be the
# signal - it is just another thing to fix).
#   pages              => [{ path => 'Comserv/root/Documentation/X.tt',
#                            project_id => 238|undef, last_updated => '...' }]
#   touch              => { path => epoch }        (git_touch_map)
#   project_last_change=> { project_id => epoch }  (newest todo change per project)
sub doc_freshness {
    my ($class, %a) = @_;
    my $pages  = $a{pages} || [];
    my $touch  = $a{touch} || {};
    my $proj   = $a{project_last_change} || {};
    my $stale  = defined $a{stale_days} ? $a{stale_days} : $STALE_DOC_D;
    my $window = $stale * 86400;

    my @out;
    for my $p (@$pages) {
        next unless $p && ref $p eq 'HASH';
        my $path  = $p->{path} or next;
        my $t     = $touch->{$path};
        next unless defined $t;

        my $claim = _date_epoch($p->{last_updated});
        if (defined $claim && $claim < $t) {
            push @out, {
                doc => $path, action => 'fix_meta',
                reason => 'META last_updated is older than the page\'s last commit',
                claimed => $p->{last_updated}, committed => $t,
            };
        }
        my $pid = $p->{project_id};
        if (defined $pid && $proj->{$pid} && ($proj->{$pid} - $t) > $window) {
            push @out, {
                doc => $path, project_id => $pid, action => 'update_plan',
                behind_days => int(($proj->{$pid} - $t) / 86400),
                reason => 'project rows moved after the plan page last changed',
            };
        }
    }
    return {
        rows => \@out,
        counts => {
            findings => scalar @out,
            fix_meta => scalar(grep { $_->{action} eq 'fix_meta' } @out),
            update_plan => scalar(grep { $_->{action} eq 'update_plan' } @out),
        },
        thresholds => { stale_days => $stale },
    };
}

# A code surface that changed with no page naming it. Reports "no page found",
# never "this page is wrong": the match is by basename, case-insensitive.
sub undocumented_surfaces {
    my ($class, %a) = @_;
    my $changed = $a{changed_paths} || [];
    my $pages   = $a{pages} || [];
    my %named;
    for my $p (@$pages) {
        my $path = ref $p ? ($p->{path} // '') : "$p";
        (my $base = $path) =~ s{.*/}{};
        $base =~ s{\.tt$}{};
        $named{lc $base} = 1 if length $base;
    }
    my (@out, %seen);
    for my $c (@$changed) {
        next unless $c =~ m{^Comserv/lib/Comserv/(?:Controller|Util)/(.+?)\.pm$};
        my $name = $1;
        next if $seen{lc $name}++;
        (my $leaf = $name) =~ s{.*/}{};
        # Substring match: a page called GitDashboard documents Controller/Git.pm.
        my $leaf_lc = lc $leaf;
        next if grep { index($_, $leaf_lc) >= 0 } keys %named;
        push @out, { surface => $c, action => 'write_doc',
                     reason => "no documentation page named '$leaf'" };
    }
    return { rows => \@out, counts => { findings => scalar @out } };
}

# Compose the four rule sets into the section the workday check carries.
# The caller owns I/O (DB rows, file scan, git walk); this method owns the
# verdict, so the whole audit is reproducible from plain data in a test.
sub collect {
    my ($class, %a) = @_;
    my $todos = $class->todo_staleness(
        rows => $a{todos}, open_by_id => $a{open_by_id}, today => $a{today},
        stale_days => $a{stale_days}, scope => $a{scope},
    );
    my $proj = $class->project_staleness(
        projects => $a{projects}, todos => $a{todos}, plan_pages => $a{plan_pages},
        today => $a{today}, stale_days => $a{stale_days},
    );
    my $docs = $class->doc_freshness(
        pages => $a{pages}, touch => $a{touch},
        project_last_change => $a{project_last_change}, stale_days => $a{fresh_days},
    );
    my $undoc = $class->undocumented_surfaces(
        changed_paths => $a{changed_paths}, pages => $a{pages},
    );
    my $counts = {
        %{ $todos->{counts} }, %{ $proj->{counts} }, %{ $docs->{counts} },
        undocumented => $undoc->{counts}{findings},
    };
    # Each section carries its own `findings`; the merged key must be the sum, not
    # whichever section merged last.
    $counts->{findings} = ($todos->{counts}{findings} // 0) + ($proj->{counts}{findings} // 0)
                        + ($docs->{counts}{findings} // 0) + ($undoc->{counts}{findings} // 0);
    return {
        success      => 1,
        scope        => $a{scope} || {},
        branch       => $a{branch},
        today_iso    => $a{today},
        todos        => $todos,
        projects     => $proj,
        docs         => $docs,
        undocumented => $undoc,
        counts       => $counts,
        totals       => { findings => $counts->{findings} },
    };
}

# Route findings to the branch that owns the work, which is how an organization
# handles portfolio hygiene: the team that owns the area gets the item, not the
# trunk. The integration branch (main) keeps only what nobody owns.
#
#   owner_map => { project_id => { branch => 'git', project_id => 238 } }
#   fallback  => { branch => 'main', project_id => 311 }   (Release Engineering)
#
# Subjects carry no counts: a count that moves every 30 minutes would file a new
# todo on every run. The count and the evidence go in the description.
sub route_findings {
    my ($class, $report, %o) = @_;
    return [] unless $report && ref $report eq 'HASH';
    my $owner_map = $o{owner_map} || {};
    my $fallback  = $o{fallback}  || {
        branch     => $report->{branch} // 'branch',
        project_id => ($report->{scope} || {})->{filed_under},
    };

    my %bucket;
    my $owner_of = sub {
        my ($pid) = @_;
        if (defined $pid && $owner_map->{$pid}) {
            return ($owner_map->{$pid}{branch}, $owner_map->{$pid}{project_id});
        }
        return ($fallback->{branch}, $fallback->{project_id});
    };
    my $add = sub {
        my ($group, $rows, $pid_of) = @_;
        for my $r (@{ $rows || [] }) {
            my ($b, $p) = $owner_of->($pid_of->($r));
            my $k = "$b\0$group";
            push @{ $bucket{$k}{rows} }, $r;
            $bucket{$k}{branch}     = $b;
            $bucket{$k}{group}      = $group;
            $bucket{$k}{project_id} = $p if defined $p;
        }
    };
    $add->('todos',    ($report->{todos}    || {})->{rows}, sub { $_[0]{project_id} });
    $add->('projects', ($report->{projects} || {})->{rows}, sub { $_[0]{project_id} });
    $add->('docs',     ($report->{docs}     || {})->{rows}, sub { $_[0]{project_id} });
    # A code surface nobody documents has no project of its own; the trunk owns it.
    $add->('docs',     ($report->{undocumented} || {})->{rows}, sub { undef });

    my @plan;
    for my $k (sort keys %bucket) {
        my $b = $bucket{$k};
        my @r = @{ $b->{rows} };
        my $n = scalar @r;
        next unless $n;
        my ($subject, $head);
        if    ($b->{group} eq 'todos') {
            $subject = "Stale todos on $b->{branch}";
            $head = "Status 5: close the clock - unfinished goes to 2, finished uses done_with_log.\n"
                  . "The only log field corrected is the end time, to real or estimated time worked.\n";
        } elsif ($b->{group} eq 'projects') {
            $subject = "Stale projects on $b->{branch}";
            $head = "A project whose todos are all done should be closed; a quiet one should be revived or closed.\n";
        } else {
            $subject = "Stale documentation on $b->{branch}";
            $head = "Plans must match the code and their project rows; META last_updated fixes are mechanical.\n";
        }
        @r = @r[0 .. 24] if @r > 25;
        my $body = join '', map {
            my $what = $_->{record_id} ? "todo $_->{record_id}: $_->{subject}"
                     : $_->{doc}          ? $_->{doc}
                     : $_->{surface}      ? $_->{surface}
                     :                      ($_->{name} // $_->{project_id} // '?');
            "- [$_->{action}] $what ($_->{reason})\n"
        } @r;
        push @plan, {
            group      => $b->{group},
            branch     => $b->{branch},
            project_id => $b->{project_id},
            subject    => $subject,
            description => "Workday freshness audit, filed to the owning branch ($b->{branch}).\n"
                         . "$n findings as of $report->{today_iso}.\n$head\n$body",
        };
    }
    return \@plan;
}

# Back-compat thin wrapper: one plan for the branch that produced the report.
sub audit_todo_plan {
    my ($class, $report) = @_;
    return $class->route_findings($report);
}

1;
