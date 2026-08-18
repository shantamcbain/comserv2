package Comserv::Controller::Api;
use Moose;
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)
use JSON::MaybeXS;
use DateTime;
use Digest::SHA qw(sha256_hex);
use Comserv::Util::Logging;
use Comserv::Util::ApiTokenValidator;
use Comserv::Util::DocumentationConfig;
use Comserv::Util::ModelCatalog;

# Resolve the default model for the AI Focus-Tune picker from the SAME shared
# catalog every other AI surface uses (ModelCatalog::default_for) — NEVER a
# hardcoded slug. Returns "provider|model" (e.g. "openrouter|...:free"). If the
# catalog is empty there is genuinely no dynamic default, so we return '' (the
# caller must then fall back to a real listed model, not invent one).
sub _focus_default_model {
    my ($c) = @_;
    my $def = eval { Comserv::Util::ModelCatalog->default_for($c, page => 'chat') };
    return $def if $def && $def =~ /\|/;
    my $cat = eval { Comserv::Util::ModelCatalog->catalog($c) } || [];
    return $cat->[0]{value} if @$cat && $cat->[0]{value};
    return '';
}

# Live external (Grok/xAI, OpenRouter, ...) model list for the AI Focus-Tune
# picker. Pulled from Model::AI2::Router::get_available_models — the SAME source
# the chat dropdown and ModelCatalog use — which performs a real list_models()
# call against each provider's API. This is the dynamic list: it reflects what
# the provider actually offers for the configured key, NOT a stale DB snapshot
# in UserApiKeys.metadata.available_models. No hardcoded fallback is added.
sub _focus_external_models {
    my ($c) = @_;
    my @out;
    eval {
        my $router = $c->model('AI2::Router');
        my $all    = $router->get_available_models($c);
        return unless $all && ref($all) eq 'ARRAY';
        for my $m (@$all) {
            next unless $m && ref($m) eq 'HASH';
            my $prov = $m->{provider} // '';
            next if $prov eq 'ollama';                 # Ollama handled separately
            next if $m->{disabled} || $m->{needs_key}; # skip unconfigured stubs
            my $name = $m->{name} // $m->{id} // '';
            next unless $name;
            push @out, {
                name     => $name,
                provider => $prov,
                label    => $m->{label} // $name,
            };
        }
    };
    if ($@) {
        Comserv::Util::Logging->instance->log_with_details(
            $c, 'warn', __FILE__, __LINE__, 'api_focus',
            "Live external model list failed: $@");
    }
    return @out;
}

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub _check_admin {
    my ($self, $c) = @_;

    unless ($c->session->{username} && $c->session->{user_id}) {
        $c->res->status(401);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({
            success => 0,
            error => 'Not authenticated. Please log in first.',
            code => 'not_authenticated'
        }));
        $c->detach();
    }

    unless ($c->stash->{is_admin}) {
        $c->res->status(403);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({
            success => 0,
            error => 'Admin role required.',
            code => 'insufficient_permissions'
        }));
        $c->detach();
    }
}

=head2 api_generate_token

POST /api/generate-token - Generate a new API token for authenticated user

Requires: User logged in with admin role
Body (optional): { token_name, expires_in_days }

Returns: { success, token, message }
Note: Token is only returned once - store it securely!
=cut

sub api_generate_token :Local :Args(0) {
    my ($self, $c) = @_;
    
    $self->_check_admin($c);
    
    my $params;
    eval {
        my $body = $c->request->body;
        if ($body) {
            if (ref($body) && $body->can('seek')) {
                seek($body, 0, 0);
                my $raw_body = do { local $/; <$body> };
                $params = decode_json($raw_body);
            } else {
                $params = decode_json($body);
            }
        }
    };
    if ($@) {
        $c->res->status(400);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({
            success => 0,
            error => "Invalid JSON: $@",
            code => 'json_parse_error'
        }));
        $c->detach();
    }
    
    my $token_name = $params->{token_name} || 'API Token ' . DateTime->now->ymd;
    my $expires_in_days = $params->{expires_in_days};
    
    my $schema = $c->model('DBEncy');
    my $username = $c->session->{username};
    
    my $user = $schema->resultset('User')->search({
        username => $username
    })->first;
    
    unless ($user) {
        $c->res->status(404);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({
            success => 0,
            error => 'Current user not found in database',
            code => 'user_not_found'
        }));
        $c->detach();
    }
    
    my $token = _generate_random_token();
    my $token_hash = sha256_hex($token);
    
    my $expires_at;
    if ($expires_in_days && $expires_in_days =~ /^\d+$/) {
        my $dt = DateTime->now->add(days => $expires_in_days);
        $expires_at = $dt;
    }
    
    my $api_token = $schema->resultset('ApiToken')->create({
        user_id => $user->id,
        token_hash => $token_hash,
        token_name => $token_name,
        is_active => 1,
        created_at => DateTime->now,
        expires_at => $expires_at,
    });
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_generate_token',
        "API token generated for user: $username, token_id: $api_token->id");
    
    $c->res->status(200);
    $c->res->content_type('application/json');
    $c->res->body(encode_json({
        success => 1,
        message => 'API token generated successfully',
        token => $token,
        token_id => $api_token->id,
        token_name => $token_name,
        expires_at => $expires_at ? $expires_at->iso8601 : undef,
        warning => 'Store this token securely. It will not be displayed again.'
    }));
    $c->detach();
}

=head2 api_list_tokens

GET /api/tokens - List all API tokens for authenticated user

Requires: User logged in with admin role

Returns: { success, tokens: [ { id, token_name, created_at, expires_at, is_active, last_used_at } ] }
=cut

sub api_list_tokens :Local :Args(0) {
    my ($self, $c) = @_;
    
    $self->_check_admin($c);
    
    my $schema = $c->model('DBEncy');
    my $username = $c->session->{username};
    
    my $user = $schema->resultset('User')->search({
        username => $username
    })->first;
    
    unless ($user) {
        $c->res->status(404);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({
            success => 0,
            error => 'Current user not found in database',
            code => 'user_not_found'
        }));
        $c->detach();
    }
    
    my @tokens = $schema->resultset('ApiToken')->search({
        user_id => $user->id
    })->all;
    
    my @token_list = map {
        {
            id => $_->id,
            token_name => $_->token_name,
            is_active => $_->is_active,
            created_at => $_->created_at ? $_->created_at->iso8601 : undef,
            expires_at => $_->expires_at ? $_->expires_at->iso8601 : undef,
            last_used_at => $_->last_used_at ? $_->last_used_at->iso8601 : undef,
            revoked_at => $_->revoked_at ? $_->revoked_at->iso8601 : undef,
        }
    } @tokens;
    
    $c->res->status(200);
    $c->res->content_type('application/json');
    $c->res->body(encode_json({
        success => 1,
        tokens => \@token_list
    }));
    $c->detach();
}

=head2 api_revoke_token

DELETE /api/tokens/:token_id - Revoke an API token

Requires: User logged in with admin role
Token ownership verified (user can only revoke own tokens)

Returns: { success, message }
=cut

sub api_revoke_token :Local :Args(1) {
    my ($self, $c, $token_id) = @_;
    
    $self->_check_admin($c);
    
    my $schema = $c->model('DBEncy');
    my $username = $c->session->{username};
    
    my $user = $schema->resultset('User')->search({
        username => $username
    })->first;
    
    unless ($user) {
        $c->res->status(404);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({
            success => 0,
            error => 'Current user not found in database',
            code => 'user_not_found'
        }));
        $c->detach();
    }
    
    my $api_token = $schema->resultset('ApiToken')->search({
        id => $token_id,
        user_id => $user->id
    })->first;
    
    unless ($api_token) {
        $c->res->status(404);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({
            success => 0,
            error => 'Token not found or does not belong to you',
            code => 'token_not_found'
        }));
        $c->detach();
    }
    
    $api_token->update({
        is_active => 0,
        revoked_at => DateTime->now
    });
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_revoke_token',
        "API token revoked: user=$username, token_id=$token_id");
    
    $c->res->status(200);
    $c->res->content_type('application/json');
    $c->res->body(encode_json({
        success => 1,
        message => 'API token revoked successfully'
    }));
    $c->detach();
}

=head2 api_list_todos

GET /api/todos - List all todos (Bypass keyword/token for local/workstation.local)

Returns: { success, todos: [ { ... } ] }
=cut

