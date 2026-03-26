package Comserv::Controller::Api;
use Moose;
use namespace::autoclean;
use JSON::MaybeXS;
use DateTime;
use Digest::SHA qw(sha256_hex);
use Comserv::Util::Logging;
use Comserv::Util::ApiTokenValidator;
use Comserv::Util::DocumentationConfig;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub _check_admin {
    my ($self, $c) = @_;
    
    unless ($c->user_exists) {
        $c->res->status(401);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({
            success => 0,
            error => 'Not authenticated. Please log in first.',
            code => 'not_authenticated'
        }));
        $c->detach();
    }
    
    my $roles = $c->session->{roles} || [];
    unless (grep { $_ eq 'admin' } @$roles) {
        $c->res->status(403);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({
            success => 0,
            error => 'Admin role required to generate API tokens.',
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
        $params = decode_json($body) if $body;
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
    my $username = $c->user->username;
    
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
    my $username = $c->user->username;
    
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
    my $username = $c->user->username;
    
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
    my @todos = $schema->resultset('Todo')->all;
    
    my @todo_list = map { { $_->get_columns } } @todos;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_list_todos',
        "Todos listed via API (Local: $is_local)");
    
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
    my $current_user = $api_user ? $api_user->username : ($c->user_exists ? $c->user->username : 'system');
    
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
    
    my $sitename = $c->session->{SiteName} || 'comserv';
    
    my $todo = $schema->resultset('Todo')->create({
        subject => $params->{subject},
        description => $params->{description} || '',
        project_id => $project_id,
        start_date => $start_date,
        due_date => $due_date,
        priority => $params->{priority},
        status => $params->{status},
        developer => $params->{assigned_to} || $current_user,
        sitename => $sitename,
        date_time_posted => DateTime->now->ymd . ' ' . DateTime->now->hms,
        username_of_poster => $current_user,
        last_mod_by => $current_user,
        last_mod_date => DateTime->now->ymd,
        parent_todo => '',
        estimated_man_hours => 0,
        accumulative_time => '00:00:00',
        group_of_poster => 'admin',
        project_code => 'system',
        share => 0,
        user_id => $api_user ? $api_user->id : 1,
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

=head2 api_todo_update

PATCH /api/todo/update/<record_id> - Update a todo's status and/or other fields.
Localhost bypasses auth; remote requires API token.

Optional JSON fields: status, priority, description, developer, comments

Returns: { success, message, todo: { ... } }
=cut

sub api_todo_update :Path('todo/update') :Args(1) {
    my ($self, $c, $record_id) = @_;

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
                error   => $validation->{error} || 'Authentication required',
                code    => $validation->{code}   || 'unauthorized'
            }));
            $c->detach();
        }
        my $schema    = $c->model('DBEncy');
        my $api_token = $schema->resultset('ApiToken')->find($validation->{api_token_id});
        $api_user     = $api_token->user if $api_token;
    }

    my $params;
    eval {
        my $body = $c->request->body;
        if ($body) {
            if (ref($body) && $body->can('seek')) {
                seek($body, 0, 0);
                my $raw_body = do { local $/; <$body> };
                $params = decode_json($raw_body) if $raw_body && $raw_body =~ /\S/;
            } else {
                $params = decode_json($body);
            }
        }
        $params ||= {};
    };
    if ($@) {
        $c->res->status(400);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => 0, error => "Invalid JSON: $@", code => 'json_parse_error' }));
        $c->detach();
    }

    my $schema = $c->model('DBEncy');
    my $todo   = $schema->resultset('Todo')->find($record_id);

    unless ($todo) {
        $c->res->status(404);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => 0, error => "Todo not found: $record_id", code => 'not_found' }));
        $c->detach();
    }

    my %allowed = map { $_ => 1 } qw(status priority description developer comments);
    my %update;
    for my $field (keys %$params) {
        $update{$field} = $params->{$field} if $allowed{$field};
    }

    if (%update) {
        my $current_user = $api_user ? $api_user->username : 'system';
        $update{last_mod_by}   = $current_user;
        $update{last_mod_date} = DateTime->now->ymd;
        $todo->update(\%update);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_todo_update',
            "Todo updated via API: record_id=$record_id, Fields=" . join(',', keys %update));
    }

    $c->res->status(200);
    $c->res->content_type('application/json');
    $c->res->body(encode_json({
        success => 1,
        message => 'Todo updated successfully',
        todo    => $self->_todo_to_hash($todo)
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

    my $current_user = $api_user ? $api_user->username : ($c->user_exists ? $c->user->username : 'system');
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
    my @projects = $schema->resultset('Project')->all;
    
    my @project_list = map { { $_->get_columns } } @projects;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_list_projects',
        "Projects listed via API (Local: $is_local)");
    
    $c->res->status(200);
    $c->res->content_type('application/json');
    $c->res->body(encode_json({
        success => 1,
        count => scalar(@project_list),
        projects => \@project_list
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

sub _todo_to_hash {
    my ($self, $todo) = @_;
    
    return {
        id => $todo->id,
        subject => $todo->subject,
        description => $todo->description,
        project_id => $todo->project_id,
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

1;
