package Comserv::Util::TodoRanking;

use strict;
use warnings;
use POSIX ();

=head1 NAME

Comserv::Util::TodoRanking - shared ranking score for the Todo list and Focus Queue

=head1 WHY

The main Todo list (Controller/Todo.pm) sorted by raw C<priority, start_date>, which is
broken by the p1-inflation bug and rewards stale work. The Planning Focus Queue
(Controller/Planning.pm) already scored each row with a stale penalty, due boost and
cross-blocker boost. The two views diverged. This module is the single source of truth
for that score so both views rank identically (see project 240 TODOLIST-UI / plan
TodoListPageDisplayTuningPlan.md).

=cut

use constant STALE_90_DAYS  => 90;
use constant STALE_180_DAYS => 180;
use constant STALE_PENALTY_90  => 50;
use constant STALE_PENALTY_180 => 500;
use constant CROSS_BLOCK_BONUS => -1000;
use constant BLOCK_BONUS        => -0.4;
use constant SUPERSEDED_PENALTY => 10000;   # bury rows explicitly marked SUPERSEDED
use constant ROUTINE_PROJECT_PENALTY => 8000; # project 1 routine daily-plan noise

# Project ids whose open todos are routine daily-plan entries rather than substantive
# work (e.g. "Daily time", "daily Plan update", "Work on Daily Plan update"). These are
# NOT is_recurring, so the Focus Queue filter misses them; we demote them here.
use constant ROUTINE_PROJECT_IDS => { 1 => 1 };

=head2 _is_routine_subject

Heuristic: subject signals a routine daily-plan / break entry rather than tracked work.

=cut

sub _is_routine_subject {
    my ($subject) = @_;
    return 0 unless defined $subject;
    return 1 if $subject =~ /SUPERSEDED/i;
    return 1 if $subject =~ /^\s*(daily\s*plan|work\s*on\s*planning|daily\s*time)\b/i;
    return 0;
}

=head2 score_todo

    Comserv::Util::TodoRanking::score_todo(\%h, \%ctx)

Given a hashref C<%h> of a todo's columns (as produced by C<< $todo->get_columns >>),
plus a context hashref C<%ctx> with keys:

    now_epoch            => time() at call time
    cross_blocker_projects => { $project_id => [blocked project ids] }   (optional)
    row_by_id            => { $record_id => $todo_row }                  (optional, for blocker lookups)

...computes and writes the following keys onto C<%h>:

    ap_score, status_tier, in_progress, stale_days, is_stale,
    priority, block_bonus, cross_block_bonus, due_bonus,
    is_overdue, due_today, days_until_due, is_cross_blocker, blocker_subject, blocker_done

This is the exact scoring math previously inline in Planning.pm (the Focus Queue). It
deliberately does NOT touch project caching, role-category classification, or the
projects-seen aggregation — those remain the caller's responsibility because they differ
between the Focus Queue and the plain Todo list.

Returns the computed ap_score.

=cut

