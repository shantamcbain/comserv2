package Comserv::Model::AI2::Scheduler;
# ONE brain for schedule order: capacity-aware start dates + optional
# predecessor blockers. Never bulk-reschedules the queue (#2218).
#
# Preview first. WRITE only when the user confirms (apply/write/set).
use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use JSON;
use DateTime;
use Comserv::Util::Logging;

extends 'Catalyst::Model';

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

sub sitename {
    my ($self, $c) = @_;
    for my $cand (
        $c->stash->{SiteName},
        $c->session->{SiteName},
        $c->session->{site_name},
        $c->stash->{site_name},
    ) {
        next unless defined $cand && $cand =~ /\S/;
        $cand =~ s/^\s+|\s+$//g;
        return $cand if length $cand;
    }
    return 'CSC';
}

sub _is_guest {
    my ($self, $c) = @_;
    my $u = eval { $c->session->{username} } || '';
    return 1 if !$u || lc($u) eq 'guest';
    return 0;
}

# "schedule todo #N", "set start after the queue for #N", "blocked by #M"
sub detect_intent {
    my ($self, $prompt) = @_;
    return unless defined $prompt && $prompt =~ /\S/;
    my $p = $prompt;
    $p =~ s/^\s+|\s+$//g;
    return if $p =~ /^(how\s+(do\s+i|to)|what\s+is|explain)\b/i;

    my $todo_id;
    if ($p =~ /\b(?:todo|task)\s*#\s*(\d+)\b/i) {
        $todo_id = $1 + 0;
    }
    elsif ($p =~ /#(\d+)\b/ && $p =~ /\b(schedule|start.?date|queue|blocker|blocked)\b/i) {
        $todo_id = $1 + 0;
    }
    return unless $todo_id;

    my $looks = 0;
    $looks = 1 if $p =~ /\b(schedule|reschedule|start.?date|after\s+(?:the\s+)?queue|capacity)\b/i;
    $looks = 1 if $p =~ /\b(blocked\s+by|blocker|predecessor)\b/i;
    return unless $looks;

    my $blocker_id;
    if ($p =~ /\bblocked\s+by\s+(?:todo\s*)?#?\s*(\d+)\b/i) {
        $blocker_id = $1 + 0;
    }
    my $apply = ($p =~ /\b(apply|write|set|save|confirm|do it)\b/i) ? 1 : 0;
    # Preview is the default; "apply schedule for #N" still applies.
    $apply = 0 if $p =~ /\bpreview|propose|what would|don't write|do not write\b/i;

    return {
        todo_id     => $todo_id,
        blocker_id  => $blocker_id,
        apply       => $apply,
        description => $p,
    };
}

sub queue_tail_date {
    my ($self, $open) = @_;
    $open ||= [];
    my $latest;
    for my $row (@$open) {
        next unless $row && ref $row eq 'HASH';
        for my $k (qw(scheduled_date start_date due_date)) {
            my $d = $row->{$k} || '';
            next unless $d =~ /^(\d{4}-\d{2}-\d{2})/;
            $d = $1;
            $latest = $d if !defined $latest || $d gt $latest;
        }
    }
    my $dt = $latest
        ? eval { DateTime->new(
            year => substr($latest,0,4)+0,
            month => substr($latest,5,2)+0,
            day => substr($latest,8,2)+0,
          ) }
        : eval { require Comserv::Util::AppTime; Comserv::Util::AppTime->now_dt } || DateTime->now;
    $dt ||= eval { Comserv::Util::AppTime->now_dt } || DateTime->now;
    return $dt->add(days => 1)->ymd;
}

sub preview {
    my ($self, $intent, $open) = @_;
    return unless $intent && $intent->{todo_id};
    my $proposed = $self->queue_tail_date($open);
    return {
        todo_id            => $intent->{todo_id},
        proposed_start     => $proposed,
        blocker_id         => $intent->{blocker_id},
        apply              => $intent->{apply} ? JSON::true : JSON::false,
        bulk               => JSON::false,
        note               => 'Preview only until you say apply/write/set. Never bulk-reschedules.',
    };
}

