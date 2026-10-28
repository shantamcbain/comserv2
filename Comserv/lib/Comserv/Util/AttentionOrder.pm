package Comserv::Util::AttentionOrder;

use strict;
use warnings;
use POSIX ();
use Comserv::Util::Logging;
use Comserv::Util::Git;
use JSON qw(decode_json);

=head1 NAME

Comserv::Util::AttentionOrder - surface branches and projects that need attention

=head1 WHY

The planning Focus Queue ranks individual todos, but it does not answer the higher-level
question: which branch or project has been left behind? This module computes three
attention lists used by /planning/daily above the Focus Queue:

=over 4

=item * Branch attention — worktrees behind main or holding unique unmerged work

=item * Project attention — projects with open work but no recent activity, or blocking other projects

=item * Stale review queue — open todos untouched for 180+ days, ready for close/suspend/keep

=back

All three are read-only. Any close/suspend action is performed by the user through the
normal todo UI.

=cut

use constant STALE_90_DAYS  => 90;
use constant STALE_180_DAYS => 180;

my $_wt_config;
my $_wt_config_mtime;

=head2 _logging

Lazy logger instance.

=cut

sub _logging {
    return Comserv::Util::Logging->instance;
}

=head2 new

Simple constructor so the module can be used as an object or via class methods.

=cut

sub new {
    my ($class) = @_;
    return bless {}, $class;
}

=head2 _worktree_config

Read root/config/worktrees.json once, with mtime-based revalidation.

=cut

sub _worktree_config {
    my $file = __FILE__;
    $file =~ s{lib/Comserv/Util/AttentionOrder\.pm$}{root/config/worktrees.json};
    my $mtime = (stat($file))[9];
    if ($_wt_config && defined $_wt_config_mtime && defined $mtime
            && $mtime == $_wt_config_mtime && -f $file) {
        return $_wt_config;
    }
    $_wt_config = { branches => {}, port_start => 4000 };
    if (-f $file) {
        eval {
            my $raw = do { local $/; open my $fh, '<', $file or die $!; <$fh> };
            my $data = decode_json($raw);
            $_wt_config = $data if ref $data eq 'HASH';
        };
        if ($@) {
            _logging()->log_with_details(undef, 'error', __FILE__, __LINE__,
                '_worktree_config', "Failed to read $file: $@");
        }
    }
    $_wt_config_mtime = $mtime;
    return $_wt_config;
}

=head2 _now_epoch_day

Return epoch for the start of today (UTC).

=cut

sub _now_epoch_day {
    my @now = gmtime(time());
    return POSIX::mktime(0, 0, 0, $now[3], $now[4], $now[5]);
}

=head2 _parse_ymd_epoch

Parse a 'YYYY-MM-DD ...' string to epoch at midnight UTC. Returns undef on failure.

=cut

sub _parse_ymd_epoch {
    my ($str) = @_;
    return undef unless defined $str && $str =~ /^(\d{4})-(\d{2})-(\d{2})/;
    return POSIX::mktime(0, 0, 0, $3, $2 - 1, $1 - 1900);
}

=head2 _activity_date

Best-effort "real activity" date for a todo. Reschedule bulk updates do not count
as real activity.

=cut

