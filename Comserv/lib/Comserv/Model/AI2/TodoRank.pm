package Comserv::Model::AI2::TodoRank;
# ONE brain for the TodoRank agent (project #287 TODOAGENT / plan
# Documentation/TodoRankAgentPlan.tt, Phase 2 ranker + Phase 3 apply logic).
#
# Given a branch/sitename-scoped batch of open todos, ask an AI model to return
# PER-RECORD {priority, todo_type, due_date, reason}, then (only when the
# caller enables writes) apply the values that actually DIFFER, attributed to
# last_mod_by='ai-todorank'.
#
# Safety rails (plan §3):
#   * DRY-RUN by default — nothing is written unless apply => 1 is passed.
#   * Never closes or deletes anything; priority stays inside the 1..10 ladder.
#   * Rows with an open work-log session (status=5) keep their dates.
#   * Every proposal is validated against the record_ids we sent.
use Moose;
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)

use Try::Tiny;
use JSON qw(encode_json decode_json);
use DateTime;

use Comserv::Util::Logging;

extends 'Catalyst::Model';

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

# Batch size per model call (plan Phase 3: ~15/batch)
use constant BATCH_SIZE => 15;

# Priority ladder from Comserv::Priority (blocker .. recurring)
use constant PRIORITY_MIN => 1;
use constant PRIORITY_MAX => 10;

my %VALID_TODO_TYPE = map { $_ => 1 } qw(task event milestone);