sub apply_one {
    my ($self, $c, $preview) = @_;
    return { success => JSON::false, error => 'Login required' } if $self->_is_guest($c);
    return { success => JSON::false, error => 'No preview' } unless $preview && $preview->{todo_id};
    my $rs = eval { $c->model('DBEncy')->resultset('Todo') };
    unless ($rs) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'apply_one',
            'Todo resultset missing');
        return { success => JSON::false, error => 'Todo table unavailable' };
    }
    my $row = eval { $rs->find({ record_id => $preview->{todo_id} }) };
    unless ($row) {
        return { success => JSON::false, error => "Todo #$preview->{todo_id} not found" };
    }
    my %upd = (scheduled_date => $preview->{proposed_start});
    if ($preview->{blocker_id}) {
        $upd{blocked_by_todo_id} = $preview->{blocker_id};
        eval {
            my $blk = $rs->find({ record_id => $preview->{blocker_id} });
            $blk->update({ is_blocking => 1 }) if $blk;
        };
        if ($@) {
            $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__, 'apply_one',
                "Could not mark blocker #$preview->{blocker_id}: $@");
        }
    }
    eval { $row->update(\%upd) };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'apply_one',
            "update todo #$preview->{todo_id} failed: $@");
        return { success => JSON::false, error => 'Could not write schedule' };
    }
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'apply_one',
        "Scheduled todo #$preview->{todo_id} start=$preview->{proposed_start}"
        . ($preview->{blocker_id} ? " blocked_by=#$preview->{blocker_id}" : ''));
    return {
        success        => JSON::true,
        todo_id        => $preview->{todo_id},
        scheduled_date => $preview->{proposed_start},
        blocker_id     => $preview->{blocker_id},
        message        => "Set todo #$preview->{todo_id} scheduled_date=$preview->{proposed_start}"
            . ($preview->{blocker_id} ? " blocked_by=#$preview->{blocker_id}" : '')
            . '.',
    };
}

sub try_chat_schedule {
    my ($self, $c, %args) = @_;
    my $intent = $self->detect_intent($args{prompt} // '') or return;
    if ($self->_is_guest($c)) {
        return {
            handled  => 1,
            success  => 1,
            response => 'Log in to schedule a todo from chat.',
            model    => '(scheduler)',
            provider => 'ai2-scheduler',
            schedule_action => { success => JSON::false, error => 'Login required' },
        };
    }
    my $open = $self->_open_queue($c);
    my $prev = $self->preview($intent, $open);
    if ($intent->{apply}) {
        my $wrote = $self->apply_one($c, $prev);
        return {
            handled  => 1,
            success  => 1,
            response => $wrote->{message} || $wrote->{error} || 'Schedule request processed.',
            model    => '(scheduler)',
            provider => 'ai2-scheduler',
            schedule_action => $wrote,
        };
    }
    my $msg = "Preview (not written): todo #$prev->{todo_id} would start $prev->{proposed_start}"
        . " (day after the latest open scheduled/due date).";
    $msg .= " Blocker: #$prev->{blocker_id}." if $prev->{blocker_id};
    $msg .= " Say 'apply schedule for todo #$prev->{todo_id}' to write this one row. I will not reschedule the rest of the queue.";
    return {
        handled  => 1,
        success  => 1,
        response => $msg,
        model    => '(scheduler)',
        provider => 'ai2-scheduler',
        schedule_action => $prev,
    };
}

sub _open_queue {
    my ($self, $c) = @_;
    my @out;
    eval {
        my $site = $self->sitename($c);
        my $rs = $c->model('DBEncy')->resultset('Todo')->search(
            {
                status => { -in => [1, 2, 'NEW', 'IN PROGRESS'] },
            },
            { rows => 80, order_by => { -desc => 'record_id' } },
        );
        while (my $t = $rs->next) {
            push @out, {
                record_id      => $t->record_id,
                scheduled_date => eval { $t->scheduled_date } || '',
                due_date       => eval { $t->due_date } || '',
                start_date     => eval { $t->can('start_date') ? $t->start_date : '' } || '',
            };
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__, '_open_queue',
            "open queue read failed: $@");
    }
    return \@out;
}

sub chat_contract {
    my ($self, $c) = @_;
    return '' if $self->_is_guest($c);
    return <<'END';
SCHEDULER (one todo at a time — never bulk-reschedule):
When the user asks to schedule todo #N after the queue, or mark it blocked by #M:
1. Preview first: proposed scheduled_date = day after the latest open todo date.
2. Do not invent blockers. Only use a real todo id they named.
3. WRITE only if they said apply/write/set/confirm. Then emit:
[ACTION: {"action":"schedule_todo","params":{"todo_id":N,"apply":true,"blocked_by_todo_id":M}}]
4. Never rewrite start_date on every open todo.
END
}

__PACKAGE__->meta->make_immutable;
1;