sub api_list_todos :Path('todos') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if request is from localhost or workstation.local
    my $address = $c->req->address;
    my $is_local = ($address eq '127.0.0.1' || $address eq '::1' || $address =~ /^192\.168\.1\./);
    
    unless ($is_local) {
        my $validation = Comserv::Util::ApiTokenValidator->validate_from_request($c);
        unless ($validation->{valid}) {
            $c->res->status($validation->{code} || 401);
            $c->res->content_type('application/json');
            $c->res->body(encode_json({
                success => 0,
                error => $validation->{error} || 'Authentication required',
                code => $validation->{code} || 'unauthorized'
            }));
            $c->detach();
        }
    }
    
    my $schema = $c->model('DBEncy');

    # Honor query parameters so callers can actually search/filter.
    # Mirrors the web /todo action's subject/description/comments LIKE logic.
    my $search_term     = $c->request->query_parameters->{search}     || '';
    my $project_id      = $c->request->query_parameters->{project_id} || '';
    my $status_filter   = $c->request->query_parameters->{status}    || '';
    my $sitename_filter = $c->request->query_parameters->{sitename}  || '';

    my $cond = {};
    if ($sitename_filter) {
        $cond->{sitename} = $sitename_filter;
    }
    if ($status_filter ne '') {
        $cond->{status} = $status_filter;
    }
    if ($project_id ne '') {
        $cond->{project_id} = $project_id;
    }
    if ($search_term) {
        # Per-word OR matching: a row matches if ANY query word appears in ANY
        # of the searchable fields. Relevance ranking (below) then orders by how
        # many distinct words matched, so "git worktree" floats rows with both up.
        my @words = grep { length } split(/\s+/, $search_term);
        my @field_or;
        for my $w (@words) {
            push @field_or, (
                { subject     => { 'like', "%$w%" } },
                { description => { 'like', "%$w%" } },
                { comments    => { 'like', "%$w%" } },
            );
        }
        $cond->{'-or'} = \@field_or if @field_or;
    }

    my @todos = $schema->resultset('Todo')->search($cond);

    # Relevance ranking: when a search term is present, order results by the
    # number of DISTINCT matched query words across subject/description/comments
    # (desc) so the strongest hits surface first and low-relevance noise sinks.
    my @todo_list;
    if ($search_term) {
        my @qwords = grep { length } split(/\s+/, lc($search_term));
        my @scored;
        for my $t (@todos) {
            my %cols = $t->get_columns;
            my $hay = lc(join(' ', $cols{subject} // '', $cols{description} // '', $cols{comments} // ''));
            my $score = 0;
            my %seen;
            for my $w (@qwords) {
                next if $seen{$w}++;
                $score++ if index($hay, $w) >= 0;
            }
            push @scored, { row => \%cols, score => $score };
        }
        @scored = sort { $b->{score} <=> $a->{score} || $a->{row}{record_id} <=> $b->{row}{record_id} } @scored;
        @todo_list = map { $_->{row} } @scored;
    } else {
        @todo_list = map { { $_->get_columns } } @todos;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_list_todos',
        "Todos listed via API (Local: $is_local)" . ($search_term ? " search='$search_term'" : '') .
        " -> " . scalar(@todo_list) . " rows");
    
    $c->res->status(200);
    $c->res->content_type('application/json');
    $c->res->body(encode_json({
        success => 1,
        count => scalar(@todo_list),
        todos => \@todo_list
    }));
    $c->detach();
}

=head2 api_todo_create

POST /api/todo/create - Create a new todo (Bypass keyword/token for local/workstation.local)

Required JSON fields: subject, start_date, due_date, priority, status
Optional JSON fields: description, project_id, assigned_to

Returns: { success, message, todo_id, todo: { ... } }
=cut

sub api_todo_create :Path('todo/create') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if request is from localhost or workstation.local
    my $address = $c->req->address;
    my $is_local = ($address eq '127.0.0.1' || $address eq '::1' || $address =~ /^192\.168\.1\./);
    
    my $api_user;
    unless ($is_local) {
        my $validation = Comserv::Util::ApiTokenValidator->validate_from_request($c);
        unless ($validation->{valid}) {
            $c->res->status($validation->{code} || 401);
            $c->res->content_type('application/json');
            $c->res->body(encode_json({
                success => 0,
                error => $validation->{error} || 'Authentication required',
                code => $validation->{code} || 'unauthorized'
            }));
            $c->detach();
        }
        
        my $schema = $c->model('DBEncy');
        my $api_token = $schema->resultset('ApiToken')->find($validation->{api_token_id});
        $api_user = $api_token->user if $api_token;
    }
    
    my $params;
    eval {
        # Using decode_json directly here
        my $body = $c->request->body;
        if ($body) {
            if (ref($body) && $body->can('seek')) {
                seek($body, 0, 0);
                my $raw_body = do { local $/; <$body> };
                $params = decode_json($raw_body);
            } else {
                $params = decode_json($body);
            }
        }
    };
    if ($@) {
        $c->res->status(400);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => 0, error => "Invalid JSON: $@", code => 'json_parse_error' }));
        $c->detach();
    }
    
    my $schema = $c->model('DBEncy');
    my $current_user = $api_user ? $api_user->username : ($c->session->{username} || 'system');
    
    my @required = qw(subject start_date due_date priority status);
    my @missing = grep { !defined $params->{$_} || $params->{$_} eq '' } @required;
    if (@missing) {
        $c->res->status(400);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => 0, error => "Missing required fields: " . join(', ', @missing), code => 'validation_error' }));
        $c->detach();
    }
    
    my $start_date = $params->{start_date};
    my $due_date = $params->{due_date};
    if ($start_date gt $due_date) {
        $c->res->status(400);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => 0, error => "Start date cannot be after due date", code => 'date_validation_error' }));
        $c->detach();
    }
    
    my $project_id = $params->{project_id} || 1;
    eval {
        my $project = $schema->resultset('Project')->find($project_id);
        unless ($project) {
            die "Project $project_id not found";
        }
    };
    if ($@) {
        $c->res->status(400);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => 0, error => "Invalid project_id: $@", code => 'invalid_project' }));
        $c->detach();
    }
    
    my $sitename = $params->{sitename} || $c->session->{SiteName} || 'CSC';

    my $poster_user_id;
    if ($api_user) {
        $poster_user_id = $api_user->id;
    } else {
        my $poster_name = $params->{assigned_to} || $params->{developer} || $current_user;
        my $poster_row = $schema->resultset('User')->search(
            { username => $poster_name },
            { rows => 1 }
        )->single;
        $poster_user_id = $poster_row ? $poster_row->id : undef;
    }

    # user_id is NOT NULL and carries an FK to users.id, so it must resolve to a real
    # user. Fall back to the session user, then fail with a clear validation error
    # rather than letting the INSERT die with a raw DBI/FK exception.
    $poster_user_id = $c->session->{user_id} unless defined $poster_user_id;
    unless ($poster_user_id
        && $schema->resultset('User')->find($poster_user_id)) {
        $c->res->status(400);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({
            success => 0,
            error   => 'Could not resolve a valid user for this todo. Pass "developer" '
                     . 'or "assigned_to" matching an existing username.',
            code    => 'invalid_user',
        }));
        $c->detach();
    }

    my $todo = $schema->resultset('Todo')->create({
        subject => $params->{subject},
        description => $params->{description} || '',
        project_id => $project_id,
        start_date => $start_date,
        due_date => $due_date,
        priority => $params->{priority},
        status => $params->{status},
        developer => $params->{assigned_to} || $params->{developer} || $current_user,
        sitename => $sitename,
        date_time_posted => DateTime->now->ymd . ' ' . DateTime->now->hms,
        username_of_poster => $current_user,
        last_mod_by => $current_user,
        last_mod_date => DateTime->now->ymd,
        parent_todo => '',
        estimated_man_hours => 0,
        accumulative_time => '00:00:00',
        group_of_poster => 'admin',
        project_code => $params->{project_code} || 'system',
        share => 0,
        user_id => $poster_user_id,
    });
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_todo_create',
        "Todo created via API: ID=" . $todo->id . ", Subject=" . $params->{subject});
    
    $c->res->status(200);
    $c->res->content_type('application/json');
    $c->res->body(encode_json({
        success => 1,
        message => 'Todo created successfully',
        todo_id => $todo->id,
        todo => $self->_todo_to_hash($todo)
    }));
    $c->detach();
}

=head2 api_list_documentation

GET /api/documentation - List all documentation pages (Bypass keyword/token for local/workstation.local)

Returns: { success, pages: [ { ... } ] }
=cut

sub api_list_documentation :Path('documentation') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if request is from localhost or workstation.local
    my $address = $c->req->address;
    my $is_local = ($address eq '127.0.0.1' || $address eq '::1' || $address =~ /^192\.168\.1\./);
    
    unless ($is_local) {
        my $validation = Comserv::Util::ApiTokenValidator->validate_from_request($c);
        unless ($validation->{valid}) {
            $c->res->status($validation->{code} || 401);
            $c->res->content_type('application/json');
            $c->res->body(encode_json({ success => 0, error => $validation->{error} || 'Authentication required' }));
            $c->detach();
        }
    }
    
    my $config = Comserv::Util::DocumentationConfig->instance;
    my $pages = $config->get_pages();
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_list_documentation',
        "Documentation listed via API (Local: $is_local)");
    
    $c->res->status(200);
    $c->res->content_type('application/json');
    $c->res->body(encode_json({
        success => 1,
        count => scalar(@$pages),
        pages => $pages
    }));
    $c->detach();
}