sub score_todo {
    my ($h, $ctx) = @_;
    $h  //= {};
    $ctx //= {};

    my $now_epoch = $ctx->{now_epoch} // time();

    # Optional weight override (used by the AI-tuning preview in Api.pm). When
    # $ctx->{weights} is absent, every weight falls back to its package constant,
    # so callers that don't pass weights get byte-identical behavior. The override
    # is read-only: it never mutates the constants or any stored column.
    my $W = ref($ctx->{weights}) eq 'HASH' ? $ctx->{weights} : {};
    my $w = sub {
        my ($k, $default) = @_;
        my $v = $W->{$k};
        return $default unless defined $v;
        return $v + 0;   # coerce to number (drops garbage non-numeric input)
    };

    my $st          = $h->{status} // '';
    my $in_progress = (   $st == 2
                       || $st == 5
                       || $st =~ /^(in.progress|in.process|IN PROGRESS)$/i ) ? 1 : 0;
    my $status_tier = $in_progress ? 0 : 1;
    $h->{in_progress} = $in_progress;

    my $activity_str = $h->{last_mod_date} || $h->{date_time_posted} || '';
    my $days_stale   = 0;
    if ($activity_str =~ /^(\d{4})-(\d{2})-(\d{2})/) {
        my $act_epoch = POSIX::mktime(0, 0, 0, $3, $2 - 1, $1 - 1900);
        $days_stale = int(($now_epoch - $act_epoch) / 86400) if $act_epoch;
    }
    my $stale_penalty = $days_stale > STALE_180_DAYS ? $w->('stale_180', STALE_PENALTY_180)
                      : ($days_stale > STALE_90_DAYS  ? $w->('stale_90', STALE_PENALTY_90)  : 0);
    $h->{stale_days} = $days_stale;
    $h->{is_stale}   = $days_stale > STALE_180_DAYS ? 1 : 0;

    my $priority         = ($h->{priority} || 5);
    my $block_bonus      = $h->{is_blocking} ? $w->('block', BLOCK_BONUS) : 0;
    my $cross_block_bonus = 0;
    my $cbp = $ctx->{cross_blocker_projects} || {};
    if ($h->{project_id} && $cbp->{$h->{project_id}} && $h->{is_blocking}) {
        $cross_block_bonus     = $w->('cross_block', CROSS_BLOCK_BONUS);
        $h->{is_cross_blocker} = 1;
        $h->{blocking_count}   = scalar @{ $cbp->{$h->{project_id}} };
        $h->{blocking_names}   = join(', ', @{ $ctx->{cross_blocker_names}->{$h->{project_id}} || [] });
    }
    $h->{priority} = $priority;
    $h->{block_bonus} = $block_bonus;

    # Demotions (project 240 / TODOLIST-UI Ph2): bury SUPERSEDED rows and project-1
    # routine daily-plan noise so substantive work surfaces first.
    my $demotion = 0;
    if (_is_routine_subject($h->{subject})) {
        $demotion += $w->('superseded', SUPERSEDED_PENALTY);   # catches SUPERSEDED in subject
    }
    if (ROUTINE_PROJECT_IDS->{ $h->{project_id} // -1 }
        && _is_routine_subject($h->{subject})) {
        $demotion += $w->('routine', ROUTINE_PROJECT_PENALTY);
    }
    $h->{rank_demotion} = $demotion;

    my $due_bonus = 0;
    if (my $due = $h->{due_date}) {
        if ($due =~ /^(\d{4})-(\d{2})-(\d{2})/) {
            my $due_epoch = POSIX::mktime(0, 0, 23, $3, $2 - 1, $1 - 1900);
            my $days_until_due = int(($due_epoch - $now_epoch) / 86400);
            $h->{days_until_due} = $days_until_due;
            if    ($days_until_due < 0)  { $due_bonus = $w->('due_overdue', -5); $h->{is_overdue} = 1; }
            elsif ($days_until_due == 0) { $due_bonus = $w->('due_today', -3);    $h->{due_today}  = 1; }
            elsif ($days_until_due <= 3) { $due_bonus = $w->('due_soon', -1); }
        }
    }
    $h->{due_bonus} = $due_bonus;

    $h->{ap_score} = ($status_tier * $w->('status_tier', 100))
                   + ($priority + $block_bonus + $cross_block_bonus + $due_bonus)
                   + $stale_penalty
                   + $demotion;

    # Blocker resolution (optional — needs row_by_id in ctx)
    my $rib = $ctx->{row_by_id} || {};
    if ($h->{blocked_by_todo_id} && %$rib) {
        my $blocker = $rib->{$h->{blocked_by_todo_id}};
        if ($blocker) {
            $h->{blocker_subject} = $blocker->{subject};
            my $bs = $blocker->{status} // '';
            $h->{blocker_done} = ($bs == 3 || $bs =~ /^(done|completed|closed)$/i) ? 1 : 0;
        }
    }

    return $h->{ap_score};
}

1;

__END__

=head1 AUTHOR

Comserv2 planning system — project 240 TODOLIST-UI.

=head1 LICENSE

Same as Comserv2.
