package Comserv::Util::TodoTypes;

use strict;
use warnings;
use Exporter 'import';
use DateTime;

our @EXPORT_OK = qw(
    TODO_TYPES TODO_TYPE_LABELS TODO_TYPE_ICONS
    RECURRENCE_RULES RECURRENCE_RULE_LABELS
    is_valid_todo_type is_valid_recurrence_rule
    todo_type_icon todo_type_label
    recurrence_label recurring_matches_date
);

# All valid todo types — add new types here, never in the DB schema.
# Values are the keys stored in todo.todo_type.
use constant TODO_TYPES => [qw(task appointment event meeting reminder)];

# Human-readable labels for each type
use constant TODO_TYPE_LABELS => {
    task        => 'Task',
    appointment => 'Appointment',
    event       => 'Event',
    meeting     => 'Meeting',
    reminder    => 'Reminder',
};

# Display icons (emoji) per type — used in badges and calendar cells
use constant TODO_TYPE_ICONS => {
    task        => '',
    appointment => "\x{1F4CC}",    # 📌
    event       => "\x{1F382}",    # 🎂  (birthday / calendar event)
    meeting     => "\x{1F91D}",    # 🤝
    reminder    => "\x{1F514}",    # 🔔
};

# All valid recurrence rules — add new cadences here.
# Values are the keys stored in todo.recurrence_rule.
use constant RECURRENCE_RULES => [qw(daily weekdays weekly biweekly monthly yearly)];

# Human-readable labels for recurrence rules
use constant RECURRENCE_RULE_LABELS => {
    daily     => 'Every Day',
    weekdays  => 'Weekdays (Mon–Fri)',
    weekly    => 'Every Week',
    biweekly  => 'Every Two Weeks',
    monthly   => 'Every Month',
    yearly    => 'Every Year',
};

# ── Helpers ──────────────────────────────────────────────────────────────────

sub is_valid_todo_type {
    my ($type) = @_;
    return 0 unless defined $type && length $type;
    my %valid = map { $_ => 1 } @{ +TODO_TYPES };
    return $valid{lc $type} ? 1 : 0;
}

sub is_valid_recurrence_rule {
    my ($rule) = @_;
    return 0 unless defined $rule && length $rule;
    my %valid = map { $_ => 1 } @{ +RECURRENCE_RULES };
    return $valid{lc $rule} ? 1 : 0;
}

sub todo_type_icon {
    my ($type) = @_;
    return '' unless defined $type;
    return TODO_TYPE_ICONS->{ lc $type } // '';
}

sub todo_type_label {
    my ($type) = @_;
    return 'Task' unless defined $type && length $type;
    return TODO_TYPE_LABELS->{ lc $type } // ucfirst(lc $type);
}

sub recurrence_label {
    my ($rule) = @_;
    return '' unless defined $rule && length $rule;
    return RECURRENCE_RULE_LABELS->{ lc $rule } // ucfirst(lc $rule);
}

sub _get_todo_start_date_str {
    my ($todo) = @_;
    return '' unless $todo->can('start_date') && defined $todo->start_date;
    my $sr = $todo->start_date;
    my $sd = ref($sr) ? $sr->ymd : "$sr";
    return length($sd) >= 10 ? substr($sd, 0, 10) : '';
}

sub recurring_matches_date {
    my ($todo, $date_str) = @_;
    return 0 unless $date_str && $date_str =~ /^(\d{4})-(\d{2})-(\d{2})$/;
    my ($y, $m, $d) = ($1, $2+0, $3+0);

    my $rule = '';
    if ($todo->can('recurrence_rule') && defined $todo->recurrence_rule) {
        $rule = lc($todo->recurrence_rule);
    }

    return 1 unless $rule;

    if ($rule eq 'daily') {
        return 1;
    } elsif ($rule eq 'weekdays') {
        my $dow = eval { DateTime->new(year => $y, month => $m, day => $d)->day_of_week };
        return ($dow && $dow >= 1 && $dow <= 5) ? 1 : 0;
    } elsif ($rule eq 'weekly' || $rule eq 'biweekly') {
        my $sd = _get_todo_start_date_str($todo);
        return 1 unless $sd && $sd =~ /^(\d{4})-(\d{2})-(\d{2})$/;
        my ($sy, $sm, $sday) = ($1, $2+0, $3+0);
        my $anchor_dt = eval { DateTime->new(year => $sy, month => $sm, day => $sday) };
        my $target_dt = eval { DateTime->new(year => $y,  month => $m,  day => $d)  };
        return 1 unless $anchor_dt && $target_dt;
        return 0 unless $anchor_dt->day_of_week == $target_dt->day_of_week;
        if ($rule eq 'weekly') {
            return 1;
        } else {
            my $days_diff = abs($target_dt->delta_days($anchor_dt)->delta_days);
            my $weeks = int($days_diff / 7);
            return ($weeks % 2 == 0) ? 1 : 0;
        }
    } elsif ($rule eq 'monthly') {
        my $sd = _get_todo_start_date_str($todo);
        return 1 unless $sd && $sd =~ /^\d{4}-\d{2}-(\d{2})$/;
        return ($d == $1+0) ? 1 : 0;
    } elsif ($rule eq 'yearly') {
        my $sd = _get_todo_start_date_str($todo);
        return 1 unless $sd && $sd =~ /^\d{4}-(\d{2})-(\d{2})$/;
        return ($m == $1+0 && $d == $2+0) ? 1 : 0;
    }

    return 1;
}

1;