=head2 api_create_project

POST /api/project/create - Create a new project or sub-project (Bypass auth for local requests)

Body (JSON):
  name, description, start_date, end_date, status, project_code,
  project_size, estimated_man_hours, developer_name, client_name,
  sitename, comments, parent_id (optional)

Returns: { success, project_id, project }
=cut

sub api_create_project :Path('project/create') :Args(0) {
    my ($self, $c) = @_;

    my $address  = $c->req->address;
    my $is_local = ($address eq '127.0.0.1' || $address eq '::1' || $address =~ /^192\.168\.1\./);

    my $api_user;
    unless ($is_local) {
        my $validation = Comserv::Util::ApiTokenValidator->validate_from_request($c);
        unless ($validation->{valid}) {
            $c->res->status($validation->{code} || 401);
            $c->res->content_type('application/json');
            $c->res->body(encode_json({ success => 0, error => $validation->{error} || 'Authentication required' }));
            $c->detach();
        }
        my $schema = $c->model('DBEncy');
        my $api_token = $schema->resultset('ApiToken')->find($validation->{api_token_id});
        $api_user = $api_token->user if $api_token;
    }

    my $params;
    eval {
        my $body = $c->request->body;
        if ($body) {
            if (ref($body) && $body->can('seek')) {
                seek($body, 0, 0);
                my $raw_body = do { local $/; <$body> };
                $params = decode_json($raw_body);
            } else {
                $params = decode_json($body);
            }
        }
    };
    if ($@) {
        $c->res->status(400);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => 0, error => "Invalid JSON: $@", code => 'json_parse_error' }));
        $c->detach();
    }

    my @required = qw(name start_date end_date status);
    my @missing  = grep { !defined $params->{$_} || $params->{$_} eq '' } @required;
    if (@missing) {
        $c->res->status(400);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => 0, error => 'Missing required fields: ' . join(', ', @missing), code => 'validation_error' }));
        $c->detach();
    }

    my $current_user = $api_user ? $api_user->username : ($c->session->{username} || 'system');
    my $schema       = $c->model('DBEncy');

    my $parent_id = $params->{parent_id} || undef;
    $parent_id    = undef if defined $parent_id && $parent_id eq '';

    my $project;
    eval {
        $project = $schema->resultset('Project')->create({
            name                => $params->{name},
            description         => $params->{description}          || '',
            start_date          => $params->{start_date},
            end_date            => $params->{end_date},
            status              => $params->{status}               || 'Requested',
            project_code        => $params->{project_code}         || '',
            project_size        => $params->{project_size}         || 3,
            estimated_man_hours => $params->{estimated_man_hours}  || 0,
            developer_name      => $params->{developer_name}       || $current_user,
            client_name         => $params->{client_name}          || 'CSC',
            sitename            => $params->{sitename}             || ($c->session->{SiteName} || 'CSC'),
            comments            => $params->{comments}             || '',
            username_of_poster  => $current_user,
            group_of_poster     => 'admin',
            date_time_posted    => DateTime->now->ymd . ' ' . DateTime->now->hms,
            parent_id           => $parent_id,
            record_id           => 0,
        });
    };
    if ($@) {
        my $err = "$@"; $err =~ s/\s+at\s+.*//s;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'api_create_project', "Error: $err");
        $c->res->status(500);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => 0, error => "Failed to create project: $err" }));
        $c->detach();
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_create_project',
        "Project created via API: ID=" . $project->id . ", Name=" . $project->name);

    $c->res->status(200);
    $c->res->content_type('application/json');
    $c->res->body(encode_json({
        success    => 1,
        message    => 'Project created successfully',
        project_id => $project->id,
        project    => { $project->get_columns },
    }));
    $c->detach();
}

=head2 api_list_projects

GET /api/projects - List all projects (Bypass keyword/token for local/workstation.local)

Returns: { success, projects: [ { ... } ] }
=cut

sub api_list_projects :Path('projects') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if request is from localhost or workstation.local
    my $address = $c->req->address;
    my $is_local = ($address eq '127.0.0.1' || $address eq '::1' || $address =~ /^192\.168\.1\./);
    
    unless ($is_local) {
        my $validation = Comserv::Util::ApiTokenValidator->validate_from_request($c);
        unless ($validation->{valid}) {
            $c->res->status($validation->{code} || 401);
            $c->res->content_type('application/json');
            $c->res->body(encode_json({ success => 0, error => $validation->{error} || 'Authentication required' }));
            $c->detach();
        }
    }
    
    my $schema = $c->model('DBEncy');

    # Honor a `search` query param (name / project_code / description) so the
    # project list is actually searchable via the API.
    my $search_term = $c->request->query_parameters->{search} || '';
    my $sitename_filter = $c->request->query_parameters->{sitename} || '';

    my $cond = {};
    if ($sitename_filter) {
        $cond->{sitename} = $sitename_filter;
    }
    if ($search_term) {
        # Per-word OR matching so multi-word queries match rows containing ANY
        # of the words; relevance ranking (below) orders by how many matched.
        my @words = grep { length } split(/\s+/, $search_term);
        my @field_or;
        for my $w (@words) {
            push @field_or, (
                { name         => { 'like', "%$w%" } },
                { project_code => { 'like', "%$w%" } },
                { description  => { 'like', "%$w%" } },
            );
        }
        $cond->{'-or'} = \@field_or if @field_or;
    }

    my @projects = $schema->resultset('Project')->search($cond);

    # Relevance ranking: when a search term is present, order by the number of
    # DISTINCT matched query words across name/project_code/description (desc).
    my @project_list;
    if ($search_term) {
        my @qwords = grep { length } split(/\s+/, lc($search_term));
        my @scored;
        for my $p (@projects) {
            my %cols = $p->get_columns;
            my $hay = lc(join(' ', $cols{name} // '', $cols{project_code} // '', $cols{description} // ''));
            my $score = 0;
            my %seen;
            for my $w (@qwords) {
                next if $seen{$w}++;
                $score++ if index($hay, $w) >= 0;
            }
            push @scored, { row => \%cols, score => $score };
        }
        @scored = sort { $b->{score} <=> $a->{score} || $a->{row}{id} <=> $b->{row}{id} } @scored;
        @project_list = map { $_->{row} } @scored;
    } else {
        @project_list = map { { $_->get_columns } } @projects;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_list_projects',
        "Projects listed via API (Local: $is_local)" . ($search_term ? " search='$search_term'" : '') .
        " -> " . scalar(@project_list) . " rows");
    
    $c->res->status(200);
    $c->res->content_type('application/json');
    $c->res->body(encode_json({
        success => 1,
        count => scalar(@project_list),
        projects => \@project_list
    }));
    $c->detach();
}

=head2 api_get_project

GET /api/projects/:project_id - Get one project with its associated todos

This endpoint is intentionally session-free for localhost/workstation.local, like
the list endpoints above.  It is the machine-readable equivalent of the project
details page and returns the complete direct todo collection, including done rows.
=cut

sub api_get_project :Path('projects') :Args(1) {
    my ($self, $c, $project_id) = @_;

    my $address = $c->req->address;
    my $is_local = ($address eq '127.0.0.1' || $address eq '::1'
        || $address =~ /^192\.168\.1\./);

    unless ($is_local) {
        my $validation = Comserv::Util::ApiTokenValidator->validate_from_request($c);
        unless ($validation->{valid}) {
            $c->res->status($validation->{code} || 401);
            $c->res->content_type('application/json');
            $c->res->body(encode_json({
                success => 0,
                error => $validation->{error} || 'Authentication required',
                code => $validation->{code} || 'unauthorized'
            }));
            $c->detach();
        }
    }

    unless (defined $project_id && $project_id =~ /^\d+$/) {
        $c->res->status(400);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => 0, error => 'Invalid project ID' }));
        $c->detach();
    }

    my $schema  = $c->model('DBEncy');
    my $project = $schema->resultset('Project')->find($project_id);
    unless ($project) {
        $c->res->status(404);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => 0, error => "Project $project_id not found" }));
        $c->detach();
    }

    my @todos = map { { $_->get_columns } }
        $schema->resultset('Todo')->search(
            { project_id => $project_id },
            { order_by => { -asc => 'start_date' } }
        )->all;

    my @sub_projects = map {
        my %columns = $_->get_columns;
        \%columns;
    } $schema->resultset('Project')->search(
        { parent_id => $project_id },
        { order_by => { -asc => 'name' } }
    )->all;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_get_project',
        "Project $project_id fetched via API with " . scalar(@todos) . " direct todos");

    $c->res->status(200);
    $c->res->content_type('application/json');
    $c->res->body(encode_json({
        success => 1,
        project => { $project->get_columns },
        todos => \@todos,
        todo_count => scalar(@todos),
        sub_projects => \@sub_projects,
        sub_project_count => scalar(@sub_projects),
    }));
    $c->detach();
}

