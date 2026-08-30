package Comserv::Model::AI2::TodoCreate;
# ONE brain for creating todos from Chat-with-AI (widget + editor).
# Callers:
#   * AI2::Actions  create_todo / resolve_todo_project
#   * AI2::Chat     sitename project catalog + ACTION contract
#   * ai-chat/feature-todo.js via POST /ai2/action
#
# Todos always belong to the current SiteName. project_id is required by
# the schema — if no project matches, we ASK before creating one.
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

# ---------------------------------------------------------------------------
# Sitename of the page the user is on. Never silently invent CSC when a real
# site is in stash/session.
# ---------------------------------------------------------------------------
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
    my $u = $c->session->{username} || '';
    return 1 if !$u || lc($u) eq 'guest';
    return 0;
}

sub _norm {
    my ($s) = @_;
    $s = lc($s // '');
    $s =~ s/[^a-z0-9]+/ /g;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

# Testable: rank an in-memory list of project hashes.
# Each hash: { id, name, project_code, parent_id }
# Returns the list sorted by score desc, with {score} added. Score 0 dropped.
sub rank_projects {
    my ($self, $query, $projects) = @_;
    $projects ||= [];
    my $qn = _norm($query);
    return [] unless length $qn && ref $projects eq 'ARRAY';

    my @qtok = grep { length $_ > 1 } split /\s+/, $qn;
    my @out;
    for my $p (@$projects) {
        next unless ref $p eq 'HASH';
        my $nn = _norm($p->{name});
        my $cn = _norm($p->{code} // $p->{project_code});
        my $score = 0;
        $score += 120 if length $cn && $cn eq $qn;
        $score += 100 if length $nn && $nn eq $qn;
        $score += 70  if length $nn && index($nn, $qn) == 0;
        $score += 45  if length $nn && index($nn, $qn) >= 0;
        $score += 50  if length $cn && index($cn, $qn) >= 0;
        if (@qtok) {
            my %nt = map { $_ => 1 } grep { length $_ > 1 } split /\s+/, "$nn $cn";
            my $hit = grep { $nt{$_} } @qtok;
            $score += 18 * $hit;
        }
        $score += 6 if $p->{parent_id};    # prefer a sub-project when tied
        next unless $score > 0;
        push @out, { %$p, score => $score };
    }
    return [ sort { $b->{score} <=> $a->{score} || ($a->{id} || 0) <=> ($b->{id} || 0) } @out ];
}

sub _schema {
    my ($self, $c) = @_;
    return eval { $c->model('DBEncy')->schema };
}

sub _project_row_hash {
    my ($self, $row) = @_;
    return unless $row;
    return {
        id           => 0 + ($row->id // 0),
        name         => $row->name // '',
        project_code => $row->project_code // '',
        parent_id    => $row->parent_id,
        sitename     => eval { $row->sitename } // '',
        status       => eval { $row->status } // '',
    };
}

# Projects visible on this SiteName (plus a few well-known parents that
# children on this site may hang off). Capped.
sub list_site_projects {
    my ($self, $c, %opts) = @_;
    my $limit = $opts{limit} || 80;
    $limit = 80 if $limit > 80;
    my $sitename = $opts{sitename} || $self->sitename($c);
    my $schema = $self->_schema($c) or return [];
    my @rows;
    eval {
        my $rs = $schema->resultset('Project')->search(
            { sitename => $sitename },
            { order_by => ['name'], rows => $limit },
        );
        while (my $p = $rs->next) {
            push @rows, $self->_project_row_hash($p);
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'list_site_projects', "Failed listing projects for sitename=$sitename: $@");
        return [];
    }
    return \@rows;
}

# Match a project for a draft todo. Returns
#   { status => 'exact'|'ambiguous'|'none'|'found',
#     sitename, query, project?, candidates => [] }
sub match_project {
    my ($self, $c, %args) = @_;
    my $sitename = $args{sitename} || $self->sitename($c);
    my $schema   = $self->_schema($c);

    my $out = {
        status     => 'none',
        sitename   => $sitename,
        query      => '',
        project    => undef,
        candidates => [],
    };
    return $out unless $schema;

    # 1. Explicit id wins (user/model picked it). Sitename mismatch is a warning.
    my $pid = $args{project_id};
    if (defined $pid && $pid =~ /^\d+$/ && $pid > 0) {
        my $row = eval { $schema->resultset('Project')->find($pid) };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                'match_project', "Project find($pid) failed: $@");
        }
        if ($row) {
            my $h = $self->_project_row_hash($row);
            $out->{status}  = 'exact';
            $out->{project} = $h;
            $out->{query}   = "#$pid";
            my $ps = $h->{sitename} || '';
            if ($ps && lc($ps) ne lc($sitename)) {
                $out->{sitename_mismatch} = 1;
                $out->{project_sitename}  = $ps;
            }
            return $out;
        }
    }

    # 2. Page URL ?project_id=N (todo/project pages)
    my $page = $args{page_path} // '';
    if ($page =~ /[?&]project_id=(\d+)/) {
        my $from_url = $1;
        my $row = eval { $schema->resultset('Project')->find($from_url) };
        if ($row) {
            $out->{status}  = 'exact';
            $out->{project} = $self->_project_row_hash($row);
            $out->{query}   = "page project_id=$from_url";
            return $out;
        }
    }

    my @site = @{ $self->list_site_projects($c, sitename => $sitename) };

    # 3. Explicit code
    my $code = $args{project_code} // '';
    $code =~ s/^\s+|\s+$//g;
    if (length $code) {
        $out->{query} = $code;
        my ($hit) = grep { lc($_->{project_code} || '') eq lc($code) } @site;
        if ($hit) {
            $out->{status}  = 'exact';
            $out->{project} = $hit;
            return $out;
        }
        # fall through to name ranking using the code as query
    }

    my $q = $args{project_name} || $args{query} || $code || $args{subject} || '';
    $q =~ s/^\s+|\s+$//g;
    $out->{query} = $q;
    return $out unless length $q && @site;

    my $ranked = $self->rank_projects($q, \@site);
    return $out unless @$ranked;

    my $top = $ranked->[0];
    my $second = $ranked->[1];
    if ($top->{score} >= 40 && (!$second || ($top->{score} - $second->{score}) >= 12)) {
        $out->{status}  = 'exact';
        $out->{project} = $top;
        $out->{candidates} = [ splice @$ranked, 0, 5 ];
        return $out;
    }
    if ($top->{score} >= 18) {
        $out->{status}     = 'ambiguous';
        $out->{candidates} = [ splice @$ranked, 0, 8 ];
        return $out;
    }
    $out->{status}     = 'none';
    $out->{candidates} = [ splice @$ranked, 0, 5 ];
    return $out;
}

sub similar_open_todos {
    my ($self, $c, $project_id, $subject) = @_;
    return [] unless $project_id && $subject;
    my $schema = $self->_schema($c) or return [];
    my $stem = substr($subject, 0, 40);
    $stem =~ s/[%_]/ /g;
    my @hits;
    eval {
        my $rs = $schema->resultset('Todo')->search(
            {
                project_id => $project_id,
                subject    => { -like => "%$stem%" },
                status     => { -not_in => [ 'COMPLETED', 'CANCELLED', '3', '4', 3, 4 ] },
            },
            { rows => 5, order_by => { -desc => 'record_id' } },
        );
        while (my $t = $rs->next) {
            push @hits, {
                record_id => 0 + ($t->record_id // 0),
                subject   => $t->subject // '',
                status    => $t->status // '',
            };
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__,
            'similar_open_todos', "Lookup failed project=$project_id: $@");
        return [];
    }
    return \@hits;
}

# Natural-language "add a todo …" — do NOT rely on the model emitting [ACTION:].
# Small/free models invent fake UI instead of calling the tool. Chat intercepts
# this before the LLM so a todo is actually created.
sub detect_create_intent {
    my ($self, $prompt) = @_;
    return unless defined $prompt && $prompt =~ /\S/;
    my $p = $prompt;
    $p =~ s/^\s+|\s+$//g;

    return if $p =~ /^(how\s+(do\s+i|to)|what\s+is|explain|where\s+(is|do))\b/i;
    return if $p =~ /\b(top\s*5|list (my |the )?(todos|tasks)|which todo|show (me )?(my )?todos)\b/i;
    return unless $p =~ /\b(add|create|make|file|track)\b/i
               && $p =~ /\b(todos?|tasks?|to-dos?|to dos?)\b/i;

    my $rest = $p;
    $rest =~ s/^(please\s+)//i;
    $rest =~ s/^(can you|could you|would you|will you)\s+(please\s+)?//i;
    $rest =~ s/^(add|create|make|file|track)\s+(me\s+)?(a\s+|an\s+|new\s+)*((todo|task|to-do|to do)s?)(\s+item)?\s*//i;
    $rest =~ s/^(to\s+the\s+|to\s+|for\s+the\s+|for\s+|:\s*|-\s*)//i;
    $rest =~ s/\s+/ /g;
    $rest =~ s/^\s+|\s+$//g;

    my $subject = $rest;
    my $project_name = '';
    if ($rest =~ /^(.+?)\s+to\s+(.+)$/i && length($1) < 60) {
        $project_name = $1;
        $project_name =~ s/^(the\s+)//i;
        $subject = $2;
    }
    $subject =~ s/^(to\s+|for\s+)//i;
    $subject =~ s/^\s+|\s+$//g;
    return unless length $subject >= 3;

    return {
        subject      => $subject,
        project_name => $project_name,
        description  => $prompt,
    };
}

# Fill planning-queue fields the user usually omits or has forgotten.
# Two layers:
#   inferred  — we pick a value from intent + how Focus Queue works
#   pending   — LOOKUP_TODOS / LOOKUP_PROJECTS / READ_DOCS may refine later
# Ask the user only for blockers (no subject, no project at all). Do not quiz
# them on ap_score / scheduled_date.
sub enrich_parse {
    my ($self, $intent) = @_;
    return $intent unless $intent && ref $intent eq 'HASH';
    my $raw = $intent->{description} // $intent->{subject} // '';
    my $today = $self->_today;
    my @inferred;
    my @pending = qw(LOOKUP_TODOS LOOKUP_PROJECTS READ_DOCS);

    my $pri = $intent->{priority};
    if (!defined $pri || $pri eq '') {
        if ($raw =~ /\b(urgent|asap|critical|p\s*1|priority\s*1)\b/i) {
            $pri = 1; push @inferred, 'priority=1 from urgent/asap language';
        }
        elsif ($raw =~ /\b(p\s*2|priority\s*2|high priority)\b/i) {
            $pri = 2; push @inferred, 'priority=2 from high-priority language';
        }
        else {
            $pri = 3; push @inferred, 'priority=3 default (not specified; Focus Queue still sees NEW below in-progress work)';
        }
        $intent->{priority} = $pri;
    }

    my $due = $intent->{due_date} // '';
    if ($due !~ /^\d{4}-\d{2}-\d{2}$/) {
        if ($raw =~ /\btoday\b/i) {
            $due = $today; push @inferred, "due_date=$due from 'today'";
        }
        elsif ($raw =~ /\btomorrow\b/i) {
            $due = DateTime->now->add(days => 1)->ymd; push @inferred, "due_date=$due from 'tomorrow'";
        }
        elsif ($raw =~ /\bthis week\b/i) {
            $due = DateTime->now->add(days => 7)->ymd; push @inferred, "due_date=$due from 'this week'";
        }
        else {
            $due = DateTime->now->add(days => 7)->ymd;
            push @inferred, "due_date=$due default (+7 days; not specified)";
        }
        $intent->{due_date} = $due;
    }

    # scheduled_date is what Daily Plan / Focus Queue uses. Users almost never
    # remember this field. Default today so the todo is eligible; status NEW
    # so it does not jump ahead of in-progress rows.
    $intent->{scheduled_date} = $today;
    push @inferred, "scheduled_date=$today so it can appear in the planning queue (user did not set this)";
    $intent->{status} = 1 unless defined $intent->{status} && $intent->{status} ne '';
    push @inferred, 'status=NEW — will not outrank in-progress todos in the Focus Queue';

    $intent->{_inferred} = \@inferred;
    $intent->{_pending_agents} = \@pending;
    my $note = "Inferred by Todo-create parse:\n- " . join("\n- ", @inferred)
             . "\nPending agent fill-in: " . join(', ', @pending);
    if ($intent->{comments}) {
        $intent->{comments} .= "\n$note";
    }
    else {
        $intent->{comments} = $note;
    }
    return $intent;
}

sub subject_needs_clarify {
    my ($self, $subject) = @_;
    return 1 unless defined $subject && length $subject >= 3;
    return 1 if $subject =~ /^(this|that|it|something|stuff|one|a thing)\b/i;
    return 0;
}

# todo.subject is varchar(255). Chat often dumps the whole request into subject,
# which raised Application Error Audit #2344 (Data too long for column 'subject').
# Keep a short title on subject; move overflow into description (text).
use constant SUBJECT_MAX => 255;

sub normalize_subject_description {
    my ($self, $subject, $description) = @_;
    $subject = defined $subject ? $subject : '';
    $description = defined $description ? $description : '';
    $subject =~ s/^\s+|\s+$//g;
    $description =~ s/^\s+|\s+$//g;
    return ($subject, $description) unless length $subject > SUBJECT_MAX;

    my $max = SUBJECT_MAX;
    my $head = substr($subject, 0, $max);
    # Prefer a clean break on whitespace/punctuation near the end of the head.
    if ($head =~ /^(.*[\s,;:\-\.])\S*$/s && length($1) >= int($max * 0.55)) {
        $head = $1;
        $head =~ s/\s+$//;
    }
    my $overflow = substr($subject, length($head));
    $overflow =~ s/^\s+//;
    $subject = $head;
    if (length $overflow) {
        if (length $description) {
            $description = $overflow . "\n\n" . $description
                unless index($description, $overflow) == 0;
        }
        else {
            $description = $overflow;
        }
    }
    return ($subject, $description);
}

# Short-circuit /ai2/chat when the user asked to create a todo.
# Returns a chat-shaped hash (handled=>1) or undef to fall through to the LLM.
sub try_chat_create {
    my ($self, $c, %args) = @_;
    my $intent = $self->detect_create_intent($args{prompt} // '') or return;
    if ($self->_is_guest($c)) {
        return {
            handled     => 1,
            success     => 1,
            response    => 'Log in to create a todo from chat.',
            model       => '(todo-create)',
            provider    => 'ai2-todo',
            todo_action => { success => JSON::false, error => 'Login required' },
        };
    }
    if ($self->subject_needs_clarify($intent->{subject})) {
        return {
            handled     => 1,
            success     => 1,
            response    => 'I can create the todo, but I need a short subject. What should it be called?',
            model       => '(todo-create)',
            provider    => 'ai2-todo',
            todo_action => {
                success       => JSON::false,
                need_clarify  => JSON::true,
                field         => 'subject',
                draft         => $intent,
                message       => 'Subject is too vague.',
            },
        };
    }
    $self->enrich_parse($intent);
    my $created = eval {
        $self->create_from_params($c, {
            %$intent,
            page_path => $args{page_path} || '',
        });
    };
    if ($@ || !$created) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'try_chat_create', "create_from_params threw: $@");
        $created = { success => JSON::false, error => 'Todo create failed' };
    }
    my $msg = $created->{message} || $created->{error} || 'Todo request processed.';
    if ($created->{success} && $created->{todo_url}) {
        $msg .= ' ' . $created->{todo_url};
        my $inf = $intent->{_inferred} || [];
        if (@$inf) {
            $msg .= "\nI filled in planning fields you did not give (you can change them; other agents can refine): "
                 . join('; ', @$inf);
        }
    }
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'try_chat_create',
        'Chat todo intent: ' . ($created->{success} ? "created #$created->{todo_id}" : ($created->{need_project} ? 'need_project' : ($created->{need_pick} ? 'need_pick' : ($created->{error} || 'no-create')))));
    return {
        handled     => 1,
        success     => 1,
        response    => $msg,
        model       => '(todo-create)',
        provider    => 'ai2-todo',
        todo_action => $created,
    };
}

# Catalog snippet + ACTION contract injected into every logged-in chat turn.
sub chat_contract {
    my ($self, $c) = @_;
    return '' if $self->_is_guest($c);
    my $sitename = $self->sitename($c);
    my $projects = $self->list_site_projects($c, sitename => $sitename, limit => 30);
    my $list = '';
    if (@$projects) {
        $list = "Projects on this site (use id/code/name — do NOT invent ids):\n";
        for my $p (@$projects) {
            my $parent = $p->{parent_id} ? " parent#$p->{parent_id}" : '';
            $list .= sprintf("  #%s %s — %s%s\n",
                $p->{id}, $p->{project_code} || '-', $p->{name} || '(unnamed)', $parent);
        }
    } else {
        $list = "No projects listed for this SiteName yet.\n";
    }

    return <<"END";
TODO CREATION + TIME TRACKING (SiteName=$sitename):
When the user asks to add, create, or track a todo/task:
1. Extract a SHORT subject (required, max 255 chars — a title, not the whole message), optional description (put long detail here), due_date (YYYY-MM-DD), priority (1=highest … 5=lowest, default 3).
2. If they named a project, put it in params.project_name or project_code or project_id. Prefer a sub-project when both a parent and a child match.
3. Emit exactly one ACTION on its own line (do not invent a project_id if you are unsure):
[ACTION: {"action":"create_todo","params":{"subject":"...","description":"...","project_name":"...","due_date":"YYYY-MM-DD","priority":3}}]
4. The server matches against $sitename projects. If none match it will ASK the user whether to create a new project — do not create a project yourself unless they already said yes.
5. Do not emit create_todo unless the user asked to track/add/create a todo.

TIME TRACKING (start/stop work on an EXISTING todo):
- "Start/track/work on todo #N" → [ACTION: {"action":"start_todo","params":{"todo_id":N}}]
- "Stop/done working/pause todo #N" → [ACTION: {"action":"stop_todo","params":{"todo_id":N},"notes":"optional summary"}]
- start_todo opens a timer (status IN PROGRESS); stop_todo closes it and reports minutes logged.
- Only use these with a REAL numeric todo id from live data or the conversation — never invent one.

$list
END
}

sub _today { DateTime->now->ymd }

sub _status_text {
    my ($raw) = @_;
    my %map = ( 1 => 'NEW', 2 => 'IN PROGRESS', 3 => 'COMPLETED', 4 => 'CANCELLED' );
    $raw //= 1;
    return $map{$raw} if exists $map{$raw};
    return $raw if $raw =~ /^[A-Za-z]/;
    return 'NEW';
}

sub _insert_project {
    my ($self, $c, %args) = @_;
    my $schema   = $self->_schema($c) or return (undef, 'Database not available');
    my $sitename = $args{sitename} || $self->sitename($c);
    my $name     = $args{name} or return (undef, 'name required');
    my $user     = $args{user} || $c->session->{username} || 'ai';
    my $today    = $self->_today;
    my $due      = $args{due_date} || DateTime->now->add(months => 1)->ymd;
    $due = DateTime->now->add(months => 1)->ymd unless $due =~ /^\d{4}-\d{2}-\d{2}$/;
    my $roles    = $c->session->{roles} || [];
    my $group    = ref $roles eq 'ARRAY' && @$roles ? $roles->[0] : 'user';
    my $code     = $args{project_code} || lc($name);
    $code =~ s/[^a-z0-9]+/_/g;
    $code = substr($code, 0, 40);
    $code ||= 'proj';
    my $parent_id = ($args{parent_id} && $args{parent_id} =~ /^\d+$/) ? $args{parent_id} : undef;

    my $row;
    eval {
        $row = $schema->resultset('Project')->create({
            name               => $name,
            description        => $args{description} || '',
            sitename           => $sitename,
            status             => $args{status} || 'NEW',
            start_date         => $today,
            end_date           => $due,
            project_code       => $code,
            username_of_poster => $user,
            group_of_poster    => $group,
            date_time_posted   => $today,
            developer_name     => $user,
            record_id          => 0,
            project_size       => 0,
            estimated_man_hours=> 0,
            client_name        => '',
            comments           => $args{comments} || 'Created from Chat-with-AI',
            ($parent_id ? (parent_id => $parent_id) : ()),
        });
    };
    if ($@ || !$row) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'insert_project', "create_project failed sitename=$sitename name='$name': $@");
        return (undef, 'Project creation failed');
    }
    return ($row, undef);
}

