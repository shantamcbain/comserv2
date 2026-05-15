package Comserv::Util::TodoTypes;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
    TODO_TYPES TODO_TYPE_LABELS TODO_TYPE_ICONS
    RECURRENCE_RULES RECURRENCE_RULE_LABELS
    is_valid_todo_type is_valid_recurrence_rule
    todo_type_icon todo_type_label
    recurrence_label
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

1;