=head2 api_list_chat

GET /api/chat - List chat conversations (Bypass keyword/token for local/workstation.local)

Returns: { success, conversations: [ { ... } ] }
=cut

sub api_list_chat :Path('chat') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if request is from localhost or workstation.local
    my $address = $c->req->address;
    my $is_local = ($address eq '127.0.0.1' || $address eq '::1' || $address =~ /^192\.168\.1\./);
    
    unless ($is_local) {
        my $validation = Comserv::Util::ApiTokenValidator->validate_from_request($c);
        unless ($validation->{valid}) {
            $c->res->status($validation->{code} || 401);
            $c->res->content_type('application/json');
            $c->res->body(encode_json({ success => 0, error => $validation->{error} || 'Authentication required' }));
            $c->detach();
        }
    }
    
    my $schema = $c->model('DBEncy');
    my @conversations = $schema->resultset('AiConversation')->search(
        {},
        { order_by => { -desc => 'created_at' }, rows => 50 }
    )->all;
    
    my @conv_list = map { { $_->get_columns } } @conversations;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_list_chat',
        "Chat conversations listed via API (Local: $is_local)");
    
    $c->res->status(200);
    $c->res->content_type('application/json');
    $c->res->body(encode_json({
        success => 1,
        count => scalar(@conv_list),
        conversations => \@conv_list
    }));
    $c->detach();
}

=head2 api_get_chat_messages

GET /api/chat/messages/:conversation_id - Get messages for a conversation

Returns: { success, messages: [ { ... } ] }
=cut

sub api_get_chat_messages :Path('chat/messages') :Args(1) {
    my ($self, $c, $conversation_id) = @_;
    
    # Check if request is from localhost or workstation.local
    my $address = $c->req->address;
    my $is_local = ($address eq '127.0.0.1' || $address eq '::1' || $address =~ /^192\.168\.1\./);
    
    unless ($is_local) {
        my $validation = Comserv::Util::ApiTokenValidator->validate_from_request($c);
        unless ($validation->{valid}) {
            $c->res->status($validation->{code} || 401);
            $c->res->content_type('application/json');
            $c->res->body(encode_json({ success => 0, error => $validation->{error} || 'Authentication required' }));
            $c->detach();
        }
    }
    
    my $schema = $c->model('DBEncy');
    my @messages = $schema->resultset('AiMessage')->search(
        { conversation_id => $conversation_id },
        { order_by => { -asc => 'created_at' } }
    )->all;
    
    my @message_list = map { { $_->get_columns } } @messages;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_get_chat_messages',
        "Messages for conversation $conversation_id listed via API (Local: $is_local)");
    
    $c->res->status(200);
    $c->res->content_type('application/json');
    $c->res->body(encode_json({
        success => 1,
        count => scalar(@message_list),
        messages => \@message_list
    }));
    $c->detach();
}

=head2 api_create_chat_message

POST /api/chat/message - Create a new chat message (logging)

Required JSON fields: content, role, conversation_id
Optional: agent_type, model_used, metadata

Returns: { success, message_id, conversation_id }
=cut

sub api_create_chat_message :Path('chat/message') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if request is from localhost or workstation.local
    my $address = $c->req->address;
    my $is_local = ($address eq '127.0.0.1' || $address eq '::1' || $address =~ /^192\.168\.1\./);
    
    my $api_user_id = 1; # Default to admin if local
    
    # Verify if default user exists to prevent foreign key violations
    try {
        my $user_check = $c->model('DBEncy::User')->find($api_user_id);
        unless ($user_check) {
            # Fallback to first available user
            my $fallback_user = $c->model('DBEncy::User')->first();
            $api_user_id = $fallback_user ? $fallback_user->id : 1;
        }
    } catch {
        # Fallback to 1 if anything goes wrong, but at least we tried
        $api_user_id = 1;
    };
    unless ($is_local) {
        my $validation = Comserv::Util::ApiTokenValidator->validate_from_request($c);
        unless ($validation->{valid}) {
            $c->res->status($validation->{code} || 401);
            $c->res->content_type('application/json');
            $c->res->body(encode_json({ success => 0, error => $validation->{error} || 'Authentication required' }));
            $c->detach();
        }
        
        my $schema = $c->model('DBEncy');
        my $api_token = $schema->resultset('ApiToken')->find($validation->{api_token_id});
        $api_user_id = $api_token->user_id if $api_token;
    }
    
    my $params;
    eval {
        my $body = $c->request->body;
        if ($body) {
            if (ref($body) && $body->can('seek')) {
                seek($body, 0, 0);
                my $raw_body = do { local $/; <$body> };
                $params = decode_json($raw_body);
            } else {
                $params = decode_json($body);
            }
        }
    };
    if ($@) {
        $c->res->status(400);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => 0, error => "Invalid JSON: $@", code => 'json_parse_error' }));
        $c->detach();
    }
    
    my $schema = $c->model('DBEncy');
    
    my @required = qw(content role);
    my @missing = grep { !defined $params->{$_} || $params->{$_} eq '' } @required;
    if (@missing) {
        $c->res->status(400);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => 0, error => "Missing required fields: " . join(', ', @missing), code => 'validation_error' }));
        $c->detach();
    }
    
    my $conversation_id = $params->{conversation_id};
    unless ($conversation_id) {
        my $title = $params->{title} || 'API Conversation';
        my $conversation = $schema->resultset('AiConversation')->create({
            user_id => $api_user_id,
            title => $title,
            status => 'active',
            metadata => $params->{metadata} || '{}'
        });
        $conversation_id = $conversation->id;
    }
    
    my $message = $schema->resultset('AiMessage')->create({
        conversation_id => $conversation_id,
        user_id => $api_user_id,
        role => $params->{role},
        content => $params->{content},
        agent_type => $params->{agent_type} || 'chat',
        model_used => $params->{model_used} || 'unknown',
        metadata => $params->{metadata} || '{}',
        ip_address => $address,
        user_role => 'api'
    });
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_create_chat_message',
        "Message created via API: ID=" . $message->id . ", ConvID=" . $conversation_id);
    
    $c->res->status(200);
    $c->res->content_type('application/json');
    $c->res->body(encode_json({
        success => 1,
        message_id => $message->id,
        conversation_id => $conversation_id
    }));
    $c->detach();
}

=head2 api_system_logs

GET /api/system_logs - Query system_log table for AI agents and monitoring tools

Optional query params:
  level     - filter by level: error, warn, info (default: all)
  limit     - max records to return (default: 100, max: 1000)
  since     - ISO datetime string, return only records after this time
  sitename  - filter by sitename
  subroutine - filter by subroutine name (partial match)
  search    - search message text (partial match)

Returns: { success, count, logs: [ { id, timestamp, level, file, line, subroutine, message, sitename, username, system_identifier } ] }
=cut

sub api_system_logs :Path('system_logs') :Args(0) {
    my ($self, $c) = @_;

    my $address  = $c->req->address;
    my $is_local = ($address eq '127.0.0.1' || $address eq '::1' || $address =~ /^192\.168\.1\./);

    unless ($is_local) {
        my $validation = Comserv::Util::ApiTokenValidator->validate_from_request($c);
        unless ($validation->{valid}) {
            $c->res->status($validation->{code} || 401);
            $c->res->content_type('application/json');
            $c->res->body(encode_json({ success => 0, error => $validation->{error} || 'Authentication required' }));
            $c->detach();
        }
    }

    my $level      = $c->req->param('level')      // '';
    my $limit      = $c->req->param('limit')      // 100;
    my $since      = $c->req->param('since')      // '';
    my $sitename   = $c->req->param('sitename')   // '';
    my $subroutine = $c->req->param('subroutine') // '';
    my $search     = $c->req->param('search')     // '';

    $limit = int($limit);
    $limit = 100  if $limit < 1;
    $limit = 1000 if $limit > 1000;

    my %where;
    $where{level}      = $level                        if $level;
    $where{sitename}   = $sitename                     if $sitename;
    $where{subroutine} = { -like => "%$subroutine%" }  if $subroutine;
    $where{message}    = { -like => "%$search%" }      if $search;
    $where{timestamp}  = { '>' => $since }             if $since;

    my $schema = $c->model('DBEncy');
    my @logs;
    eval {
        @logs = $schema->resultset('SystemLog')->search(
            \%where,
            { order_by => { -desc => 'timestamp' }, rows => $limit }
        )->all;
    };
    if ($@) {
        $c->res->status(500);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => 0, error => "Database error: $@" }));
        $c->detach();
    }

    my @log_list = map { { $_->get_columns } } @logs;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_system_logs',
        "system_logs queried via API: level=$level limit=$limit count=" . scalar(@log_list) . " (Local: $is_local)");

    $c->res->status(200);
    $c->res->content_type('application/json');
    $c->res->body(encode_json({
        success => 1,
        count   => scalar(@log_list),
        filters => {
            level      => $level      || undef,
            since      => $since      || undef,
            sitename   => $sitename   || undef,
            subroutine => $subroutine || undef,
            search     => $search     || undef,
            limit      => $limit,
        },
        logs => \@log_list,
    }));
    $c->detach();
}

