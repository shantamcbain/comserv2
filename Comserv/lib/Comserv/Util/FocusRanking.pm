package Comserv::Util::FocusRanking;

use strict;
use warnings;

=head1 NAME

Comserv::Util::FocusRanking - site-agnostic ranking + filter toolkit for todo lists.

=head1 WHY

The Focus Queue scoring and Role/Site/Project filtering were originally entangled in
C<Comserv::Controller::Planning> (the CSC planning page) and in client JS. That confined
the logic to one view. This module is the SHARED, SITE-AGNOSTIC home for both:

  * score_todo  - the computed importance score (delegates to TodoRanking)
  * passes_filters - pure Role/Site/Project predicate, mirrors the Focus Queue filter

Any controller (CSC planning, BMaster calendar, a future weather-aware view, etc.) calls
these with its own sitename / selected filters. No C<is_csc> gating lives here.

See project 240 TODOLIST-UI, Phase 5 / 5b / 6.

=cut

use parent qw(Exporter);
our @EXPORT_OK = qw(score_todo passes_filters in_branch_scope is_active_work
                    todo_matches_branch cmp_branch_focus subject_branch
                    place_blockers_before_blocked apply_blocker_placement);

# Scoring is owned by TodoRanking (single source of truth for ap_score).
use Comserv::Util::TodoRanking ();