sub _activity_date {
    my ($row) = @_;
    my $activity = '';
    if (defined $row->{last_mod_by} && lc($row->{last_mod_by} // '') eq 'reschedule') {
        $activity = $row->{date_time_posted} || $row->{start_date} || $row->{last_mod_date} || '';
    }
    else {
        $activity = $row->{last_mod_date} || $row->{date_time_posted} || $row->{start_date} || '';
    }
    return $activity;
}

=head2 branch_attention($c)

Return an arrayref of branch attention rows. Each row:

  {
    name            => branch name,
    port            => configured port,
    url             => configured url,
    label           => configured label,
    path            => resolved worktree path or undef,
    exists          => 1/0,
    behind_main     => integer,
    ahead_main      => integer (unique commits),
    unique_files    => integer,
    last_commit     => 'YYYY-MM-DD',
    needs_attention => 1/0,
    attention_reason=> 'behind main' | 'unique work' | 'behind + unique' | 'current',
  }

A branch needs attention when it is behind local main OR has unique unmerged work,
per the 2026-10-26 decision on todo #2616.

=cut

sub branch_attention {
    my ($self, $c) = @_;
    my $cfg = _worktree_config();
    my $branches = $cfg->{branches} // {};
    my $git = Comserv::Util::Git->new;
    my @out;

    for my $name (sort keys %$branches) {
        next if lc($name) eq 'main';
        my $bconf = $branches->{$name} // {};
        my $row = {
            name         => $name,
            port         => $bconf->{port} // 0,
            url          => $bconf->{url}  // '/planning/daily',
            label        => $bconf->{label} // $name,
            path         => undef,
            exists       => 0,
            behind_main  => 0,
            ahead_main   => 0,
            unique_files => 0,
            last_commit  => '',
            needs_attention => 0,
            attention_reason => 'current',
        };

        my $wt_path = eval { $git->worktree_checkout_path_for_branch($c, $name) };
        if ($@) {
            _logging()->log_with_details($c, 'warn', __FILE__, __LINE__,
                'branch_attention', "worktree resolve failed for '$name': $@");
        }
        if ($wt_path && -e "$wt_path/.git") {
            $row->{path}   = $wt_path;
            $row->{exists} = 1;

            my $main_check = $git->_run($c, 'rev-parse', '--verify', '--quiet', 'main',
                { repo => $wt_path });
            if ($main_check->{success} && length($main_check->{output} // '')) {
                my $lr = $git->_run($c, 'rev-list', '--left-right', '--count', 'main...HEAD',
                    { repo => $wt_path });
                if ($lr->{success} && $lr->{output} =~ /^(\d+)\s+(\d+)$/) {
                    $row->{behind_main} = $1 + 0;
                    $row->{ahead_main}  = $2 + 0;
                }
                else {
                    _logging()->log_with_details($c, 'warn', __FILE__, __LINE__,
                        'branch_attention', "rev-list failed for '$name': " . ($lr->{error} // ''));
                }

                my $dr = $git->_run($c, 'diff', '--stat', '--no-color', 'main...HEAD',
                    { repo => $wt_path });
                if (defined $dr->{output}) {
                    my @lines = split /\n/, $dr->{output};
                    # Last line of --stat is summary like "X files changed, Y insertions..."
                    # Count non-empty non-summary lines as changed files.
                    my $count = 0;
                    for my $l (@lines) {
                        next if $l =~ /^\s*$/;
                        next if $l =~ /files? changed/;
                        $count++;
                    }
                    $row->{unique_files} = $count;
                }
            }
            else {
                # No main ref in this checkout; compare against primary repo main if possible
                my $main_path = eval { $git->main_repo_path($c) };
                if ($main_path && -e "$main_path/.git") {
                    my $lr = $git->_run($c, 'rev-list', '--left-right', '--count',
                        "$main_path/main...HEAD", { repo => $wt_path });
                    if ($lr->{success} && $lr->{output} =~ /^(\d+)\s+(\d+)$/) {
                        $row->{behind_main} = $1 + 0;
                        $row->{ahead_main}  = $2 + 0;
                    }
                }
            }

            my $logr = $git->_run($c, 'log', '-1', '--format=%cd', '--date=short', 'HEAD',
                { repo => $wt_path });
            if ($logr->{success} && defined $logr->{output}) {
                my $d = $logr->{output};
                $d =~ s/\s+//g;
                $row->{last_commit} = $d if $d =~ /^\d{4}-\d{2}-\d{2}$/;
            }
        }

        if ($row->{behind_main} > 0 && $row->{ahead_main} > 0) {
            $row->{needs_attention} = 1;
            $row->{attention_reason} = 'behind + unique';
        }
        elsif ($row->{behind_main} > 0) {
            $row->{needs_attention} = 1;
            $row->{attention_reason} = 'behind main';
        }
        elsif ($row->{ahead_main} > 0 || $row->{unique_files} > 0) {
            $row->{needs_attention} = 1;
            $row->{attention_reason} = 'unique work';
        }

        push @out, $row;
    }

    @out = sort {
        $b->{behind_main} <=> $a->{behind_main}
        ||
        ($a->{last_commit} || '9999-99-99') cmp ($b->{last_commit} || '9999-99-99')
    } @out;

    return \@out;
}

=head2 project_attention($c)

Return projects that need attention: open work but newest real activity older than
90 days, OR blocking another in-process project. Each row:

  {
    project_id,
    project_name,
    project_code,
    parent_id,
    sitename,
    open_todos,
    newest_activity,
    stale_open_todos,
    blocks_projects => [ ids ],
    needs_attention => 1/0,
    attention_reason => 'stale' | 'blocking' | 'stale + blocking',
  }

=cut

sub project_attention {
    my ($self, $c) = @_;
    my $schema = $c->model('DBEncy');
    my $now_day = _now_epoch_day();

    my $todo_rs = $schema->resultset('Todo')->search({
        status => { -not_in => [3, 4, 'done', 'completed', 'closed', 'cancelled', 'canceled'] },
    });
    my %proj_stats;
    while (my $todo = $todo_rs->next) {
        my $pid = $todo->project_id;
        next unless defined $pid && $pid ne '';
        my $activity = _activity_date({
            last_mod_date    => $todo->last_mod_date,
            date_time_posted => $todo->date_time_posted,
            start_date       => $todo->start_date,
            last_mod_by      => $todo->last_mod_by,
        });
        $proj_stats{$pid}{open_todos}++;
        my $act_epoch = _parse_ymd_epoch($activity);
        if (defined $act_epoch) {
            if (!defined $proj_stats{$pid}{newest_epoch} || $act_epoch > $proj_stats{$pid}{newest_epoch}) {
                $proj_stats{$pid}{newest_epoch} = $act_epoch;
                $proj_stats{$pid}{newest_activity} = $activity;
            }
            my $stale_days = int(($now_day - $act_epoch) / 86400);
            if ($stale_days > STALE_180_DAYS) {
                $proj_stats{$pid}{stale_open_todos}++;
            }
        }
    }

    # Cross-blocker info: projects whose open todos are marked is_blocking and
    # block another project. Reuse the same logic Planning.pm uses.
    my %cross_blocker_projects;
    my %pid2name;
    eval {
        my @dep_rows = $c->model('DBEncy')->resultset('ProjectDependency')->search(
            { status => 'active', dependency_type => 'blocks' },
            { columns => [qw(depends_on_id project_id)] }
        )->all;
        my %ids_needed;
        for my $dr (@dep_rows) {
            next unless Comserv::Util::ProjectDependencies::cross_project_block_still_active($c, $dr);
            push @{ $cross_blocker_projects{$dr->depends_on_id} }, $dr->project_id;
            $ids_needed{$dr->project_id}    = 1;
            $ids_needed{$dr->depends_on_id} = 1;
        }
        if (%ids_needed) {
            my @prows = $c->model('DBEncy')->resultset('Project')->search(
                { id => { -in => [keys %ids_needed] } },
                { columns => [qw(id name)] }
            )->all;
            %pid2name = map { $_->id => $_->name } @prows;
        }
    };
    if ($@) {
        _logging()->log_with_details($c, 'warn', __FILE__, __LINE__,
            'project_attention', "Could not build cross-blocker map: $@");
    }

    my @out;
    for my $pid (sort { $a <=> $b } keys %proj_stats) {
        my $project = eval { $schema->resultset('Project')->find($pid) };
        next unless $project;
        my $stats = $proj_stats{$pid};
        my $newest_epoch = $stats->{newest_epoch};
        my $stale_days = (defined $newest_epoch)
            ? int(($now_day - $newest_epoch) / 86400)
            : undef;
        my $is_stale = (defined $stale_days && $stale_days > STALE_90_DAYS) ? 1 : 0;
        my $blocks = $cross_blocker_projects{$pid} // [];
        my $blocks_named = [ map { $pid2name{$_} || "Project #$_" } @$blocks ];
        my $is_blocking = (ref $blocks eq 'ARRAY' && @$blocks) ? 1 : 0;
        next unless $is_stale || $is_blocking;

        my $reason = '';
        if ($is_stale && $is_blocking) { $reason = 'stale + blocking'; }
        elsif ($is_stale)              { $reason = 'stale'; }
        else                           { $reason = 'blocking'; }

        push @out, {
            project_id       => $pid,
            project_name     => $project->name // '',
            project_code     => $project->project_code // '',
            parent_id        => $project->parent_id // '',
            sitename         => $project->sitename // '',
            open_todos       => $stats->{open_todos} // 0,
            newest_activity  => $stats->{newest_activity} // '',
            stale_open_todos => $stats->{stale_open_todos} // 0,
            blocks_projects  => $blocks,
            blocks_names     => $blocks_named,
            needs_attention  => 1,
            attention_reason => $reason,
            stale_days       => $stale_days,
        };
    }

    return \@out;
}

=head2 stale_review_queue($c)

Return open/new todos untouched for 180+ days, with a suggested triage class:

=over 4

=item done-not-closed — text suggests the work is complete

=item abandoned — text suggests it was superseded or the plan changed

=item still-valid — default

=back

=cut

sub stale_review_queue {
    my ($self, $c) = @_;
    my $schema = $c->model('DBEncy');
    my $now_day = _now_epoch_day();

    my $rs = $schema->resultset('Todo')->search({
        status => { -in => [1, 'NEW', 'open', 2, 'In-Process', 'in progress'] },
    });

    my @out;
    while (my $todo = $rs->next) {
        my $activity = _activity_date({
            last_mod_date    => $todo->last_mod_date,
            date_time_posted => $todo->date_time_posted,
            start_date       => $todo->start_date,
            last_mod_by      => $todo->last_mod_by,
        });
        my $act_epoch = _parse_ymd_epoch($activity);
        next unless defined $act_epoch;
        my $stale_days = int(($now_day - $act_epoch) / 86400);
        next unless $stale_days > STALE_180_DAYS;

        my $subject = $todo->subject // '';
        my $desc    = $todo->description // '';
        my $text    = "$subject\n$desc";
        my $class   = 'still-valid';
        if ($text =~ /SUPERSEDED|plan changed|no longer needed|abandoned|obsolete/i) {
            $class = 'abandoned';
        }
        elsif ($text =~ /done|completed|finished|resolved|fixed|implemented|verified/i) {
            $class = 'done-not-closed';
        }

        my $project = eval { $schema->resultset('Project')->find($todo->project_id) };
        push @out, {
            record_id      => $todo->record_id,
            subject        => $subject,
            project_id     => $todo->project_id // '',
            project_name   => $project ? ($project->name // '') : '',
            project_code   => $project ? ($project->project_code // '') : ($todo->project_code // ''),
            status         => $todo->status // '',
            priority       => $todo->priority // 5,
            stale_days     => $stale_days,
            suggested_class=> $class,
            activity_date  => $activity,
        };
    }

    # Oldest first in the review queue so the worst staleness is at the top.
    @out = sort { $b->{stale_days} <=> $a->{stale_days} || $a->{record_id} <=> $b->{record_id} } @out;
    return \@out;
}

1;

__END__

=head1 AUTHOR

Comserv2 planning system — todo #2616.

=head1 LICENSE

Same as Comserv2.