# ---------------------------------------------------------------------------
# Gather open todos scoped to sitename / project_id, scored by the shared
# TodoRanking util (context only — the MODEL judges function, same rule as
# FocusTune: the coded score must NOT be presented as the answer).
# Returns ($rows_by_id, $rbid) where $rows_by_id is an ordered arrayref of
# column hashrefs with ap_score attached.
# ---------------------------------------------------------------------------
sub gather_todos {
    my ($self, $c, %opts) = @_;
    my $now_epoch = $opts{now_epoch} // time();

    my %crit = ( status => { -not_in => [ 3, 4, '3', '4', 'COMPLETED', 'CANCELLED' ] } );
    if ($opts{project_id} && $opts{project_id} =~ /^\d+$/) {
        $crit{project_id} = $opts{project_id};
    }
    else {
        my $site = $opts{sitename} || $self->_sitename($c);
        $crit{sitename} = $site if $site;
    }

    my (@rows, %rbid);
    eval {
        my $schema = $c->model('DBEncy')->schema;
        my @rs = $schema->resultset('Todo')->search(
            \%crit,
            { order_by => { -asc => ['priority', 'record_id'] }, rows => 2000 },
        )->all;
        %rbid = map { $_->record_id => { $_->get_columns } } @rs;
        for my $t (@rs) {
            my $h = $rbid{ $t->record_id };
            Comserv::Util::TodoRanking::score_todo($h, { now_epoch => $now_epoch, row_by_id => \%rbid });
            push @rows, $h;
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'todorank_gather', "gather_todos failed: $@");
        return ([], {});
    }
    @rows = sort { ($a->{ap_score} // 0) <=> ($b->{ap_score} // 0) } @rows;
    return (\@rows, \%rbid);
}

sub _sitename {
    my ($self, $c) = @_;
    for my $cand ($c->stash->{SiteName}, $c->session->{SiteName}, $c->stash->{site_name}) {
        next unless defined $cand && $cand =~ /\S/;
        $cand =~ s/^\s+|\s+$//g;
        return $cand if length $cand;
    }
    return 'CSC';
}

# ---------------------------------------------------------------------------
# Branch context: which worktree branch / coordination project serves this
# SiteName+port. Read from root/config/worktrees.json (the ONE source of the
# branch→port→project mapping). Best-effort; missing file just means no branch
# framing in the prompt.
# Returns { branch, project_id, project_name } with possibly-undef values.
# ---------------------------------------------------------------------------
sub branch_context {
    my ($self, $c) = @_;
    my $out = { branch => undef, project_id => undef, project_name => undef };
    my $path = $c->path_to('root', 'config', 'worktrees.json');
    return $out unless $path && -f $path;
    my $json;
    eval {
        open my $fh, '<', $path or die "open: $!";
        local $/; $json = <$fh>; close $fh;
        1;
    } or return $out;
    my $cfg;
    eval { $cfg = JSON::decode_json($json); };
    return $out unless ref($cfg) eq 'HASH' && ref($cfg->{branches}) eq 'HASH';

    # Match by port first (each branch instance runs on its own port), else by
    # host+sitename. The request port is authoritative for "which branch am I".
    my ($host, $port) = ($c->req->uri->host // '', $c->req->uri->port // '');
    for my $label (sort keys %{ $cfg->{branches} }) {
        my $b = $cfg->{branches}{$label} or next;
        if (($b->{port} // '') eq $port
            && lc($b->{sitename} // '') eq lc($self->_sitename($c))) {
            $out->{branch}      = $label;
            $out->{project_id}  = $b->{project_id};
            return $self->_fill_project_name($c, $out);
        }
    }
    return $out;
}

sub _fill_project_name {
    my ($self, $c, $ctx) = @_;
    return $ctx unless $ctx->{project_id};
    eval {
        my $row = $c->model('DBEncy')->schema->resultset('Project')->find($ctx->{project_id});
        $ctx->{project_name} = $row ? $row->name : undef;
        1;
    };
    return $ctx;
}

# ---------------------------------------------------------------------------
# Prompt for one batch. JSON-only contract; presentation order is shuffled
# deterministically (same anti-anchor trick as FocusTune::build_prompt).
#
# SITE CONTEXT (mandatory): %ctx carries
#   sitename      — the SiteName whose todos are being ranked
#   branch        — optional worktree branch label this instance serves
#   project_name  — optional branch coordination project name
#   roles         — optional arrayref of the requesting user's roles
# The agent coordinates SITE OPERATIONS for this one SiteName: it has NO git
# access and must judge importance by what this SITE needs done next, not by
# generic "programming" merit. On CSC that leans code; on 3d it is print/sign/
# rendering ops — the framing must follow the site, never assume coding.
# ---------------------------------------------------------------------------
sub build_prompt {
    my ($self, $batch, $ctx) = @_;
    $ctx ||= {};
    my @shuffled = sort { (($a->{record_id} // 0) * 2654435761 % 1000)
                       <=> (($b->{record_id} // 0) * 2654435761 % 1000) } @$batch;

    my @lines;
    for my $h (@shuffled) {
        push @lines, sprintf(
            "rec=%s | pri=%s | type=%s | start=%s | due=%s | status=%s | proj=%s | subj=%s | desc=%s",
            $h->{record_id}, $h->{priority}, $h->{todo_type} // 'task',
            substr($h->{start_date} // '', 0, 10),
            substr($h->{due_date} // '', 0, 10),
            $h->{status},
            $h->{project_code} // $h->{project_id} // '',
            ($h->{subject} // '') =~ s/\n/ /gr,
            substr((($h->{description} // '') =~ s/\s+/ /gr), 0, 200),
        );
    }
    my $todo_block = join("\n", @lines);

    my $site  = $ctx->{sitename} || 'this site';
    my $branch = $ctx->{branch} ? "The app instance you serve is the '$ctx->{branch}' branch."
                                : '';
    my $proj   = $ctx->{project_name} ? "Its coordination project is '$ctx->{project_name}'."
                                      : '';
    my $roles  = (ref($ctx->{roles}) eq 'ARRAY' && @{ $ctx->{roles} })
        ? "Requester roles: " . join(', ', @{ $ctx->{roles} }) . " — weight what that role can act on."
        : '';

    my $system =
        "You are the Comserv2 TodoRank agent for SiteName=$site. You coordinate SITE\n"
      . "OPERATIONS for this one SiteName only: you have NO git access, no shell, and no\n"
      . "view of other sites' todos. Judge each todo by how much it helps THIS SITE's\n"
      . "operations move forward — on a coding site that is code health; on an ops site\n"
      . "(print/sign/rendering) it is keeping production running. Do NOT assume every\n"
      . "todo is programming work. $branch $proj $roles\n"
      . "For EACH todo below decide the correct stored values so the daily-plan priority\n"
      . "list is ordered by real need:\n"
      . "  priority: integer 1 (blocker/incident) .. 10 (recurring noise). Judge FUNCTION:\n"
      . "    what breaks, what unblocks other work, what advances a documented plan outranks\n"
      . "    polish, routine events, and stale wishes. Ignore the pri= shown — it is often wrong.\n"
      . "  todo_type: \"task\" for real work, \"event\" for fixed-time items (morning/lunch/\n"
      . "    afternoon routines, meetings) that must NOT sit in the task priority list.\n"
      . "  due_date: YYYY-MM-DD. Only change it when the todo is overdue or has none and a\n"
      . "    sensible horizon is obvious (default +7 days from today); otherwise echo the existing one.\n"
      . "Return ONLY a JSON object (no prose, no markdown fence):\n"
      . '{"records":[{"record_id":<int>,"priority":<int 1-10>,"todo_type":"task|event|milestone",'
      . '"due_date":"YYYY-MM-DD","reason":"<one short sentence>"}]}\n'
      . "Every record_id you return MUST be one of the rec= values. One entry each.\n"
      . "Today is " . DateTime->now->ymd . ".";

    my $user_prompt = "TODOS (order is meaningless — do not anchor on it):\n$todo_block";
    return ($system, $user_prompt);
}

# ---------------------------------------------------------------------------
# Run one batch through a model via Router->dispatch_chat (same provider path
# as chat/FocusTune). Returns the raw dispatch result hash.
# ---------------------------------------------------------------------------
sub run_batch {
    my ($self, $c, $target, $system, $user_prompt) = @_;
    my $resp;
    eval {
        $resp = $c->model('AI2::Router')->dispatch_chat($c,
            ref($target) ? $target->{name} : $target,
            [ { role => 'system', content => $system },
              { role => 'user',   content => $user_prompt } ],
            can_select => 1);
        1;
    } or do {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'todorank_run',
            "dispatch_chat threw: $@");
        $resp = { success => 0, error => "$@" };
    };
    return $resp;
}

# Parse one dispatch result into validated proposals keyed by record_id:
#   { record_id => { priority, todo_type, due_date, reason } }
# Invalid rows are dropped silently except for a count in {rejected}.
sub parse_result {
    my ($self, $res, $valid_ids) = @_;
    my %valid = map { $_ => 1 } @$valid_ids;
    my $out = { proposals => {}, rejected => 0 };

    return $out unless $res && $res->{success};
    my $raw = $res->{response} // '';
    $raw =~ s/^```(?:json)?\s*//i; $raw =~ s/\s*```$//;
    my $parsed;
    eval { $parsed = decode_json($raw); };
    return $out unless ref($parsed) eq 'HASH';

    my $records = ref($parsed->{records}) eq 'ARRAY' ? $parsed->{records} : [];
    for my $r (@$records) {
        next unless ref($r) eq 'HASH';
        my $id = $r->{record_id};
        next unless defined $id && $id =~ /^\d+$/ && $valid{$id};
        my %prop;
        if (defined $r->{priority} && $r->{priority} =~ /^-?\d+$/) {
            $prop{priority} = $r->{priority} < PRIORITY_MIN ? PRIORITY_MIN
                            : $r->{priority} > PRIORITY_MAX ? PRIORITY_MAX
                            : 0 + $r->{priority};
        }
        if (defined $r->{todo_type} && $VALID_TODO_TYPE{ lc($r->{todo_type}) }) {
            $prop{todo_type} = lc($r->{todo_type});
        }
        if (defined $r->{due_date} && $r->{due_date} =~ /^\d{4}-\d{2}-\d{2}$/) {
            $prop{due_date} = $r->{due_date};
        }
        $prop{reason} = substr(($r->{reason} // ''), 0, 300);
        if (%prop) {
            $out->{proposals}{$id} = \%prop;
        }
        else {
            $out->{rejected}++;
        }
    }
    return $out;
}

# ---------------------------------------------------------------------------
# Phase 3 apply. Compares proposals against current row values and writes ONLY
# differences via the DBIC row (NOT the HTTP API — this runs server-side).
# Every write carries last_mod_by='ai-todorank'. Rows in an open log session
# (status=5) never get date changes. dry_run (default) returns would-change.
# Returns { changed => [...], unchanged => N, missing => N }.
# ---------------------------------------------------------------------------
sub apply_proposals {
    my ($self, $c, $rbid, $proposals, %opts) = @_;
    my $dry   = exists $opts{apply} ? !$opts{apply} : 1;
    my $model = $opts{model} // '';
    my $today = DateTime->now->ymd;

    my @changed;
    my ($unchanged, $missing) = (0, 0);

    for my $id (sort { $a <=> $b } keys %$proposals) {
        my $row_hash = $rbid->{$id};
        unless ($row_hash) { $missing++; next; }

        my $prop = $proposals->{$id};
        my %set;
        $set{priority}  = $prop->{priority}  if defined $prop->{priority}
                         && $prop->{priority} != ($row_hash->{priority} // 5);
        $set{todo_type} = $prop->{todo_type} if defined $prop->{todo_type}
                         && lc($row_hash->{todo_type} // 'task') ne $prop->{todo_type};
        if (defined $prop->{due_date}
            && substr($row_hash->{due_date} // '', 0, 10) ne $prop->{due_date}
            && "$row_hash->{status}" ne '5') {          # never touch open-session dates
            $set{due_date} = $prop->{due_date};
        }

        next unless %set;
        push @changed, {
            record_id => $id + 0,
            changes   => { map { $_ => { from => $row_hash->{$_}, to => $set{$_} } } sort keys %set },
            reason    => $prop->{reason},
            applied   => (!$dry ? \1 : \0),
        };
        next if $dry;

        eval {
            my $schema = $c->model('DBEncy')->schema;
            my $row = $schema->resultset('Todo')->find($id);
            $row->update({ %set, last_mod_by => 'ai-todorank', last_mod_date => $today });
            1;
        } or do {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                'todorank_apply', "update todo $id failed: $@");
            pop @changed;
            next;
        };
    }
    for my $id (keys %$proposals) {
        $unchanged++ unless grep { $_->{record_id} == $id } @changed;
    }
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'todorank',
        sprintf('%s pass model=%s proposed=%d changed=%d',
                $dry ? 'DRY-RUN' : 'WRITE', $model, scalar(keys %$proposals), scalar(@changed)));
    return { changed => \@changed, unchanged => $unchanged, missing => $missing, dry_run => $dry ? \1 : \0 };
}

__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 NAME

Comserv::Model::AI2::TodoRank — AI re-ranking of open todos (TODOAGENT plan Phases 2–3)

=head1 SYNOPSIS

    my $rank = $c->model('AI2::TodoRank');
    my ($rows, $rbid) = $rank->gather_todos($c, sitename => 'CSC');
    my ($system, $user) = $rank->build_prompt([ @$rows[0..14] ]);
    my $res  = $rank->run_batch($c, { name => 'grok-4.6' }, $system, $user);
    my $p    = $rank->parse_result($res, [ map { $_->{record_id} } @$rows ]);
    my $out  = $rank->apply_proposals($c, $rbid, $p->{proposals});   # dry-run

=cut