# ----------------------------------------------------------------------------
# passes_filters( \%todo_attrs, \%filter_ctx )
#
# Pure, site-agnostic equivalent of the Focus Queue client filter
# (daily-plan.js applyAllFilters). Returns 1 if the todo should be visible,
# given the selected Role/Site/Project sets.
#
#   %todo_attrs = {
#       role_cats   => 'general,developer',   # comma-separated
#       sitename    => 'CSC',
#       project_id  => 235,
#   }
#   %filter_ctx = {
#       role_filtered  => 1,                 # non-CSC-admin visibility gate
#       permitted_roles=> { editor=>1 },     # roles the viewer may see
#       all_roles    => { general=>1, developer=>1, ... },  # every role the viewer can pick
#       checked_roles=> { developer=>1 },                    # roles the viewer selected
#       site_filtered=> 0|1,        # true when not all sites are selected
#       checked_sites=> { CSC=>1 },
#       proj_filtered=> 0|1,        # true when not all projects are selected
#       checked_projects=> { 235=>1, 240=>1 },
#   }
#
# Semantics:
#   - CSC administrators bypass role and SiteName restrictions.
#   - Every other viewer must match an assigned role or the general category.
#   - SiteName is then enforced before project filtering and sorting.
# ----------------------------------------------------------------------------
sub passes_filters {
    my ($t, $ctx) = @_;
    $t   //= {};
    $ctx //= {};

    # Role is the first visibility gate. CSC admins bypass it.
    my $show_role = 1;
    if ($ctx->{is_csc_admin}) {
        $show_role = 1;
    } elsif ($ctx->{role_filtered}) {
        my $permitted = $ctx->{permitted_roles} || {};
        my @todo_roles = split /,/, ($t->{role_cats} // 'general');
        $show_role = 0;
        for my $role (@todo_roles) {
            $role =~ s/^\s+|\s+$//g;
            next unless length $role;
            if ($role eq 'general' || $permitted->{$role}) {
                $show_role = 1;
                last;
            }
        }
    }
    return 0 unless $show_role;

    # SiteName is the second visibility gate.
    my $show_site = 1;
    if ($ctx->{site_filtered} && !$ctx->{is_csc_admin}) {
        my $cs = $ctx->{checked_sites} || {};
        $show_site = $cs->{ $t->{sitename} // '' } ? 1 : 0;
    }

    # Project — exact id OR the project's parent (phase sub-projects live
    # under a parent; filtering DRYER-INT must include #273–#279).
    my $show_proj = 1;
    if ($ctx->{proj_filtered}) {
        my $cp = $ctx->{checked_projects} || {};
        my $pid    = $t->{project_id} // '';
        my $parent = $t->{parent_id}  // '';
        $show_proj = ($cp->{$pid} || ($parent ne '' && $cp->{$parent})) ? 1 : 0;
    }

    return ($show_role && $show_site && $show_proj) ? 1 : 0;
}

# ----------------------------------------------------------------------------
# in_branch_scope( \%todo, \%ctx )
#
# On a worktree server the Focus Queue should not dump the whole site backlog.
# Keep a row if it belongs to the branch's project tree, or if it is actually
# blocking that tree (cross-project is_blocking, or a blocked_by_todo_id).
#
#   %ctx = {
#       branch_project_ids     => { 138 => 1, 234 => 1, ... },
#       blocked_by_ids         => { 99 => 1 },   # todos that block a branch todo
#       cross_blocker_projects => { $blocker_pid => [ blocked pids ] },
#   }
# ----------------------------------------------------------------------------
sub in_branch_scope {
    my ($t, $ctx) = @_;
    $t   //= {};
    $ctx //= {};

    my $ids = $ctx->{branch_project_ids} || {};
    return 0 unless %$ids;

    my $pid = $t->{project_id} // '';
    return 1 if $pid ne '' && $ids->{$pid};

    # Active work (status 5 / in_progress) from ANY project — so another
    # developer does not start a todo already being worked.
    if ($ctx->{keep_active}) {
        my $st = $t->{status} // '';
        return 1 if $st eq '5' || $t->{in_progress};
    }

    my $rid = $t->{record_id} // '';
    my $blockers = $ctx->{blocked_by_ids} || {};
    return 1 if $rid ne '' && $blockers->{$rid};

    # A todo on a depended-on project that is marked blocking, and that
    # dependency targets a project in this branch's tree.
    my $cbp     = $ctx->{cross_blocker_projects} || {};
    my $blocked = ($pid ne '' && $cbp->{$pid}) ? $cbp->{$pid} : [];
    if (ref($blocked) eq 'ARRAY' && @$blocked
        && ($t->{is_cross_blocker} || $t->{is_blocking})) {
        for my $bp (@$blocked) {
            return 1 if $ids->{$bp};
        }
    }
    return 0;
}

# Status 5 (open work log) is "Active" in the todo card.
sub is_active_work {
    my ($t) = @_;
    return 0 unless $t;
    my $st = $t->{status} // '';
    return 1 if $st =~ /^5$/;
    return 0;
}

# A leading [Branch] tag names the branch that owns the work. Used when a
# row was filed on the wrong project_id (schema and planning share 138).
# Unknown brackets ([Error], [URGENT]) are not branch tags.
sub subject_branch {
    my ($t) = @_;
    $t //= {};
    my $sub = $t->{subject} // '';
    return '' unless $sub =~ /^\[([A-Za-z0-9_-]+)\]/;
    my $tag = lc($1);
    return $tag if $tag =~ /^(?:planning|aisystem|3d|git|dockerha|inventoryaccounting|schema|helpdesk|documentation)$/;
    return '';
}

# Branch identity via project id tree, parent, name, or code keywords.
# Do NOT match a bare "ai" substring (hits "daily").
# A [Branch] tag wins over project_id: the row belongs to the named branch,
# not to the project it was mis-filed on.
sub todo_matches_branch {
    my ($t, $branch, $scope) = @_;
    $t      //= {};
    $scope  //= {};
    $branch = lc($branch // '');
    return 0 unless $branch && $branch ne 'main';

    my $named = subject_branch($t);
    if ($named ne '') {
        return $named eq $branch ? 1 : 0;
    }

    my $pid = $t->{project_id} // '';
    return 1 if $pid ne '' && $scope->{$pid};
    my $pp = $t->{project_parent_id} // '';
    return 1 if $pp ne '' && $scope->{$pp};

    my $code = lc($t->{project_code} // '');
    my $name = lc($t->{project_name} // '');
    return 1 if $code eq $branch || $name eq $branch;
    return 1 if $code ne '' && index($code, $branch) >= 0;
    return 1 if $name ne '' && index($name, $branch) >= 0;

    my %hints = (
        planning             => [qw(planning plan-queue todolist-ui)],
        aisystem             => [qw(aisystem aimps agents aichat ai2 v2mig)],
        '3d'                 => [qw(dryer 3d printing_3d)],
        git                  => [qw(gitwt git-dev)],
        dockerha             => [qw(infra-ha dockerha k3s)],
        inventoryaccounting  => [qw(inventory accounting sql-ledger)],
    );
    my $keys = $hints{$branch} || [];
    for my $k (@$keys) {
        return 1 if $code ne '' && index($code, $k) >= 0;
        return 1 if $name ne '' && index($name, $k) >= 0;
    }
    return 0;
}

# Sort: Active first, then this branch's projects, then ap_score.
# is_blocking is NOT a sort key. A blocker is placed immediately before the
# todo it blocks by place_blockers_before_blocked, and only in a list that
# already contains that todo (apply_blocker_placement).
sub cmp_branch_focus {
    my ($a, $b, $ctx) = @_;
    $a   //= {};
    $b   //= {};
    $ctx //= {};
    my $scope = $ctx->{branch_project_ids} || {};
    my $branch = $ctx->{branch} || '';

    my $a_act = is_active_work($a) ? 1 : 0;
    my $b_act = is_active_work($b) ? 1 : 0;
    my $a_br  = todo_matches_branch($a, $branch, $scope) ? 1 : 0;
    my $b_br  = todo_matches_branch($b, $branch, $scope) ? 1 : 0;

    return $b_act <=> $a_act
        || $b_br <=> $a_br
        || ($a->{ap_score} // 0) <=> ($b->{ap_score} // 0)
        || ($a->{priority} // 5) <=> ($b->{priority} // 5);
}

# Reorder so each blocker sits immediately before the todos in this list
# that name it. The group lands at the first blocked row, not at the top.
# A blocker with nothing it blocks in this list stays where it was.
sub place_blockers_before_blocked {
    my ($rows) = @_;
    return [] unless $rows && ref($rows) eq 'ARRAY' && @$rows;

    my %by_id;
    for my $t (@$rows) {
        next unless ref($t) eq 'HASH' && defined $t->{record_id} && $t->{record_id} ne '';
        $by_id{ $t->{record_id} } = $t;
    }
    my %direct;
    for my $t (@$rows) {
        next unless ref($t) eq 'HASH';
        my $bid = $t->{blocked_by_todo_id} || next;
        next unless $by_id{$bid};
        next if $t->{blocker_done};
        push @{ $direct{$bid} }, $t->{record_id};
    }
    return [@$rows] unless %direct;

    my %emitted;
    my @out;
    my $emit;
    $emit = sub {
        my ($id) = @_;
        return if $emitted{$id};
        my $row = $by_id{$id} || return;
        my $parent = $row->{blocked_by_todo_id} || 0;
        if ($parent && $by_id{$parent} && !$row->{blocker_done}) {
            $emit->($parent);
        }
        return if $emitted{$id};
        push @out, $row;
        $emitted{$id} = 1;
        for my $dep (@{ $direct{$id} || [] }) {
            $emit->($dep);
        }
    };

    for my $t (@$rows) {
        next unless ref($t) eq 'HASH';
        my $id = $t->{record_id};
        next if !defined $id || $emitted{$id};
        # Defer a blocker until its first blocked row, so it does not float up.
        next if $direct{$id};
        my $bid = $t->{blocked_by_todo_id} || 0;
        if ($bid && $by_id{$bid} && !$t->{blocker_done}) {
            $emit->($bid);
            next;
        }
        push @out, $t;
        $emitted{$id} = 1;
    }
    for my $t (@$rows) {
        my $id = $t->{record_id};
        next if !defined $id || $emitted{$id};
        $emit->($id);
    }
    return \@out;
}

# Branch list: keep rows that belong here. A blocker whose blocked todos are
# not in this list is dropped, even if its own project_id matches — unless
# it is started (status 5). Started work stays visible so it is not started
# again. A blocker that is not a member is inserted when a kept row names it.
# Then the blocker is placed immediately before those rows.
# $all is the pre-filter universe (needed to find the blocker row). Caller logs.
sub apply_blocker_placement {
    my ($kept, $all) = @_;
    $kept = [] unless $kept && ref($kept) eq 'ARRAY';
    $all  = ($all && ref($all) eq 'ARRAY' && @$all) ? $all : $kept;

    my %by_id;
    for my $t (@$all) {
        next unless ref($t) eq 'HASH' && defined $t->{record_id} && $t->{record_id} ne '';
        $by_id{ $t->{record_id} } = $t;
    }
    my %kept_id = map { ($_->{record_id} // '') => 1 } grep { ref($_) eq 'HASH' } @$kept;

    my %deps;
    for my $t (@$all) {
        next unless ref($t) eq 'HASH';
        my $bid = $t->{blocked_by_todo_id} || next;
        next if $t->{blocker_done};
        push @{ $deps{$bid} }, $t;
    }

    my @members;
    for my $t (@$kept) {
        next unless ref($t) eq 'HASH';
        my $id = $t->{record_id};
        my $d  = $deps{$id};
        if ($t->{is_blocking} && $d && @$d && !is_active_work($t)) {
            next unless grep { $kept_id{ $_->{record_id} } } @$d;
        }
        push @members, $t;
    }
    %kept_id = map { ($_->{record_id} // '') => 1 } @members;

    for my $t (@members) {
        my $bid = $t->{blocked_by_todo_id} || next;
        next if $t->{blocker_done};
        next if $kept_id{$bid};
        my $blocker = $by_id{$bid} || next;
        my $bs = $blocker->{status} // '';
        next if $bs eq '3' || $bs eq '4' || $bs =~ /^(?:done|completed|closed)$/i;
        push @members, $blocker;
        $kept_id{$bid} = 1;
    }
    return place_blockers_before_blocked(\@members);
}

# Re-export the scorer so callers import from one place.
sub score_todo {
    return Comserv::Util::TodoRanking::score_todo(@_);
}

1;

__END__

=head1 AUTHOR

Comserv2 planning system - project 240 TODOLIST-UI.

=head1 LICENSE

Same as Comserv2.