sub _insert_todo {
    my ($self, $c, %args) = @_;
    my $schema   = $self->_schema($c) or return (undef, 'Database not available');
    my $sitename = $args{sitename} || $self->sitename($c);
    my $subject  = $args{subject} or return (undef, 'subject required');
    my $project  = $args{project} or return (undef, 'project required');
    my $user     = $args{user} || $c->session->{username} || 'ai';
    my $user_id  = $c->session->{user_id} || 1;
    my $today    = $self->_today;
    my $due      = $args{due_date} || DateTime->now->add(days => 7)->ymd;
    $due = DateTime->now->add(days => 7)->ymd unless $due =~ /^\d{4}-\d{2}-\d{2}$/;
    my $roles    = $c->session->{roles} || [];
    my $group    = ref $roles eq 'ARRAY' && @$roles ? $roles->[0] : 'user';
    my $code     = $project->{project_code} || '';
    # Defense in depth: never INSERT a subject longer than the column
    # (Application Error Audit #2344 — Data too long for column 'subject').
    my $description = $args{description} // '';
    ($subject, $description) = $self->normalize_subject_description($subject, $description);
    my $row;
    eval {
        $row = $schema->resultset('Todo')->create({
            sitename            => $sitename,
            start_date          => $today,
            parent_todo         => '',
            due_date            => $due,
            subject             => $subject,
            description         => $description,
            estimated_man_hours => 0,
            comments            => $args{comments} // '',
            reporter            => $user,
            company_code        => 'default',
            owner               => $user,
            project_code        => $code,
            developer           => $user,
            username_of_poster  => $user,
            status              => _status_text($args{status}),
            priority            => ((defined $args{priority} && $args{priority} =~ /^\d+$/) ? $args{priority} : 3),
            share               => 0,
            last_mod_by         => $user,
            last_mod_date       => $today,
            user_id             => $user_id,
            group_of_poster     => $group,
            project_id          => $project->{id},
            date_time_posted    => $today,
            scheduled_date      => $today,
            sort_order          => 0,
        });
    };
    if (($@ || !$row) && $@ && $@ =~ /scheduled_date|Unknown column/i) {
        $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__,
            'insert_todo', "Retry without scheduled_date: $@");
        eval {
            $row = $schema->resultset('Todo')->create({
                sitename            => $sitename,
                start_date          => $today,
                parent_todo         => '',
                due_date            => $due,
                subject             => $subject,
                description         => $description,
                estimated_man_hours => 0,
                comments            => $args{comments} // '',
                reporter            => $user,
                company_code        => 'default',
                owner               => $user,
                project_code        => $code,
                developer           => $user,
                username_of_poster  => $user,
                status              => _status_text($args{status}),
                priority            => ((defined $args{priority} && $args{priority} =~ /^\d+$/) ? $args{priority} : 3),
                share               => 0,
                last_mod_by         => $user,
                last_mod_date       => $today,
                user_id             => $user_id,
                group_of_poster     => $group,
                project_id          => $project->{id},
                date_time_posted    => $today,
            });
        };
    }
    if ($@ || !$row) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'insert_todo', "create_todo failed sitename=$sitename subject='$subject': $@");
        return (undef, 'Todo creation failed');
    }
    return ($row, undef);
}