=head2 _api_authenticate

Shared auth gate for the data endpoints. Requests originating from localhost or the
192.168.1.0/24 LAN bypass token validation (development/workstation convenience); everything
else must present a valid API token.

Returns the C<User> row behind the API token when one was used, or undef for local requests.
Detaches with a JSON error response when authentication fails.

=cut

sub _api_authenticate {
    my ($self, $c) = @_;

    my $address  = $c->req->address // '';
    my $is_local = ($address eq '127.0.0.1' || $address eq '::1' || $address =~ /^192\.168\.1\./);
    return undef if $is_local;

    my $validation = Comserv::Util::ApiTokenValidator->validate_from_request($c);
    unless ($validation->{valid}) {
        $self->_json_error($c, $validation->{code} || 401,
            $validation->{error} || 'Authentication required', 'unauthorized');
    }

    my $api_token = $c->model('DBEncy')->resultset('ApiToken')->find($validation->{api_token_id});
    return $api_token ? $api_token->user : undef;
}

=head2 _parse_json_body

Decode the JSON request body. Detaches with a 400 when the body is not valid JSON.

=cut

sub _parse_json_body {
    my ($self, $c) = @_;

    my $params;
    eval {
        my $body = $c->request->body;
        if ($body) {
            if (ref($body) && $body->can('seek')) {
                seek($body, 0, 0);
                my $raw_body = do { local $/; <$body> };
                $params = decode_json($raw_body);
            }
            else {
                $params = decode_json($body);
            }
        }
    };
    if ($@) {
        $self->_json_error($c, 400, "Invalid JSON: $@", 'json_parse_error');
    }

    unless (ref $params eq 'HASH') {
        $self->_json_error($c, 400, 'Request body must be a JSON object', 'validation_error');
    }

    return $params;
}

=head2 _json_error

Emit a JSON error response and detach.

=cut

sub _json_error {
    my ($self, $c, $status, $message, $code) = @_;

    $c->res->status($status || 400);
    $c->res->content_type('application/json');
    $c->res->body(encode_json({
        success => 0,
        error   => $message,
        ($code ? (code => $code) : ()),
    }));
    $c->detach();
}

=head2 _json_ok

Emit a JSON success response and detach.

=cut

sub _json_ok {
    my ($self, $c, $payload) = @_;

    $c->res->status(200);
    $c->res->content_type('application/json');
    $c->res->body(encode_json({ success => 1, %{ $payload || {} } }));
    $c->detach();
}

=head2 _apply_updates

Copy whitelisted fields from the request params onto a DBIC row.

Only keys present in the request are touched, so a partial update leaves every other column
alone. An explicit JSON null clears a nullable column. Returns the list of changed field names.

=cut

sub _apply_updates {
    my ($self, $row, $params, $allowed, $nullable) = @_;

    my %nullable = map { $_ => 1 } @{ $nullable || [] };
    my %updates;

    for my $field (@$allowed) {
        next unless exists $params->{$field};

        my $value = $params->{$field};

        if (!defined $value || (!ref $value && $value eq '')) {
            next unless $nullable{$field};
            $updates{$field} = undef;
            next;
        }

        $updates{$field} = $value;
    }

    return () unless %updates;

    $row->update(\%updates);
    return sort keys %updates;
}

=head2 api_todo_update

POST /api/todo/update - Update an existing todo (bypass token for local/workstation.local)

Body: { record_id | todo_id, <any updatable field> }

Only the fields present in the body are changed. Nullable fields (parent_id,
blocked_by_todo_id, plan_id, scheduled_date) accept an explicit null to clear them.

Returns: { success, message, updated: [ field, ... ], todo: { ... } }

=cut

sub api_todo_update :Path('todo/update') :Args(0) {
    my ($self, $c) = @_;

    my $api_user = $self->_api_authenticate($c);
    my $params   = $self->_parse_json_body($c);

    my $todo_id = $params->{record_id} || $params->{todo_id} || $params->{id};
    unless ($todo_id) {
        $self->_json_error($c, 400, 'Missing required field: record_id', 'validation_error');
    }

    my $schema = $c->model('DBEncy');
    my $todo   = $schema->resultset('Todo')->find($todo_id);
    unless ($todo) {
        $self->_json_error($c, 404, "Todo $todo_id not found", 'not_found');
    }

    # Validate a referenced project before pointing the todo at it
    if ($params->{project_id}) {
        unless ($schema->resultset('Project')->find($params->{project_id})) {
            $self->_json_error($c, 400, "Invalid project_id: $params->{project_id}", 'invalid_project');
        }
    }

    # Keep the date range coherent using whichever side is being changed
    my $start_date = defined $params->{start_date} ? $params->{start_date} : $todo->start_date;
    my $due_date   = defined $params->{due_date}   ? $params->{due_date}   : $todo->due_date;
    if ($start_date && $due_date && "$start_date" gt "$due_date") {
        $self->_json_error($c, 400, 'Start date cannot be after due date', 'date_validation_error');
    }

    # A todo may not block itself
    if (defined $params->{blocked_by_todo_id} && $params->{blocked_by_todo_id}
        && $params->{blocked_by_todo_id} == $todo->record_id) {
        $self->_json_error($c, 400, 'A todo cannot be blocked by itself', 'validation_error');
    }

    my @allowed = qw(
        subject description project_id project_code sitename
        start_date due_date scheduled_date priority status
        estimated_man_hours accumulative_time comments
        developer owner reporter company_code
        parent_id parent_todo sort_order is_blocking blocked_by_todo_id
        plan_id share billable todo_type
    );
    my @nullable = qw(parent_id blocked_by_todo_id plan_id scheduled_date comments);

    my $current_user = $api_user ? $api_user->username : ($c->session->{username} || 'system');

    my @updated;
    eval {
        @updated = $self->_apply_updates($todo, $params, \@allowed, \@nullable);
        if (@updated) {
            $todo->update({
                last_mod_by   => $current_user,
                last_mod_date => DateTime->now->ymd,
            });
        }
    };
    if ($@) {
        my $err = "$@"; $err =~ s/\s+at\s+.*//s;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'api_todo_update',
            "Failed to update todo $todo_id: $err");
        $self->_json_error($c, 500, "Failed to update todo: $err", 'update_failed');
    }

    unless (@updated) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'api_todo_update',
            "Todo $todo_id update requested with no recognised fields");
        $self->_json_ok($c, {
            message => 'No updatable fields supplied — nothing changed',
            updated => [],
            todo    => $self->_todo_to_hash($todo),
        });
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_todo_update',
        "Todo updated via API: ID=$todo_id, fields=" . join(',', @updated));

    $self->_json_ok($c, {
        message => 'Todo updated successfully',
        todo_id => $todo->record_id,
        updated => \@updated,
        todo    => $self->_todo_to_hash($todo),
    });
}

=head2 api_project_update

POST /api/project/update - Update an existing project (bypass token for local/workstation.local)

Body: { project_id | id, <any updatable field> }

Only the fields present in the body are changed. Passing C<append_comments> instead of
C<comments> appends to the existing comments rather than replacing them — useful for adding
plan links without destroying existing notes.

Returns: { success, message, updated: [ field, ... ], project: { ... } }

=cut

sub api_project_update :Path('project/update') :Args(0) {
    my ($self, $c) = @_;

    my $api_user = $self->_api_authenticate($c);
    my $params   = $self->_parse_json_body($c);

    my $project_id = $params->{project_id} || $params->{id};
    unless ($project_id) {
        $self->_json_error($c, 400, 'Missing required field: project_id', 'validation_error');
    }

    my $schema  = $c->model('DBEncy');
    my $project = $schema->resultset('Project')->find($project_id);
    unless ($project) {
        $self->_json_error($c, 404, "Project $project_id not found", 'not_found');
    }

    # Guard against a project becoming its own parent
    if (defined $params->{parent_id} && $params->{parent_id}
        && $params->{parent_id} == $project->id) {
        $self->_json_error($c, 400, 'A project cannot be its own parent', 'validation_error');
    }

    # Append mode for comments — add without destroying what is already there
    if (defined $params->{append_comments} && $params->{append_comments} ne '') {
        my $existing = $project->comments // '';
        $params->{comments} = $existing eq ''
            ? $params->{append_comments}
            : $existing . "\n" . $params->{append_comments};
    }

    my @allowed = qw(
        name description start_date end_date status
        project_code project_size estimated_man_hours
        developer_name client_name sitename comments
        parent_id sort_order priority
    );
    my @nullable = qw(parent_id);

    my @updated;
    eval {
        @updated = $self->_apply_updates($project, $params, \@allowed, \@nullable);
    };
    if ($@) {
        my $err = "$@"; $err =~ s/\s+at\s+.*//s;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'api_project_update',
            "Failed to update project $project_id: $err");
        $self->_json_error($c, 500, "Failed to update project: $err", 'update_failed');
    }

    unless (@updated) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'api_project_update',
            "Project $project_id update requested with no recognised fields");
        $self->_json_ok($c, {
            message => 'No updatable fields supplied — nothing changed',
            updated => [],
            project => { $project->get_columns },
        });
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_project_update',
        "Project updated via API: ID=$project_id, fields=" . join(',', @updated));

    $self->_json_ok($c, {
        message    => 'Project updated successfully',
        project_id => $project->id,
        updated    => \@updated,
        project    => { $project->get_columns },
    });
}

