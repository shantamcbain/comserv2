package Comserv::Util::ProjectDependencies;

use strict;
use warnings;

our $FOCUS_QUEUE_LIMIT = 20;

sub done_statuses {
    return (3, 4, 'DONE', 'Completed', 'completed', 'Closed', 'closed', 'Done');
}

sub todo_is_done {
    my ($todo) = @_;
    return 0 unless $todo;
    my $st = eval { $todo->status } // '';
    return 1 if $st == 3 || $st == 4;
    return 1 if $st =~ /^(done|completed|closed)$/i;
    return 0;
}

# Shown in Application Error Audit — exclude from the focus work queue.
sub is_audit_panel_todo {
    my ($subject, $parent_id) = @_;
    return 1 if $parent_id;
    $subject //= '';
    return 1 if $subject =~ /^\[Error\]/;
    return 1 if $subject =~ /Morning Audit/i;
    return 0;
}

sub cross_project_block_still_active {
    my ($c, $dep) = @_;
    return 1 unless $c && $dep;

    my $tdrs = eval { $c->model('DBEncy')->resultset('Todo') };
    return 1 unless $tdrs;

    my @done     = done_statuses();
    my $waiting  = $dep->project_id;
    my $blocker  = $dep->depends_on_id;

    my @waiting_todos = $tdrs->search({
        project_id         => $waiting,
        status             => { -not_in => \@done },
        blocked_by_todo_id => { '!=' => undef },
    })->all;

    for my $w (@waiting_todos) {
        my $blk = eval { $tdrs->find($w->blocked_by_todo_id) };
        next unless $blk && ($blk->project_id // '') == $blocker;
        return 1 unless todo_is_done($blk);
    }
    return 0;
}

sub resolve_for_closed_todo {
    my ($c, $todo) = @_;
    return 0 unless $c && $todo;

    my $blocker_pid = eval { $todo->project_id } // '';
    return 0 unless $blocker_pid;

    my $deps_rs = eval { $c->model('DBEncy')->resultset('ProjectDependency') };
    return 0 unless $deps_rs;

    my $resolved = 0;
    my @deps = $deps_rs->search({
        depends_on_id => $blocker_pid,
        status        => 'active',
    })->all;

    for my $dep (@deps) {
        next if cross_project_block_still_active($c, $dep);
        eval {
            $dep->update({ status => 'resolved', resolved_at => \'NOW()' });
            $resolved++;
        };
    }
    return $resolved;
}

sub active_cross_blocker_count {
    my ($c, $sitename, $is_csc) = @_;
    my $deps_rs = eval { $c->model('DBEncy')->resultset('ProjectDependency') };
    return 0 unless $deps_rs;

    my %dep_search = (status => 'active', dependency_type => 'blocks');
    $dep_search{sitename} = $sitename unless $is_csc;

    my $count = 0;
    my @deps = $deps_rs->search(\%dep_search)->all;
    for my $dep (@deps) {
        $count++ if cross_project_block_still_active($c, $dep);
    }
    return $count;
}

# Returns (\@project_deps, $auto_resolved_count, $auto_detected_count)
sub sync_dependencies {
    my ($c, $sitename, $is_csc, $detect_new) = @_;
    my (@project_deps, $auto_resolved, $auto_detected) = ((), 0, 0);

    return (\@project_deps, 0, 0) unless $c && $c->can('model');

    my $prs     = eval { $c->model('DBEncy')->resultset('Project') };
    my $tdrs    = eval { $c->model('DBEncy')->resultset('Todo') };
    my $deps_rs = eval { $c->model('DBEncy')->resultset('ProjectDependency') };
    return (\@project_deps, 0, 0) unless $prs && $tdrs && $deps_rs;

    my @done = done_statuses();

    if ($detect_new) {
        my %bt_cond = (
            'me.blocked_by_todo_id' => { '!=' => undef },
            'me.status'             => { -not_in => \@done },
            'me.project_id'         => { '!=' => undef },
        );
        $bt_cond{'me.sitename'} = $sitename unless $is_csc;

        for my $blocked ($tdrs->search(\%bt_cond)->all) {
            my $blocker_todo_id = $blocked->blocked_by_todo_id // next;
            my $blocker = eval { $tdrs->find($blocker_todo_id) };
            next unless $blocker && $blocker->project_id;
            next if $blocker->project_id == $blocked->project_id;
            next if todo_is_done($blocker);

            my $existing = eval {
                $deps_rs->find({
                    project_id    => $blocked->project_id,
                    depends_on_id => $blocker->project_id,
                });
            };
            next if $existing;

            eval {
                $deps_rs->create({
                    project_id      => $blocked->project_id,
                    depends_on_id   => $blocker->project_id,
                    dependency_type => 'blocks',
                    status          => 'active',
                    sitename        => $sitename,
                    created_by      => 'auto-detect',
                    description     => "Auto-detected: '"
                        . ($blocked->subject // '?') . "' blocked by '"
                        . ($blocker->subject // '?') . "'",
                });
                $auto_detected++;
            };
        }
    }

    my %dep_search = (status => 'active');
    $dep_search{sitename} = $sitename unless $is_csc;

    my %proj_name_cache;
    for my $dep ($deps_rs->search(\%dep_search, { order_by => { -asc => 'project_id' } })->all) {
        unless (cross_project_block_still_active($c, $dep)) {
            eval {
                $dep->update({ status => 'resolved', resolved_at => \'NOW()' });
                $auto_resolved++;
            };
            next;
        }

        my %d = $dep->get_columns;
        for my $fid ($d{project_id}, $d{depends_on_id}) {
            unless (exists $proj_name_cache{$fid}) {
                my $p = eval { $prs->find($fid) };
                $proj_name_cache{$fid} = $p ? $p->name : "Project #$fid";
            }
        }
        $d{project_name}    = $proj_name_cache{$d{project_id}};
        $d{depends_on_name} = $proj_name_cache{$d{depends_on_id}};
        push @project_deps, \%d;
    }

    return (\@project_deps, $auto_resolved, $auto_detected);
}

1;