sub _draft_from_params {
    my ($self, $params) = @_;
    $params ||= {};
    my ($subject, $description) = $self->normalize_subject_description(
        $params->{subject} || '',
        $params->{description} || '',
    );
    return {
        subject        => $subject,
        description    => $description,
        due_date       => $params->{due_date} || '',
        priority       => $params->{priority} // 3,
        status         => $params->{status} // 1,
        project_id     => $params->{project_id},
        project_code   => $params->{project_code} || '',
        project_name   => $params->{project_name} || '',
        page_path      => $params->{page_path} || '',
        comments       => $params->{comments} || '',
    };
}

# Called from Actions. Does NOT write the HTTP response — returns a hash.
sub create_from_params {
    my ($self, $c, $params) = @_;
    $params ||= {};
    my $user = $c->session->{username} || 'ai';
    my $sitename = $self->sitename($c);
    my $draft = $self->_draft_from_params($params);
    my $subject = $draft->{subject};
    return { success => JSON::false, error => 'subject required' } unless $subject;

    my $match = $self->match_project($c,
        sitename     => $sitename,
        project_id   => $draft->{project_id},
        project_code => $draft->{project_code},
        project_name => $draft->{project_name},
        subject      => $subject,
        page_path    => $draft->{page_path},
        query        => $params->{query},
    );

    my $want_new = $params->{create_project} || $params->{create_project_confirmed};

    if ($match->{status} eq 'ambiguous' && !$want_new) {
        return {
            success    => JSON::false,
            need_pick  => JSON::true,
            sitename   => $sitename,
            draft      => $draft,
            candidates => $match->{candidates} || [],
            message    => "Several $sitename projects could fit. Which one?",
        };
    }

    if ($match->{status} eq 'none' || (!$match->{project} && $match->{status} ne 'exact')) {
        if ($want_new) {
            my $pname = $params->{new_project_name} || $draft->{project_name} || $subject;
            my ($prow, $perr) = $self->_insert_project($c,
                sitename    => $sitename,
                name        => $pname,
                description => $draft->{description},
                user        => $user,
                parent_id   => $params->{parent_id},
            );
            return { success => JSON::false, error => $perr || 'Project creation failed' } unless $prow;
            $match->{status}  = 'exact';
            $match->{project} = $self->_project_row_hash($prow);
            $match->{created_project} = 1;
        }
        else {
            return {
                success      => JSON::false,
                need_project => JSON::true,
                sitename     => $sitename,
                draft        => $draft,
                candidates   => $match->{candidates} || [],
                message      => "No project on $sitename matches. Create a new project for this todo?",
            };
        }
    }

    my $project = $match->{project};
    return {
        success      => JSON::false,
        need_project => JSON::true,
        sitename     => $sitename,
        draft        => $draft,
        candidates   => $match->{candidates} || [],
        message      => "No project on $sitename matches. Create a new project for this todo?",
    } unless $project && $project->{id};

    my $similar = $self->similar_open_todos($c, $project->{id}, $subject);

    my ($todo, $terr) = $self->_insert_todo($c,
        sitename    => $sitename,
        subject     => $subject,
        description => $draft->{description},
        due_date    => $draft->{due_date},
        priority    => $draft->{priority},
        status      => $draft->{status},
        comments    => $draft->{comments},
        project     => $project,
        user        => $user,
    );
    return { success => JSON::false, error => $terr || 'Todo creation failed' } unless $todo;

    my $new_id = $todo->record_id // $todo->id // 0;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_from_params',
        "AI todo #$new_id sitename=$sitename project=$project->{id} subject='$subject' by=$user");

    # AGENT HANDOFF (AISYSTEM plan §3d, Phase A): after WRITE, spin up the
    # TodoRank agent scoped to this project. Dry-run ONLY — it returns
    # proposed priority/type/due for the new row as advisory text; nothing is
    # written until someone reviews and re-runs with apply:true.
    my $rank_note = $self->rank_handoff($c,
        todo_id     => $new_id,
        project_id  => $project->{id},
        sitename    => $sitename,
        model       => $params->{rank_model},
    );

    my $message = "Todo #$new_id created on $sitename / $project->{name}";
    if ($rank_note && $rank_note->{suggestion}) {
        $message .= "\nTodoRank agent reviewed it (dry-run): " . $rank_note->{suggestion}
                 .  " — say \"apply rank suggestions\" to write them.";
    }
    elsif ($rank_note && $rank_note->{error}) {
        $message .= "\n(TodoRank review unavailable: $rank_note->{error})";
    }

    return {
        success      => JSON::true,
        message      => $message,
        todo_id      => 0 + $new_id,
        todo_url     => "/todo/details?record_id=$new_id",
        project_id   => 0 + $project->{id},
        project_name => $project->{name},
        project_code => $project->{project_code} || '',
        project_url  => "/project/details?project_id=$project->{id}",
        sitename     => $sitename,
        created_project => $match->{created_project} ? JSON::true : JSON::false,
        similar      => $similar,
        sitename_mismatch => $match->{sitename_mismatch} ? JSON::true : JSON::false,
        rank_review  => $rank_note,
    };
}