sub _todo_to_hash {
    my ($self, $todo) = @_;

    # Resolve the attached project via the existing belongs_to(project)
    # relationship so API/AI-agent callers see the SAME project name + link
    # the web detail page renders (record.project.name ->
    # /project/details?project_id=<id>), instead of only a raw project_id.
    my $project = $todo->project;
    my $project_name = $project ? $project->name : undef;
    my $project_link = $project ? "/project/details?project_id=" . $project->id : undef;

    return {
        id => $todo->id,
        subject => $todo->subject,
        description => $todo->description,
        project_id => $todo->project_id,
        project_name => $project_name,
        project_link => $project_link,
        start_date => $todo->start_date,
        due_date => $todo->due_date,
        priority => $todo->priority,
        status => $todo->status,
        assigned_to => $todo->developer,
        sitename => $todo->sitename,
        posted_by => $todo->username_of_poster,
        accumulative_time => $todo->accumulative_time || 0,
    };
}

sub _generate_random_token {
    my @chars = ('a'..'z', 'A'..'Z', 0..9, '-', '_');
    my $token = '';
    for (1..32) {
        $token .= $chars[int(rand(@chars))];
    }
    return $token;
}

# ----------------------------------------------------------------------------
# Time-log open/close actions (project 240 TODOLIST-UI)
#
# Mirror Comserv::Controller::Todo::open_log / close_log / done_with_log exactly,
# but authorize via the same local-network bypass used by /api/todos (localhost /
# 192.168.1.*), so an agent or script can drive the same log bookkeeping the
# Start/Done buttons perform without holding a browser session.
# ----------------------------------------------------------------------------

sub _api_local_ok {
    my ($c) = @_;
    my $address = $c->req->address;
    return ($address eq '127.0.0.1' || $address eq '::1' || $address =~ /^192\.168\.1\./) ? 1 : 0;
}

sub _api_log_unauthorized {
    my ($c) = @_;
    $c->res->status(403);
    $c->res->content_type('application/json');
    $c->res->body(encode_json({ success => 0, error => 'Local network only' }));
    $c->detach();
}

=head2 api_todo_open_log

POST /api/todo/open_log  { record_id, actor?, username?, notes? }
Opens a work log for a todo (status -> 5). Mirrors Todo::open_log SQL.

IDENTITY CONTRACT: the caller MUST self-identify via C<actor> (legacy alias C<username>).
The default is the neutral string C<api> so no single agent (Hermes, the in-app AI editor,
a future Android/iOS app, or an external ENcy integrator) impersonates another actor or the
site owner. Pass C<actor> explicitly; do not rely on the default for attributable work.

=cut

sub api_todo_open_log :Path('todo/open_log') :Args(0) {
    my ($self, $c) = @_;
    $c->res->content_type('application/json');
    unless (_api_local_ok($c)) { _api_log_unauthorized($c); return; }

    my $data = $self->_api_json_body($c);
    my $record_id = $data->{record_id};
    unless ($record_id) {
        $c->res->status(400);
        $c->res->body(encode_json({ success => 0, error => 'Missing record_id' }));
        return;
    }
    my $username = $data->{actor} // $data->{username} // 'api';

    my $now   = DateTime->now(time_zone => 'local');
    my $today = $now->ymd;
    my $time  = $now->hms;

    eval {
        my $dbh  = $c->model('DBEncy')->storage->dbh;
        my $todo = $c->model('DBEncy')->resultset('Todo')->find($record_id);
        die "Todo not found\n" unless $todo;

        my $existing = $dbh->selectrow_hashref(
            "SELECT record_id FROM log WHERE todo_record_id=? AND end_time='00:00:00' AND status!=3 LIMIT 1",
            undef, $record_id
        );
        if ($existing) {
            my $cur = $dbh->selectrow_array("SELECT status FROM todo WHERE record_id=?", undef, $record_id) // 0;
            $dbh->do("UPDATE todo SET status=5, last_mod_by=?, last_mod_date=? WHERE record_id=?",
                undef, $username, $today, $record_id) if $cur != 5;
            $c->res->body(encode_json({ success => 1, already_open => 1, log_id => $existing->{record_id} }));
            return;
        }

        my $proj_code = '';
        if ($todo->project_id) {
            my $proj = eval { $c->model('DBEncy')->resultset('Project')->find($todo->project_id) };
            $proj_code = $proj ? ($proj->project_code || '') : '';
        }
        my $sitename_val = eval { $todo->sitename } || 'CSC';
        my $due_date_val = eval { my $dd = $todo->due_date; $dd ? (ref($dd) ? $dd->ymd : substr("$dd",0,10)) : $today } // $today;
        my $priority_val = eval { $todo->priority } // 5;
        my $comments_val = eval { $todo->comments } // '';
        my $group_val    = '';

        $dbh->do(
            'INSERT INTO log (todo_record_id, username, sitename, project_code, abstract, details, start_date, due_date, start_time, end_time, time, status, priority, last_mod_by, last_mod_date, group_of_poster, comments) VALUES (?,?,?,?,?,?,?,?,?,"00:00:00","00:00:00",2,?,?,?,?,?)',
            undef,
            $record_id, $username, $sitename_val, $proj_code,
            'Started: ' . ($todo->subject // ''),
            'Work begun on this step by ' . $username,
            $today, $due_date_val, $time,
            $priority_val, $username, $today, $group_val, $comments_val
        );
        my $new_log_id = $dbh->last_insert_id(undef, undef, 'log', 'record_id');
        $dbh->do("UPDATE todo SET status=5, last_mod_by=?, last_mod_date=? WHERE record_id=?",
            undef, $username, $today, $record_id);

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_todo_open_log',
            "Log opened for todo $record_id by $username (log_id=$new_log_id)");
        $c->res->body(encode_json({ success => 1, log_id => ($new_log_id // 0) }));
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'api_todo_open_log',
            "Failed open_log for todo $record_id: $@");
        $c->res->body(encode_json({ success => 0, error => "$@" }));
    }
}

=head2 api_todo_close_log

POST /api/todo/close_log  { record_id, notes?, username? }
Closes an open work log (status -> 3) and sets todo back to IN PROGRESS (2).
Mirrors Todo::close_log SQL.

=cut

sub api_todo_close_log :Path('todo/close_log') :Args(0) {
    my ($self, $c) = @_;
    $c->res->content_type('application/json');
    unless (_api_local_ok($c)) { _api_log_unauthorized($c); return; }

    my $data = $self->_api_json_body($c);
    my $record_id = $data->{record_id};
    unless ($record_id) {
        $c->res->status(400);
        $c->res->body(encode_json({ success => 0, error => 'Missing record_id' }));
        return;
    }
    my $username = $data->{actor} // $data->{username} // 'api';
    my $notes    = $data->{notes} // '';

    my $now_dt   = DateTime->now(time_zone => 'local');
    my $today    = $now_dt->ymd;
    my $now_hms  = $now_dt->strftime('%H:%M:%S');

    eval {
        my $dbh = $c->model('DBEncy')->storage->dbh;
        my $open_row = $dbh->selectrow_hashref(
            "SELECT record_id, start_time FROM log WHERE todo_record_id=? AND end_time='00:00:00' AND status!=3 ORDER BY record_id DESC LIMIT 1",
            undef, $record_id
        );
        die "No open log found for todo $record_id\n" unless $open_row;

        my $raw_start  = $open_row->{start_time} // '09:00:00';
        my $start_hms  = ($raw_start =~ /^\d{1,2}:\d{2}/) ? substr($raw_start, 0, 8) : '09:00:00';
        my ($sh, $sm)  = ($start_hms =~ /^(\d+):(\d+)/);
        my ($eh, $em)  = ($now_hms   =~ /^(\d{2}):(\d{2})/);
        my $dur_mins   = ($eh * 60 + $em) - ($sh * 60 + $sm);
        $dur_mins = 1 if $dur_mins <= 0;
        my $dur_hms = sprintf('%02d:%02d:00', int($dur_mins / 60), $dur_mins % 60);

        $dbh->do(
            'UPDATE log SET end_time=?, time=?, status=3, last_mod_by=?, last_mod_date=?, comments=? WHERE record_id=?',
            undef, $now_hms, $dur_hms, $username, $today, $notes, $open_row->{record_id}
        );
        $dbh->do("UPDATE todo SET status=2, last_mod_by=?, last_mod_date=? WHERE record_id=? AND status=5",
            undef, $username, $today, $record_id);

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_todo_close_log',
            "Closed log $open_row->{record_id} for todo $record_id ($dur_mins min)");
        $c->res->body(encode_json({ success => 1, duration_mins => $dur_mins }));
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'api_todo_close_log',
            "Failed close_log for todo $record_id: $@");
        $c->res->body(encode_json({ success => 0, error => "$@" }));
    }
}

=head2 api_todo_done_with_log

POST /api/todo/done_with_log  { record_id, notes?, username? }
Closes an open log (if any) AND marks the todo DONE (status 3).
Mirrors Todo::done_with_log SQL.

=cut

sub api_todo_done_with_log :Path('todo/done_with_log') :Args(0) {
    my ($self, $c) = @_;
    $c->res->content_type('application/json');
    unless (_api_local_ok($c)) { _api_log_unauthorized($c); return; }

    my $data = $self->_api_json_body($c);
    my $record_id = $data->{record_id};
    unless ($record_id) {
        $c->res->status(400);
        $c->res->body(encode_json({ success => 0, error => 'Missing record_id' }));
        return;
    }
    my $username = $data->{actor} // $data->{username} // 'api';
    my $notes    = $data->{notes} // '';

    my $now_dt   = DateTime->now(time_zone => 'local');
    my $today    = $now_dt->ymd;
    my $now_hms  = $now_dt->strftime('%H:%M:%S');

    eval {
        my $dbh  = $c->model('DBEncy')->storage->dbh;
        my $todo = $c->model('DBEncy')->resultset('Todo')->find($record_id);
        die "Todo not found\n" unless $todo;

        my $open_row = $dbh->selectrow_hashref(
            "SELECT record_id, start_time FROM log WHERE todo_record_id=? AND end_time='00:00:00' AND status!=3 ORDER BY record_id DESC LIMIT 1",
            undef, $record_id
        );
        if ($open_row) {
            my $raw_start  = $open_row->{start_time} // '09:00:00';
            my $start_hms  = ($raw_start =~ /^\d{1,2}:\d{2}/) ? substr($raw_start, 0, 8) : '09:00:00';
            my ($sh, $sm)  = ($start_hms =~ /^(\d+):(\d+)/);
            my ($eh, $em)  = ($now_hms   =~ /^(\d{2}):(\d{2})/);
            my $dur_mins   = ($eh * 60 + $em) - ($sh * 60 + $sm);
            $dur_mins = 1 if $dur_mins <= 0;
            my $dur_hms = sprintf('%02d:%02d:00', int($dur_mins / 60), $dur_mins % 60);
            $dbh->do(
                'UPDATE log SET end_time=?, time=?, status=3, last_mod_by=?, last_mod_date=?, comments=? WHERE record_id=?',
                undef, $now_hms, $dur_hms, $username, $today, $notes, $open_row->{record_id}
            );
        }

        $dbh->do("UPDATE todo SET status=3, last_mod_by=?, last_mod_date=? WHERE record_id=?",
            undef, $username, $today, $record_id);

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_todo_done_with_log',
            "Todo $record_id marked done (log closed if open)");
        $c->res->body(encode_json({ success => 1, log_closed => ($open_row ? 1 : 0) }));
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'api_todo_done_with_log',
            "Failed done_with_log for todo $record_id: $@");
        $c->res->body(encode_json({ success => 0, error => "$@" }));
    }
}

