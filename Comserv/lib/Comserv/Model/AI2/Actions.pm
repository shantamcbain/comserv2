package Comserv::Model::AI2::Actions;
# v2 port of v1 Controller::AI /ai/action — agentic write actions
# (todos, projects, helpdesk, constituents, yards/hives/queens/inspections).
# Body ported verbatim from Controller::AI::action (2026-07-24); the model
# writes the JSON response directly, controller stays thin.
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

sub perform {
    my ($self, $c) = @_;

    $c->response->content_type('application/json; charset=utf-8');

    # Only POST accepted
    unless ($c->request->method eq 'POST') {
        $c->response->status(405);
        $c->response->body(encode_json({ success => JSON::false, error => 'Method not allowed' }));
        return;
    }

    # Guests may not write
    my $is_guest = !$c->session->{username} || lc($c->session->{username}) eq 'guest';
    if ($is_guest) {
        $c->response->status(403);
        $c->response->body(encode_json({ success => JSON::false, error => 'Login required to perform this action' }));
        return;
    }

    # Parse JSON body
    my $body_text;
    if ($c->req->can('content')) {
        $body_text = $c->req->content;
    } else {
        my $body = $c->req->body;
        if (ref($body) && $body->can('seek')) {
            seek($body, 0, 0);
            $body_text = do { local $/; <$body> };
        } else {
            $body_text = $body;
        }
    }
    my $req;
    eval { $req = decode_json($body_text) } if $body_text;
    if ($@ || !ref $req) {
        $c->response->status(400);
        $c->response->body(encode_json({ success => JSON::false, error => 'Invalid JSON body' }));
        return;
    }

    my $action_name = $req->{action} || '';
    my $params      = $req->{params} || {};
    my $current_user = $c->session->{username} || 'ai';
    my $today        = DateTime->now->ymd;

    my $schema = eval { $c->model('DBEncy')->schema };
    unless ($schema) {
        $c->response->status(500);
        $c->response->body(encode_json({ success => JSON::false, error => 'Database not available' }));
        return;
    }

    # ── update_todo_status ────────────────────────────────────────────────────
    if ($action_name eq 'update_todo_status') {
        my $todo_id = $params->{todo_id} or do {
            $c->response->status(400);
            $c->response->body(encode_json({ success => JSON::false, error => 'todo_id required' }));
            return;
        };
        my $new_status = $params->{status};
        unless (defined $new_status && $new_status =~ /^\d+$/) {
            $c->response->status(400);
            $c->response->body(encode_json({ success => JSON::false, error => 'status (numeric) required' }));
            return;
        }
        my $todo = eval { $schema->resultset('Todo')->find($todo_id) };
        unless ($todo) {
            $c->response->status(404);
            $c->response->body(encode_json({ success => JSON::false, error => "Todo #$todo_id not found" }));
            return;
        }
        eval { $todo->update({ status => $new_status, last_mod_by => $current_user, last_mod_date => $today }) };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'action', "update_todo_status failed: $@");
            $c->response->status(500);
            $c->response->body(encode_json({ success => JSON::false, error => 'Update failed' }));
            return;
        }
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'action',
            "AI action update_todo_status: todo=$todo_id status=$new_status by=$current_user");
        $c->response->body(encode_json({ success => JSON::true, message => "Todo #$todo_id status updated to $new_status" }));
        return;
    }

    # ── update_todo ───────────────────────────────────────────────────────────
    if ($action_name eq 'update_todo') {
        my $todo_id = $params->{todo_id} or do {
            $c->response->status(400);
            $c->response->body(encode_json({ success => JSON::false, error => 'todo_id required' }));
            return;
        };
        my $todo = eval { $schema->resultset('Todo')->find($todo_id) };
        unless ($todo) {
            $c->response->status(404);
            $c->response->body(encode_json({ success => JSON::false, error => "Todo #$todo_id not found" }));
            return;
        }
        my %changes = (last_mod_by => $current_user, last_mod_date => $today);
        $changes{subject}     = $params->{subject}     if defined $params->{subject}     && $params->{subject}     ne '';
        $changes{description} = $params->{description} if defined $params->{description};
        $changes{comments}    = $params->{comments}    if defined $params->{comments};
        $changes{due_date}    = $params->{due_date}    if defined $params->{due_date}    && $params->{due_date} =~ /^\d{4}-\d{2}-\d{2}$/;
        $changes{priority}    = $params->{priority}    if defined $params->{priority}    && $params->{priority} =~ /^\d+$/;

        if (keys(%changes) <= 2) {
            $c->response->status(400);
            $c->response->body(encode_json({ success => JSON::false, error => 'No updatable fields provided (subject, description, comments, due_date, priority)' }));
            return;
        }
        eval { $todo->update(\%changes) };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'action', "update_todo failed: $@");
            $c->response->status(500);
            $c->response->body(encode_json({ success => JSON::false, error => 'Update failed' }));
            return;
        }
        my @updated = grep { $_ ne 'last_mod_by' && $_ ne 'last_mod_date' } keys %changes;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'action',
            "AI action update_todo: todo=$todo_id fields=@updated by=$current_user");
        $c->response->body(encode_json({ success => JSON::true, message => "Todo #$todo_id updated (" . join(', ', @updated) . ")" }));
        return;
    }

    # ── reschedule_todo ───────────────────────────────────────────────────────
    if ($action_name eq 'reschedule_todo') {
        my $todo_id  = $params->{todo_id}  or do {
            $c->response->status(400);
            $c->response->body(encode_json({ success => JSON::false, error => 'todo_id required' }));
            return;
        };
        my $new_due = $params->{due_date};
        unless ($new_due && $new_due =~ /^\d{4}-\d{2}-\d{2}$/) {
            $c->response->status(400);
            $c->response->body(encode_json({ success => JSON::false, error => 'due_date (YYYY-MM-DD) required' }));
            return;
        }
        my $todo = eval { $schema->resultset('Todo')->find($todo_id) };
        unless ($todo) {
            $c->response->status(404);
            $c->response->body(encode_json({ success => JSON::false, error => "Todo #$todo_id not found" }));
            return;
        }
        my $old_due   = $todo->due_date   // '';
        my $old_start = $todo->start_date // $today;
        eval { $todo->update({ due_date => $new_due, last_mod_by => $current_user, last_mod_date => $today }) };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'action', "reschedule_todo update failed: $@");
            $c->response->status(500);
            $c->response->body(encode_json({ success => JSON::false, error => 'Update failed' }));
            return;
        }
        # Audit interval
        if ($old_due ne $new_due) {
            eval {
                $schema->resultset('TodoInterval')->create({
                    todo_record_id => $todo_id,
                    start_date     => $old_start,
                    end_date       => $today,
                    interval_type  => 'rescheduled',
                    status         => "from:$old_due to:$new_due",
                    last_mod_by    => $current_user,
                    last_mod_date  => $today,
                });
            };
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'action',
                "reschedule interval create failed: $@") if $@;
        }
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'action',
            "AI action reschedule_todo: todo=$todo_id old=$old_due new=$new_due by=$current_user");
        $c->response->body(encode_json({ success => JSON::true, message => "Todo #$todo_id rescheduled to $new_due" }));
        return;
    }

    # ── create_log_entry ─────────────────────────────────────────────────────
    if ($action_name eq 'create_log_entry') {
        my $todo_id  = $params->{todo_id}  || 0;
        my $abstract = $params->{abstract} || 'AI-created log entry';
        my $details  = $params->{details}  || '';
        my $sitename = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';

        my $log_row;
        eval {
            $log_row = $schema->resultset('Log')->create({
                todo_record_id  => $todo_id || undef,
                username        => $current_user,
                sitename        => $sitename,
                start_date      => $today,
                due_date        => $today,
                project_code    => 'PLANNING',
                abstract        => $abstract,
                details         => $details,
                start_time      => '00:00:00',
                end_time        => '00:00:00',
                time            => '00:00:00',
                group_of_poster => do {
                    my $roles = $c->session->{roles} || [];
                    ref $roles eq 'ARRAY' ? join(',', @$roles) : ($roles || 'default');
                },
                status          => 1,
                priority        => 2,
                last_mod_by     => $current_user,
                last_mod_date   => $today,
            });
        };
        if ($@ || !$log_row) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'action', "create_log_entry failed: $@");
            $c->response->status(500);
            $c->response->body(encode_json({ success => JSON::false, error => 'Log creation failed' }));
            return;
        }
        my $log_id = $log_row->id // $log_row->record_id // '?';
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'action',
            "AI action create_log_entry: log=$log_id todo=$todo_id by=$current_user");
        $c->response->body(encode_json({ success => JSON::true, message => "Log entry #$log_id created", log_id => $log_id + 0 }));
        return;
    }

    # ── add_todo_comment ──────────────────────────────────────────────────────
    if ($action_name eq 'add_todo_comment') {
        my $todo_id = $params->{todo_id} or do {
            $c->response->status(400);
            $c->response->body(encode_json({ success => JSON::false, error => 'todo_id required' }));
            return;
        };
        my $comment = $params->{comment} || '';
        unless ($comment) {
            $c->response->status(400);
            $c->response->body(encode_json({ success => JSON::false, error => 'comment required' }));
            return;
        }
        my $todo = eval { $schema->resultset('Todo')->find($todo_id) };
        unless ($todo) {
            $c->response->status(404);
            $c->response->body(encode_json({ success => JSON::false, error => "Todo #$todo_id not found" }));
            return;
        }
        my $existing = $todo->comments // '';
        my $appended = $existing
            ? "$existing\n[$today $current_user] $comment"
            : "[$today $current_user] $comment";
        eval { $todo->update({ comments => $appended, last_mod_by => $current_user, last_mod_date => $today }) };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'action', "add_todo_comment failed: $@");
            $c->response->status(500);
            $c->response->body(encode_json({ success => JSON::false, error => 'Comment update failed' }));
            return;
        }
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'action',
            "AI action add_todo_comment: todo=$todo_id by=$current_user");
        $c->response->body(encode_json({ success => JSON::true, message => "Comment added to Todo #$todo_id" }));
        return;
    }

    # ── create_todo ───────────────────────────────────────────────────────────
    # Sitename + project matching lives in AI2::TodoCreate so chat, editor,
    # and /ai2/action share one brain (never dump onto project #1 / CSC).
    if ($action_name eq 'create_todo') {
        require Comserv::Model::AI2::TodoCreate;
        my $brain = eval { $c->model('AI2::TodoCreate') };
        $brain = Comserv::Model::AI2::TodoCreate->new if !$brain || !ref $brain;
        $brain->perform_create($c, $params);
        return;
    }

    # ── resolve_todo_project ──────────────────────────────────────────────────
    # Preview: which project on this SiteName would a draft todo land on?
    if ($action_name eq 'resolve_todo_project') {
        require Comserv::Model::AI2::TodoCreate;
        my $brain = eval { $c->model('AI2::TodoCreate') };
        $brain = Comserv::Model::AI2::TodoCreate->new if !$brain || !ref $brain;
        $brain->perform_resolve($c, $params);
        return;
    }

    # ── open_project_wizard ───────────────────────────────────────────────────
    # This is handled entirely client-side; the server just echoes the params back
    # so the JS wizard handler can pre-fill the form fields.
    if ($action_name eq 'open_project_wizard') {
        $c->response->body(encode_json({
            success       => JSON::true,
            action        => 'open_project_wizard',
            wizard_title  => $params->{title} || '',
            message       => 'Project wizard opened',
        }));
        return;
    }

    # ── create_project ────────────────────────────────────────────────────────
    if ($action_name eq 'create_project') {
        my $name = $params->{name};
        unless ($name) {
            $c->response->status(400);
            $c->response->body(encode_json({ success => JSON::false, error => 'name required' }));
            return;
        }
        my $description  = $params->{description}  || '';
        my $sitename     = $c->stash->{SiteName}  || $c->session->{SiteName} || 'CSC';
        my $parent_id    = ($params->{parent_id} && $params->{parent_id} =~ /^\d+$/) ? $params->{parent_id} : undef;
        my $status       = $params->{status}       || 'NEW';
        my $due_date     = $params->{due_date}     || do { DateTime->now->add(months => 1)->ymd };
        my $user_id      = $c->session->{user_id}  || 1;
        my $roles        = $c->session->{roles}    || [];
        my $group        = ref $roles eq 'ARRAY' && @$roles ? $roles->[0] : 'user';
        my $project_code = lc($name);
        $project_code    =~ s/[^a-z0-9]+/_/g;
        $project_code    = substr($project_code, 0, 40);

        my $new_project;
        eval {
            $new_project = $schema->resultset('Project')->create({
                name               => $name,
                description        => $description,
                sitename           => $sitename,
                status             => $status,
                start_date         => $today,
                end_date           => $due_date,
                project_code       => $project_code,
                username_of_poster => $current_user,
                group_of_poster    => $group,
                date_time_posted   => $today,
                developer_name     => $current_user,
                record_id           => 0,
                project_size        => 0,
                estimated_man_hours => 0,
                client_name         => '',
                comments            => '',
                ($parent_id ? (parent_id => $parent_id) : ()),
            });
        };
        if ($@ || !$new_project) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'action', "create_project failed: $@");
            $c->response->status(500);
            $c->response->body(encode_json({ success => JSON::false, error => 'Project creation failed' }));
            return;
        }
        my $new_id = $new_project->id // '?';
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'action',
            "AI action create_project: id=$new_id name='$name' sitename=$sitename by=$current_user");
        $c->response->body(encode_json({
            success     => JSON::true,
            message     => "Project #$new_id created: \"$name\"",
            project_id  => $new_id + 0,
            project_url => "/project/details?project_id=$new_id",
        }));
        return;
    }

    # ── create_helpdesk_ticket ────────────────────────────────────────────────
    if ($action_name eq 'create_helpdesk_ticket') {
        my $subject = $params->{subject};
        unless ($subject) {
            $c->response->status(400);
            $c->response->body(encode_json({ success => JSON::false, error => 'subject required' }));
            return;
        }
        my $description = $params->{description} || '';
        my $category    = $params->{category}    || 'General';
        my $priority    = $params->{priority}    || 'normal';
        my $email       = $params->{email}       || $c->session->{email} || '';
        my $site_name   = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
        my $user_id     = $c->session->{user_id} || undef;
        my $username    = $current_user;

        my $ticket_number = uc($site_name) . '-' . DateTime->now->strftime('%Y%m%d') . '-' . sprintf('%04d', int(rand(9999)) + 1);
        my $now_str = DateTime->now->strftime('%Y-%m-%d %H:%M:%S');

        my $new_ticket;
        eval {
            $new_ticket = $schema->resultset('SupportTicket')->create({
                ticket_number => $ticket_number,
                site_name     => $site_name,
                user_id       => $user_id,
                username      => $username,
                email         => $email,
                subject       => $subject,
                description   => $description,
                category      => $category,
                priority      => $priority,
                status        => 'open',
                created_at    => $now_str,
            });
        };
        if ($@ || !$new_ticket) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'action',
                "create_helpdesk_ticket failed: $@");
            $c->response->status(500);
            $c->response->body(encode_json({ success => JSON::false, error => 'Ticket creation failed' }));
            return;
        }
        my $ticket_id  = $new_ticket->id // '?';
        my $ticket_num = $new_ticket->ticket_number // $ticket_number;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'action',
            "AI action create_helpdesk_ticket: id=$ticket_id num=$ticket_num sitename=$site_name by=$username subject='$subject'");
        $c->response->body(encode_json({
            success       => JSON::true,
            message       => "Support ticket $ticket_num created: \"$subject\". An admin will be notified.",
            ticket_id     => $ticket_id + 0,
            ticket_number => $ticket_num,
            ticket_url    => "/HelpDesk/ticket/$ticket_num",
        }));
        return;
    }

    # ── sync_schema_field ─────────────────────────────────────────────────────
    # direction: "to_result" = update Result file to match DB
    #            "to_table"  = ALTER TABLE to match Result file
    if ($action_name eq 'sync_schema_field') {
        my $table     = $params->{table}     || '';
        my $field     = $params->{field}     || '';
        my $direction = $params->{direction} || '';
        my $database  = $params->{database}  || 'ency';

        unless ($table && $direction && $direction =~ /^(to_result|to_table)$/) {
            $c->response->status(400);
            $c->response->body(encode_json({ success => JSON::false,
                error => "sync_schema_field requires table, field (optional), direction (to_result|to_table)" }));
            return;
        }

        my $endpoint = ($direction eq 'to_result')
            ? '/admin/sync_table_to_result'
            : '/admin/sync_result_to_table';

        my $payload = encode_json({
            table    => $table,
            field    => $field || undef,
            database => $database,
        });

        my $result;
        eval {
            require LWP::UserAgent;
            require HTTP::Request;
            my $ua = LWP::UserAgent->new(timeout => 30);
            my $req = HTTP::Request->new(POST => $c->uri_for($endpoint));
            $req->content_type('application/json');
            $req->content($payload);
            # Forward session cookie
            my $cookie = $c->request->header('Cookie') || '';
            $req->header('Cookie' => $cookie) if $cookie;
            my $resp = $ua->request($req);
            $result = eval { decode_json($resp->content) } || { success => 0, error => $resp->status_line };
        };
        if ($@) { $result = { success => 0, error => "Internal error: $@" }; }

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'action',
            "sync_schema_field: table=$table field=" . ($field||'ALL') . " direction=$direction result=" . ($result->{success} ? 'ok' : $result->{error}));

        $c->response->body(encode_json({
            success   => $result->{success} ? JSON::true : JSON::false,
            message   => $result->{success}
                ? "Schema sync ($direction) applied for table '$table'" . ($field ? ", field '$field'" : " (all fields)")
                : "Schema sync failed: " . ($result->{error} || 'unknown error'),
            direction => $direction,
            table     => $table,
            field     => $field || undef,
        }));
        return;
    }

    # ── create_constituent ────────────────────────────────────────────────────
    # Create a new ENCY constituent record and optionally a todo stub.
    if ($action_name eq 'create_constituent') {
        my $name = $params->{name} || '';
        unless ($name) {
            $c->response->status(400);
            $c->response->body(encode_json({ success => JSON::false, error => 'name required' }));
            return;
        }

        my $roles = $c->session->{roles} || [];
        $roles = [split(/\s*,\s*/, $roles)] unless ref $roles;
        my $can_edit = grep { /^(admin|editor|developer)$/i } @$roles;
        unless ($can_edit) {
            $c->response->status(403);
            $c->response->body(encode_json({ success => JSON::false,
                error => 'Editor or admin role required to create constituents' }));
            return;
        }

        my $ency_model = $c->model('ENCYModel');
        unless ($ency_model) {
            $c->response->status(500);
            $c->response->body(encode_json({ success => JSON::false, error => 'ENCY model not available' }));
            return;
        }

        my $sitename  = $c->stash->{SiteName} || $c->session->{SiteName} || 'ENCY';
        my $username  = $c->session->{username} || 'system';
        my $group     = ref $roles eq 'ARRAY' && @$roles ? $roles->[0] : '';

        my $existing;
        eval {
            $existing = $ency_model->ency_schema->resultset('Ency::Constituent')->search(
                { -or => [
                    name        => { like => $name },
                    common_name => { like => $name },
                ]},
                { rows => 1 }
            )->first;
        };

        if ($existing) {
            $c->response->body(encode_json({
                success  => JSON::true,
                message  => "Constituent '$name' already exists: " . $existing->name,
                existing => JSON::true,
                id       => $existing->record_id,
                url      => '/ENCY/Constituent/' . $existing->record_id,
            }));
            return;
        }

        my $data = {
            name                    => $name,
            common_name             => $params->{common_name}            || '',
            chemical_formula        => $params->{chemical_formula}       || '',
            chemical_class          => $params->{chemical_class}         || '',
            iupac_name              => $params->{iupac_name}             || '',
            cas_number              => $params->{cas_number}             || '',
            therapeutic_action      => $params->{therapeutic_action}     || '',
            pharmacological_effects => $params->{pharmacological_effects}|| '',
            toxicity                => $params->{toxicity}               || '',
            solubility              => $params->{solubility}             || '',
            found_in_herbs          => $params->{found_in_herbs}         || '',
            found_in_foods          => $params->{found_in_foods}         || '',
            found_in_drugs          => $params->{found_in_drugs}         || '',
            research_notes          => $params->{research_notes}         || '',
            url                     => $params->{url}                    || '',
            reference               => $params->{reference}              || '',
            sitename                => $sitename,
            username_of_poster      => $username,
            group_of_poster         => $group,
            date_time_posted        => \'NOW()',
            share                   => 0,
        };

        my ($ok, $new_id) = eval { $ency_model->add_constituent($c, $data) };
        if ($@ || !$ok) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'action',
                "create_constituent failed: $@");
            $c->response->status(500);
            $c->response->body(encode_json({ success => JSON::false,
                error => 'Constituent creation failed: ' . ($@ || 'unknown error') }));
            return;
        }

        my $stub_note = '';
        unless ($data->{chemical_formula} || $data->{therapeutic_action}) {
            eval {
                require Comserv::Model::ENCYModel;
                $ency_model->_create_ency_todo($c,
                    "ENCY: New constituent stub '$name' needs review",
                    "A stub constituent record was created for '$name' via AI. "
                  . "Please complete the entry with: chemical formula, class, therapeutic action, "
                  . "pharmacological effects, found_in_herbs, and references.\n"
                  . "Edit at: /ENCY/Constituent/edit?record_id=$new_id"
                );
            };
            $stub_note = ' A review todo was created.';
        }

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'action',
            "AI action create_constituent: id=$new_id name='$name' by=$username");
        $c->response->body(encode_json({
            success => JSON::true,
            message => "Constituent '$name' created (ID $new_id).$stub_note "
                     . "Edit at /ENCY/Constituent/edit?record_id=$new_id",
            id      => $new_id,
            url     => "/ENCY/Constituent/$new_id",
        }));
        return;
    }

    # ── create_yard ───────────────────────────────────────────────────────────
    if ($action_name eq 'create_yard') {
        my $wiz_confirmed = $params->{wizard_confirmed};
        my %prefill = (
            yard_code      => $params->{yard_code}      || '',
            yard_name      => $params->{yard_name}      || '',
            yard_size      => $params->{yard_size}      || 10,
            total_yard_size=> $params->{total_yard_size}|| 10,
            notes          => $params->{notes}          || '',
            sitename       => $c->session->{SiteName}   || 'BMaster',
        );

        unless ($wiz_confirmed) {
            $c->response->body(encode_json({
                success        => JSON::true,
                action         => 'open_yard_wizard',
                wizard_prefill => \%prefill,
                message        => 'Please review the yard details before saving.',
            }));
            return;
        }

        unless ($prefill{yard_code} && $prefill{yard_name}) {
            $c->response->body(encode_json({ success => JSON::false, error => 'yard_code and yard_name are required' }));
            return;
        }

        my $yard_row;
        eval {
            $yard_row = $schema->resultset('Beekeeping::Yard')->create({
                %prefill,
                current          => 0,
                status           => 'active',
                date_time_posted => DateTime->now->stringify,
                comments         => $params->{comments} || '',
                image            => '',
            });
        };
        if ($@ || !$yard_row) {
            $c->response->body(encode_json({ success => JSON::false, error => "Failed to create yard: $@" }));
            return;
        }
        my $yard_id = $yard_row->id;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'action', "AI action create_yard: id=$yard_id by=$current_user");
        $c->response->body(encode_json({
            success  => JSON::true,
            yard_id  => $yard_id + 0,
            url      => "/Apiary/yards/view/$yard_id",
            message  => "Yard '$prefill{yard_name}' created (id=$yard_id). Now you can add hives to it.",
        }));
        return;
    }

    # ── create_hive ───────────────────────────────────────────────────────────
    if ($action_name eq 'create_hive') {
        my $wiz_confirmed = $params->{wizard_confirmed};
        my $sitename = $c->session->{SiteName} || 'BMaster';

        my $yard_id = $params->{yard_id};
        unless ($yard_id) {
            my @yards = $schema->resultset('Beekeeping::Yard')->search({ sitename => $sitename, status => 'active' })->all;
            unless (@yards) {
                $c->response->body(encode_json({
                    success => JSON::true,
                    action  => 'open_yard_wizard',
                    wizard_prefill => { yard_name => $params->{yard_name} || '', yard_code => '', yard_size => 10, total_yard_size => 10 },
                    message => 'No yards exist yet. Please create a yard first.',
                }));
                return;
            }
            if (@yards == 1) {
                $yard_id = $yards[0]->id;
            } else {
                $c->response->body(encode_json({
                    success       => JSON::true,
                    action        => 'open_hive_wizard',
                    wizard_prefill => {
                        hive_number => $params->{hive_number} || '',
                        yards       => [map { { id => $_->id, name => $_->yard_name, code => $_->yard_code } } @yards],
                    },
                    message => 'Multiple yards found — please select which yard this hive belongs to.',
                }));
                return;
            }
        }

        my %prefill = (
            hive_number => $params->{hive_number} || '',
            yard_id     => $yard_id + 0,
            queen_code  => $params->{queen_code}  || '',
            pallet_code => $params->{pallet_code} || '',
            status      => 'active',
            sitename    => $sitename,
            notes       => $params->{notes}       || '',
            created_by  => $current_user,
        );

        unless ($wiz_confirmed) {
            $c->response->body(encode_json({
                success        => JSON::true,
                action         => 'open_hive_wizard',
                wizard_prefill => \%prefill,
                message        => 'Please review the hive details before saving.',
            }));
            return;
        }

        unless ($prefill{hive_number}) {
            $c->response->body(encode_json({ success => JSON::false, error => 'hive_number is required' }));
            return;
        }

        my $hive_row;
        eval { $hive_row = $schema->resultset('Beekeeping::Hive')->create(\%prefill) };
        if ($@ || !$hive_row) {
            $c->response->body(encode_json({ success => JSON::false, error => "Failed to create hive: $@" }));
            return;
        }
        my $hive_id = $hive_row->id;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'action', "AI action create_hive: id=$hive_id hive_number=$prefill{hive_number} yard=$yard_id by=$current_user");
        $c->response->body(encode_json({
            success    => JSON::true,
            hive_id    => $hive_id + 0,
            hive_number=> $prefill{hive_number},
            url        => "/Apiary/hives/view/$hive_id",
            message    => "Hive $prefill{hive_number} created (id=$hive_id). You can now record an inspection.",
        }));
        return;
    }

    # ── create_queen ──────────────────────────────────────────────────────────
    if ($action_name eq 'create_queen') {
        my $wiz_confirmed = $params->{wizard_confirmed};
        my $sitename = $c->session->{SiteName} || 'BMaster';
        my $today = DateTime->now->ymd;

        my %prefill = (
            tag_number       => $params->{tag_number}       || '',
            color_marking    => $params->{color_marking}    || '',
            birth_date       => $params->{birth_date}       || $today,
            breed            => $params->{breed}            || 'unknown',
            origin           => $params->{origin}           || 'local',
            mating_status    => $params->{mating_status}    || 'mated',
            introduction_date=> $params->{introduction_date}|| $today,
            removal_date     => $params->{removal_date}     || '9999-12-31',
            performance_rating => ($params->{performance_rating} || 0) + 0,
            health_status    => $params->{health_status}    || 'healthy',
            laying_status    => $params->{laying_status}    || 'laying_well',
            temperament_rating => $params->{temperament_rating} || 'calm',
            status           => 'active',
            purpose          => $params->{purpose}          || 'production',
            sitename         => $sitename,
            notes            => $params->{notes}            || '',
            created_by       => $current_user,
        );

        unless ($wiz_confirmed) {
            $c->response->body(encode_json({
                success        => JSON::true,
                action         => 'open_queen_wizard',
                wizard_prefill => \%prefill,
                message        => 'Please review the queen details before saving.',
            }));
            return;
        }

        my $queen_row;
        eval { $queen_row = $schema->resultset('Beekeeping::Queen')->create(\%prefill) };
        if ($@ || !$queen_row) {
            $c->response->body(encode_json({ success => JSON::false, error => "Failed to create queen: $@" }));
            return;
        }
        my $queen_id = $queen_row->id;

        if ($params->{hive_id}) {
            eval {
                $schema->resultset('Beekeeping::QueenHiveAssignment')->create({
                    queen_id   => $queen_id,
                    hive_id    => $params->{hive_id} + 0,
                    start_date => $today,
                    status     => 'active',
                    notes      => "Assigned by AI from voice inspection",
                });
            };
        }

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'action', "AI action create_queen: id=$queen_id tag=$prefill{tag_number} by=$current_user");
        $c->response->body(encode_json({
            success  => JSON::true,
            queen_id => $queen_id + 0,
            url      => "/Apiary/queens/view/$queen_id",
            message  => "Queen recorded (id=$queen_id, tag=$prefill{tag_number}).",
        }));
        return;
    }

    # ── create_inspection ─────────────────────────────────────────────────────
    if ($action_name eq 'create_inspection') {
        my $sitename = $c->session->{SiteName} || 'BMaster';

        my $hive_id = $params->{hive_id};
        unless ($hive_id) {
            my $hive_number = $params->{hive_number} || '';
            if ($hive_number) {
                my $hive_row = $schema->resultset('Beekeeping::Hive')->search(
                    { hive_number => $hive_number, sitename => $sitename },
                    { rows => 1 }
                )->first;
                if ($hive_row) {
                    $hive_id = $hive_row->id;
                } else {
                    my @yards = $schema->resultset('Beekeeping::Yard')->search({ sitename => $sitename, status => 'active' })->all;
                    unless (@yards) {
                        $c->response->body(encode_json({
                            success => JSON::true,
                            action  => 'open_yard_wizard',
                            wizard_prefill => { yard_name => '', yard_code => '', yard_size => 10, total_yard_size => 10 },
                            message => "Hive $hive_number not found and no yards exist. Please create a yard first, then the hive.",
                            next_action => 'create_hive',
                            next_params => { hive_number => $hive_number },
                        }));
                        return;
                    }
                    $c->response->body(encode_json({
                        success        => JSON::true,
                        action         => 'open_hive_wizard',
                        wizard_prefill => {
                            hive_number => $hive_number,
                            yard_id     => @yards == 1 ? $yards[0]->id + 0 : undef,
                            yards       => [map { { id => $_->id + 0, name => $_->yard_name, code => $_->yard_code } } @yards],
                        },
                        message => "Hive $hive_number not found in the system. Please fill in the details to register it first.",
                        next_action => 'create_inspection',
                        next_params => $params,
                    }));
                    return;
                }
            } else {
                $c->response->status(400);
                $c->response->body(encode_json({ success => JSON::false, error => 'hive_id or hive_number required' }));
                return;
            }
        };

        my %POPULATION_MAP = (
            'very strong' => 'very_strong', 'very_strong' => 'very_strong',
            'strong'      => 'strong',      'good'        => 'strong',
            'moderate'    => 'moderate',    'medium'      => 'moderate', 'average' => 'moderate',
            'weak'        => 'weak',        'low'         => 'weak',
            'very weak'   => 'very_weak',   'very_weak'   => 'very_weak', 'poor'   => 'very_weak',
        );
        my %TEMPERAMENT_MAP = (
            'calm'           => 'calm',           'gentle'    => 'calm',     'docile'  => 'calm',
            'moderate'       => 'moderate',       'normal'    => 'moderate',
            'aggressive'     => 'aggressive',     'defensive' => 'aggressive',
            'very aggressive'=> 'very_aggressive','very_aggressive' => 'very_aggressive', 'hot' => 'very_aggressive',
        );
        my %STATUS_MAP = (
            'excellent' => 'excellent', 'great' => 'excellent',
            'good'      => 'good',
            'fair'      => 'fair',      'ok'    => 'fair',  'okay' => 'fair',
            'poor'      => 'poor',
            'critical'  => 'critical',  'bad'   => 'critical',
        );
        my %WEATHER_MAP = (
            'sunny'    => 'sunny',   'clear'    => 'sunny',
            'cloudy'   => 'cloudy',  'overcast' => 'cloudy',
            'rainy'    => 'rainy',   'rain'     => 'rainy',   'wet' => 'rainy',
            'windy'    => 'windy',   'breezy'   => 'windy',
            'warm'     => 'warm',    'hot'      => 'warm',
            'cold'     => 'cold',    'cool'     => 'cold',
            'foggy'    => 'foggy',
        );

        my $normalise = sub {
            my ($val, $map_ref) = @_;
            return undef unless defined $val && $val ne '';
            my $lc = lc($val);
            return $map_ref->{$lc} || $map_ref->{$val} || $val;
        };

        my $inspection_date = $params->{inspection_date} || $today;
        $inspection_date = $today unless $inspection_date =~ /^\d{4}-\d{2}-\d{2}$/;

        my %insp = (
            hive_id             => $hive_id + 0,
            inspection_date     => $inspection_date,
            inspector           => $params->{inspector} || $current_user,
            inspection_type     => $params->{inspection_type} || 'routine',
            overall_status      => $normalise->($params->{overall_status}, \%STATUS_MAP) || 'good',
            queen_seen          => ($params->{queen_seen}  ? 1 : 0),
            queen_marked        => ($params->{queen_marked}? 1 : 0),
            eggs_seen           => ($params->{eggs_seen}   ? 1 : 0),
            larvae_seen         => ($params->{larvae_seen} ? 1 : 0),
            capped_brood_seen   => ($params->{capped_brood_seen} ? 1 : 0),
            supersedure_cells   => ($params->{supersedure_cells}  || 0) + 0,
            swarm_cells         => ($params->{swarm_cells}         || 0) + 0,
            queen_cells         => ($params->{queen_cells}         || 0) + 0,
            temperament         => $normalise->($params->{temperament}, \%TEMPERAMENT_MAP) || 'calm',
            general_notes       => $params->{general_notes}   || '',
            action_required     => $params->{action_required} || '',
            feeding_done        => ($params->{feeding_done}   ? 1 : 0),
            feed_type           => $params->{feed_type}    || undef,
            feed_amount         => $params->{feed_amount}  || undef,
        );

        if (defined $params->{population_estimate} && $params->{population_estimate} ne '') {
            $insp{population_estimate} = $normalise->($params->{population_estimate}, \%POPULATION_MAP);
        }
        if (defined $params->{weather_conditions} && $params->{weather_conditions} ne '') {
            $insp{weather_conditions} = $normalise->($params->{weather_conditions}, \%WEATHER_MAP) // $params->{weather_conditions};
        }
        if (defined $params->{temperature} && $params->{temperature} =~ /^-?\d/) {
            ($insp{temperature} = $params->{temperature}) =~ s/[^\d.\-]//g;
        }
        if (defined $params->{next_inspection_date} && $params->{next_inspection_date} =~ /^\d{4}-\d{2}-\d{2}$/) {
            $insp{next_inspection_date} = $params->{next_inspection_date};
        }
        if (defined $params->{start_time}) { $insp{start_time} = $params->{start_time}; }
        if (defined $params->{end_time})   { $insp{end_time}   = $params->{end_time};   }

        my $inspection_row;
        eval { $inspection_row = $schema->resultset('Beekeeping::Inspection')->create(\%insp) };
        if ($@ || !$inspection_row) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                'action', "create_inspection failed: $@");
            $c->response->status(500);
            $c->response->body(encode_json({ success => JSON::false, error => "Inspection creation failed: $@" }));
            return;
        }

        my $inspection_id = $inspection_row->id;

        my @detail_rows_created;
        my $box_details = $params->{box_details} || [];
        if (ref($box_details) eq 'ARRAY') {
            for my $bd (@$box_details) {
                next unless ref($bd) eq 'HASH';
                my %detail = (
                    inspection_id   => $inspection_id,
                    detail_type     => $bd->{detail_type}   || 'box_summary',
                    bees_coverage   => $bd->{bees_coverage} || 'none',
                    brood_pattern   => $bd->{brood_pattern} || 'good',
                    brood_percentage=> ($bd->{brood_percentage} || 0) + 0,
                    honey_percentage=> ($bd->{honey_percentage} || 0) + 0,
                    pollen_percentage=>($bd->{pollen_percentage}|| 0) + 0,
                    empty_percentage=> ($bd->{empty_percentage} || 0) + 0,
                    disease_signs   => $bd->{disease_signs}   || undef,
                    pest_signs      => $bd->{pest_signs}      || undef,
                    treatment_applied=> $bd->{treatment_applied} || undef,
                    notes           => $bd->{notes}           || undef,
                    queen_cells_count=> ($bd->{queen_cells_count} || 0) + 0,
                );
                $detail{box_id}    = $bd->{box_id}   + 0 if defined $bd->{box_id}   && $bd->{box_id}   =~ /^\d+$/;
                $detail{frame_id}  = $bd->{frame_id} + 0 if defined $bd->{frame_id} && $bd->{frame_id} =~ /^\d+$/;
                $detail{comb_condition} = $bd->{comb_condition} if $bd->{comb_condition};
                $detail{brood_type}     = $bd->{brood_type}     if $bd->{brood_type};

                my $dr;
                eval { $dr = $schema->resultset('Beekeeping::InspectionDetail')->create(\%detail) };
                if ($@) {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                        'action', "create_inspection_detail failed: $@");
                } else {
                    push @detail_rows_created, $dr->id;
                }
            }
        }

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'action', "AI action create_inspection: id=$inspection_id hive=$hive_id by=$current_user details=" . scalar(@detail_rows_created));

        $c->response->body(encode_json({
            success       => JSON::true,
            inspection_id => $inspection_id + 0,
            url           => "/Apiary/inspections/view/$inspection_id",
            detail_count  => scalar(@detail_rows_created) + 0,
            message       => "Inspection #$inspection_id recorded for hive $hive_id.",
        }));
        return;
    }

    # Unknown action
    $c->response->status(400);
    $c->response->body(encode_json({ success => JSON::false, error => "Unknown action: $action_name" }));
}

__PACKAGE__->meta->make_immutable;
1;