# ---------------------------------------------------------------------------
# Spin up the AI2::TodoRank agent for ONE freshly created todo (Phase A of the
# agent-spawn chain: Task Assistant → TodoRank). Advisory/dry-run only:
# proposes {priority, todo_type, due_date} + reason; never writes here.
# Failure is NON-FATAL and reported in-band — a ranking outage must not make
# the user think their todo was lost.
# Returns { suggestion?, proposals?{}, error?, skipped? }.
# ---------------------------------------------------------------------------
sub rank_handoff {
    my ($self, $c, %args) = @_;
    my $todo_id = $args{todo_id} or return { skipped => 'no todo_id' };

    my $rank = eval { $c->model('AI2::TodoRank') };
    return { error => 'TodoRank agent not available' } unless $rank;

    my ($rows, $rbid) = eval {
        $rank->gather_todos($c, project_id => $args{project_id},
                                 sitename  => $args{sitename});
    };
    if ($@ || !ref($rows)) {
        return { error => 'could not gather todos' };
    }
    my ($mine) = grep { ($_->{record_id} // 0) == $todo_id } @$rows;
    return { skipped => 'new todo not in gather scope' } unless $mine;

    # Same NO-default-model rule as FocusTune: the caller must name the model
    # (params.rank_model). Without one we skip rather than guess.
    return { skipped => 'no rank_model given' } unless $args{model} && "$args{model}" =~ /\S/;
    my ($system, $user_prompt) = $rank->build_prompt([$mine], {
        sitename => $args{sitename},
    });
    my $res = $rank->run_batch($c, { name => $args{model} }, $system, $user_prompt);
    return { error => ($res && $res->{error}) || 'AI ranking unavailable' }
        unless $res && $res->{success};

    my $parsed = $rank->parse_result($res, [$todo_id]);
    my $prop = $parsed->{proposals}{$todo_id};
    return { skipped => 'agent had no change to suggest' } unless $prop && %$prop;

    my @parts;
    push @parts, "priority $prop->{priority}"       if defined $prop->{priority};
    push @parts, "type '$prop->{todo_type}'"        if $prop->{todo_type};
    push @parts, "due $prop->{due_date}"            if $prop->{due_date};
    my $sugg = @parts ? ucfirst(join(', ', @parts)) : '';
    $sugg .= " — $prop->{reason}" if $prop->{reason};
    return { suggestion => $sugg, proposals => $prop };
}

sub resolve_from_params {
    my ($self, $c, $params) = @_;
    $params ||= {};
    my $sitename = $self->sitename($c);
    my $match = $self->match_project($c,
        sitename     => $sitename,
        project_id   => $params->{project_id},
        project_code => $params->{project_code},
        project_name => $params->{project_name},
        subject      => $params->{subject},
        page_path    => $params->{page_path},
        query        => $params->{query},
    );
    my $all = $self->list_site_projects($c, sitename => $sitename, limit => 40);
    return {
        success    => JSON::true,
        sitename   => $sitename,
        status     => $match->{status},
        query      => $match->{query},
        project    => $match->{project},
        candidates => $match->{candidates} || [],
        projects   => $all,
        draft      => $self->_draft_from_params($params),
    };
}

sub write_json {
    my ($self, $c, $status, $payload) = @_;
    $c->response->status($status || 200);
    $c->response->content_type('application/json; charset=utf-8');
    $c->response->body(encode_json($payload));
}

sub perform_create {
    my ($self, $c, $params) = @_;
    my $result = $self->create_from_params($c, $params);
    my $http = 200;
    $http = 400 if !$result->{success} && $result->{error} && !$result->{need_project} && !$result->{need_pick};
    $http = 500 if ($result->{error} || '') =~ /failed|not available/i && !$result->{need_project};
    $self->write_json($c, $http, $result);
}

sub perform_resolve {
    my ($self, $c, $params) = @_;
    my $result = eval { $self->resolve_from_params($c, $params) };
    if ($@ || !$result) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'perform_resolve', "resolve failed: $@");
        $self->write_json($c, 500, { success => JSON::false, error => 'Project resolve failed' });
        return;
    }
    $self->write_json($c, 200, $result);
}

__PACKAGE__->meta->make_immutable;
1;