=head2 _api_json_body

Read and JSON-decode the request body (best-effort). Returns a hashref.

=cut

sub _api_json_body {
    my ($self, $c) = @_;
    my $body_fh = $c->req->body;
    my $body    = $body_fh ? do { local $/; <$body_fh> } : '';
    my $data;
    eval { require JSON; $data = JSON::decode_json($body) if $body; };
    return $data && ref($data) eq 'HASH' ? $data : {};
}

# ----------------------------------------------------------------------------
# AI "Top 5" for the Focus Queue (project 240 TODOLIST-UI / Phase 5b)
#
# Returns the 5 items the AI judges most worth doing next, each with a
# one-line rationale. The AI reasons over BOTH planning sources, combined:
#
#   (a) open todos — the FULL scored CSC-open set (top 50 by ap_score), and
#   (b) plan docs  — BOTH the on-disk root/Documentation/*.tt/* plan corpus AND
#                    the DB DailyPlan rows (planning-system plans + their open
#                    phase todos).
#
# The AI is asked to return up to 5 picks. Each pick is either a real todo
# ({"record_id": <int>, ...}) it can link to, or a plan-doc-only next step
# ({"plan_item": {...}, ...}) that has no todo yet — surfaced as advisory text,
# never mutated. The selection is INDEPENDENT of the Focus Queue's Role/Site/
# Project filter toggles. Advisory only: never reorders, closes, or mutates.
#
# Reuses the existing AI2 provider (Model::AI2::Provider::Ollama) so there is
# no second AI path. Default model = curated local Ollama; if unavailable,
# fall back to the Router's default model.
# ----------------------------------------------------------------------------

use File::Find ();
use Encode     ();

