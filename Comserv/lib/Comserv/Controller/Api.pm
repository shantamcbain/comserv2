package Comserv::Controller::Api;
use Moose;
use namespace::autoclean;
use JSON::MaybeXS;
use DateTime;
use Digest::SHA qw(sha256_hex);
use Comserv::Util::Logging;
use Comserv::Util::ApiTokenValidator;

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

sub _generate_random_token {
    my @chars = ('a'..'z', 'A'..'Z', 0..9, '-', '_');
    my $token = '';
    for (1..32) {
        $token .= $chars[int(rand(@chars))];
    }
    return $token;
}

1;