sub api_focus_top5 :Path('focus/top5') :Args(0) {
    my ($self, $c) = @_;
    $c->res->content_type('application/json');
    unless (_api_local_ok($c)) { _api_log_unauthorized($c); return; }

    my $data = $self->_api_json_body($c);
    my $req_model = $data->{model} // '';
    $req_model =~ s/^\s+|\s+$//g;
    my $now_epoch = time();

    # ── Resolve which model(s) to ask (honors the UI's explicit choice; falls
    #    back to the chat system's current model so the button works with no
    #    selection). @targets / $can_select / @models feed the tail below. ──
    my @targets;
    my @models;
    my $can_select = 0;
    my $roles = $c->session->{roles} || [];
    if (ref($roles) eq 'ARRAY') { $can_select = grep { $_ =~ /^(admin|developer|editor)$/i } @$roles; }

    my $req_host = $data->{host} // '';
    my @req_models = ref($data->{models}) eq 'ARRAY' ? @{ $data->{models} } : ();
    if (@req_models) {
        for my $m (@req_models) {
            if (ref($m) eq 'HASH' && $m->{name}) {
                push @targets, { name => $m->{name}, host => $m->{host} // '' };
            } elsif (!ref($m) && $m) {
                push @targets, { name => $m, host => '' };
            }
        }
    } elsif ($req_model) {
        push @targets, { name => $req_model, host => $req_host };
    }

    # Build the list of selectable models for the UI (same facade the chat
    # header dropdown uses). Surfaced in the response so the UI can label hosts.
    # Default comes from the chat system's CURRENT model when available; if that
    # is missing we fall back to the shared catalog default (ModelCatalog) rather
    # than a hardcoded localhost Ollama slug.
    my ($def_prov, $def_name) = split(/\|/, _focus_default_model($c), 2);
    my $default_model = $def_name // '';
    my $cfg_host      = 'localhost';
    my $ai_facade     = eval { $c->model('AI') };
    if ($ai_facade) {
        my ($host, $port, $cur, $inst) = eval { $ai_facade->get_current_config($c, $can_select) };
        $cfg_host      = $host      if $host;
        $default_model = $cur       if $cur;
        if ($inst && ref($inst) eq 'ARRAY') {
            for my $m (@$inst) {
                my $n = ref($m) ? ($m->{name} // $m->{model} // $m) : $m;
                push @models, { name => $n, provider => 'ollama', host => $host } if $n;
            }
        }
        my @ext = _focus_external_models($c);
        for my $m (@ext) {
            push @models, { name => $m->{name}, provider => $m->{provider} // 'external',
                            label => $m->{label} // ($m->{name} // ''), host => '' };
        }
    }
    # Default the target to the chat system's current model when none passed.
    # Only when it is a real (non-empty) model — never invent one.
    unless (@targets || !$default_model) {
        push @targets, { name => $default_model, host => '' };
    }
    push @models, { name => $default_model, provider => 'ollama', host => $cfg_host }
        if $default_model && !($default_model eq ($models[0]{name} // '') && @models);
    my %seen; @models = grep { !$seen{ $_->{name} }++ } @models;

    # ── Delegate the AI work to Model::AI2::FocusTune (the SAME brain the
    #    Chat-with-AI focustune agent uses). One implementation, two callers. ──
    my $tune = $c->model('AI2::FocusTune');
    my ($top, $rbid) = $tune->gather_candidates($c, $now_epoch);
    my @plan_docs = $tune->plan_docs($c);
    my ($system, $user_prompt) = $tune->build_prompt($c, $top, \@plan_docs);

    my @results;
    for my $tgt (@targets) {
        push @results, $tune->run_one($c, $tgt, $system, $user_prompt, $can_select);
    }

    my @parsed_results = map { $tune->parse_result($c, $_, $top, $rbid, $now_epoch) } @results;
    my $payload = $parsed_results[0];
    $payload->{models} = \@models;
    $payload->{note}   = 'Advisory + tuning preview only — does not reorder, close, or mutate any todo or plan. Independent of Focus Queue filters. Reads both plan docs and the todo system.'
                        . (@targets > 1 ? ' Batch comparison of ' . scalar(@targets) . ' models.' : '');
    if (@targets > 1) {
        $payload->{results} = \@parsed_results;
    }
    $c->res->body(encode_json($payload));
}

# ----------------------------------------------------------------------------
# GET /api/focus/models — list the models the AI Focus-Tune picker can offer.
# Uses Comserv::Model::AI (the SAME facade the chat-header model dropdown uses)
# so this reflects every actually-available model, not a guessed localhost list.
# Local-network bypass.
# ----------------------------------------------------------------------------

sub api_focus_models :Path('focus/models') :Args(0) {
    my ($self, $c) = @_;
    $c->res->content_type('application/json');
    unless (_api_local_ok($c)) { _api_log_unauthorized($c); return; }

    my @models;
    my $can_select = 0;
    my $roles = $c->session->{roles} || [];
    if (ref($roles) eq 'ARRAY') { $can_select = grep { $_ =~ /^(admin|developer|editor)$/i } @$roles; }

    eval {
        my $ai = $c->model('AI');
        # Installed Ollama models (what the chat header shows).
        my ($host, $port, $current_model, $installed) = $ai->get_current_config($c, $can_select);
        if ($installed && ref($installed) eq 'ARRAY') {
            for my $m (@$installed) {
                my $n = ref($m) ? ($m->{name} // $m->{model} // $m) : $m;
                next unless $n;
                push @models, { name => $n, provider => 'ollama', host => $host };
            }
        }
        # External (Grok/xAI, OpenRouter, ...) models — sourced from the SAME
        # live catalog the chat dropdown uses (Model::AI2::Router::get_available_models),
        # which does a real list_models() call against each provider's API. This
        # is the dynamic list: it reflects what the provider actually offers for
        # the configured key, not a stale DB snapshot. No hardcoded fallback.
        my @ext = _focus_external_models($c);
        for my $m (@ext) {
            push @models, { name => $m->{name}, provider => $m->{provider} // 'external',
                            label => $m->{label} // ($m->{name} // '') };
        }
    };
    my %seen; @models = grep { !$seen{ $_->{name} }++ } @models;
    # Attach real per-token pricing (USD per 1M) from the live Router catalog so
    # the picker can show cost like the chat dropdown does. Keyed by provider|name.
    my %price_by_model;
    my $price_src;
    eval { $price_src = $c->model('AI2::Router')->get_available_models($c); };
    $price_src = undef if $@;
    if ($price_src && ref($price_src) eq 'ARRAY') {
        for my $m (@$price_src) {
            next unless $m && ref($m) eq 'HASH' && $m->{name};
            my $svc  = $m->{provider} // '';
            my $key  = "$svc|" . $m->{name};
            $price_by_model{$key} = {
                price_prompt     => ($m->{price_prompt}     // 0) + 0,
                price_completion => ($m->{price_completion} // 0) + 0,
                price_tier       => $m->{price_tier} // '',
                free             => ($m->{free} || (($m->{name} // '') =~ /:free$/)) ? 1 : 0,
                local            => ($svc eq 'ollama') ? 1 : 0,
            };
        }
    }
    for my $m (@models) {
        my $k = ($m->{provider} // '') . '|' . $m->{name};
        if (my $p = $price_by_model{$k}) {
            $m->{price_prompt}     = $p->{price_prompt};
            $m->{price_completion} = $p->{price_completion};
            $m->{price_tier}       = $p->{price_tier};
            $m->{free}             = $p->{free};
            $m->{local}            = $p->{local};
        }
    }
    # The pre-selected default MUST be one of the dynamic models we just listed —
    # never a hardcoded slug that isn't actually an option. Prefer the shared
    # catalog default, but only if it is present in the live list; otherwise fall
    # back to the first listed (dynamic) model. Surfaced as `default` so the JS
    # picker pre-checks the right option instead of inventing one client-side.
    my $default = '';
    my $cat_def = _focus_default_model($c);
    if ($cat_def && $cat_def =~ /\|/) {
        my (undef, $cn) = split(/\|/, $cat_def, 2);
        if (grep { $_->{name} eq $cn } @models) { $default = $cat_def; }
    }
    unless ($default) {
        $default = (@models && $models[0]{provider})
            ? ($models[0]{provider} . '|' . $models[0]{name}) : '';
    }
    $c->res->body(encode_json({ success => 1, models => \@models, default => $default }));
}

# Gather the plan-doc context for api_focus_top5: BOTH the on-disk planning
# corpus (root/Documentation/**/*.{tt,md} that look like plan docs) AND the DB
# DailyPlan rows (with their open phase todos). Pure, no mutation; returns an
# array of hashrefs: { title, name, path, plan_id?, status?, open_phase_todos?,
# next_steps? }. The on-disk scan is bounded and best-effort (errors logged).
sub _focus_top5_plan_docs {
    my ($c) = @_;
    my @docs;

    # ── DB DailyPlan rows (planning-system plans) + their open phase todos ──
    eval {
        my $schema = $c->model('DBEncy');
        my @plans  = $schema->resultset('DailyPlan')->search(
            { status => { '!=' => 'completed' } },
            { order_by => { -desc => 'last_modified' }, rows => 50 }
        )->all;
        for my $pl (@plans) {
            my %h = (
                title   => $pl->plan_name,
                name    => $pl->plan_name,
                path    => 'DailyPlan:' . $pl->plan_name,
                plan_id => $pl->id,
                status  => $pl->status,
            );
            # Open phase todos that already exist for this plan.
            my @pt;
            eval {
                my @rows = $schema->resultset('Todo')->search(
                    { plan_id => $pl->id, status => { '!=' => '3' } },
                    { order_by => { -asc => 'priority' }, rows => 200 }
                )->all;
                @pt = map { { record_id => $_->record_id, priority => $_->priority,
                              subject => $_->subject } } @rows;
            };
            $h{open_phase_todos} = \@pt if @pt;
            push @docs, \%h;
        }
    };
    $c->log->warn("api_focus_top5: could not load DailyPlan rows: $@") if $@;

    # ── On-disk planning corpus (root/Documentation/**) ──
    eval {
        my $docs_root = $c->path_to('root', 'Documentation');
        my @tt_files;
        File::Find::find({
            wanted => sub {
                return unless -f $_;
                return unless /\.(tt|md)$/i;
                push @tt_files, $File::Find::name;
            },
            no_chdir => 1,
        }, $docs_root);

        # Bound the scan: cap files and prefer names that look like plan docs.
        my @planish = grep { m{([Pp]lan|roadmap|phase|strategy|design|proposal|todo)}i } @tt_files;
        my @chosen = @planish ? @planish : @tt_files;
        @chosen = @chosen[0 .. 60] if @chosen > 60;

        my $cap_bytes = 4_000;   # per-doc excerpt cap to bound the prompt
        for my $f (@chosen) {
            my $txt;
            eval {
                open my $fh, '<:raw', $f or return;
                local $/; $txt = <$fh>; close $fh;
                # Drop the leading Template-Toolkit META/POD-ish header cruft and
                # HTML tags so the AI sees the plan's prose, not markup.
                $txt =~ s/\[%[^%]*%\]//g;
                $txt =~ s/<[^>]+>//g;
                $txt = Encode::decode('UTF-8', $txt, Encode::FB_DEFAULT) if defined $txt;
                $txt = substr($txt, 0, $cap_bytes) if length($txt) > $cap_bytes;
            };
            next unless defined $txt && length($txt) > 40;
            my $rel = $f;
            $rel =~ s{^\Q$docs_root\E/?}{}i;
            # Pull a terse "next step" list: lines that look like pending work.
            my @steps = map { s/^\s*[-*]\s*//r }
                        grep { /^\s*[-*]\s*\S/ && /next|todo|phase|step|task|implement|add|fix|create|wire/i }
                        split /\n/, $txt;
            push @docs, {
                title => $rel,
                name  => $rel,
                path  => 'Documentation/' . $rel,
                next_steps => [ @steps ? @steps[0 .. ($#steps > 9 ? 9 : $#steps)] : () ],
            };
        }
    };
    $c->log->warn("api_focus_top5: could not scan on-disk plan docs: $@") if $@;

    return @docs;
}

1;
