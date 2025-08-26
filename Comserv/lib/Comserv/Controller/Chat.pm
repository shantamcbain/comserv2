package Comserv::Controller::Chat;
use Moose;
use namespace::autoclean;
use JSON;
use DateTime;
use Try::Tiny;

BEGIN { extends 'Catalyst::Controller'; }

=head1 NAME

Comserv::Controller::Chat - Chat Controller for Comserv

=head1 DESCRIPTION

Controller for handling chat functionality.

=head1 METHODS

=cut

=head2 index

Chat home page

=cut

sub index :Path :Args(0) {
    my ($self, $c) = @_;
    
    # Set the template
    $c->stash->{template} = 'chat/index.tt';
}

=head2 send_message

API endpoint to send a chat message

=cut

sub send_message :Path('send_message') :Args(0) {
    my ($self, $c) = @_;
    
    # Log the action
    $c->log->debug("Chat: Processing send_message request");
    
    # Get the message from the request
    my $message = $c->req->params->{message};
    my $username = $c->session->{username} || 'Guest';
    my $domain = $c->req->uri->host || 'unknown';
    my $site_name = $c->session->{SiteName} || 'unknown';
    
    # Validate the message
    unless ($message) {
        $c->log->debug("Chat: Empty message received");
        $c->response->status(400);
        $c->response->body(encode_json({
            success => 0,
            error => 'Message cannot be empty'
        }));
        return;
    }
    
    # Log with domain information
    $c->log->debug("Chat: Message received from $username on domain $domain (site: $site_name)");
    
    try {
        # Store the message in the database
        my $chat_message = $c->model('DB::ChatMessage')->create({
            username => $username,
            message => $message,
            timestamp => DateTime->now->iso8601,
            is_read => 0,
            domain => $domain,
            site_name => $site_name,
        });
        
        # Log success
        $c->log->debug("Chat: Message stored successfully");
        
        # Return success response
        $c->response->content_type('application/json');
        $c->response->body(encode_json({
            success => 1,
            message_id => $chat_message->id,
            timestamp => $chat_message->timestamp,
        }));
    } catch {
        # Log error
        $c->log->error("Chat: Error storing message: $_");
        
        # Return error response
        $c->response->status(500);
        $c->response->body(encode_json({
            success => 0,
            error => 'Failed to store message'
        }));
    };
}

=head2 get_messages

API endpoint to retrieve chat messages

=cut

sub get_messages :Path('get_messages') :Args(0) {
    my ($self, $c) = @_;
    
    # Log the action
    $c->log->debug("Chat: Processing get_messages request");
    
    # Get parameters
    my $last_id = $c->req->params->{last_id} || 0;
    my $username = $c->session->{username};
    
    try {
        # Get messages newer than last_id
        my @messages;
        
        if ($username && $c->check_user_roles('admin')) {
            # Admins can see all messages
            @messages = $c->model('DB::ChatMessage')->search(
                { id => { '>' => $last_id } },
                { order_by => { -asc => 'id' } }
            )->all();
        } else {
            # Regular users only see their own messages and system responses
            @messages = $c->model('DB::ChatMessage')->search(
                {
                    id => { '>' => $last_id },
                    -or => [
                        { username => $username },
                        { is_system_message => 1 }
                    ]
                },
                { order_by => { -asc => 'id' } }
            )->all();
        }
        
        # Format messages for JSON response
        my @formatted_messages = map {
            {
                id => $_->id,
                username => $_->username,
                message => $_->message,
                timestamp => $_->timestamp,
                is_system_message => $_->is_system_message || 0,
            }
        } @messages;
        
        # Mark messages as read if user is admin
        if ($username && $c->check_user_roles('admin')) {
            $c->model('DB::ChatMessage')->search(
                { is_read => 0 }
            )->update({ is_read => 1 });
        }
        
        # Return messages
        $c->response->content_type('application/json');
        $c->response->body(encode_json({
            success => 1,
            messages => \@formatted_messages,
        }));
    } catch {
        # Log error
        $c->log->error("Chat: Error retrieving messages: $_");
        
        # Return error response
        $c->response->status(500);
        $c->response->body(encode_json({
            success => 0,
            error => 'Failed to retrieve messages'
        }));
    };
}

=head2 admin

Admin interface for chat management

=cut

sub admin :Path('admin') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is admin
    unless ($c->check_user_roles('admin')) {
        $c->response->redirect($c->uri_for('/'));
        return;
    }
    
    # Get all messages
    my @messages = $c->model('DB::ChatMessage')->search(
        {},
        { order_by => { -desc => 'timestamp' } }
    )->all();
    
    # Format messages for template
    my @formatted_messages = map {
        {
            id => $_->id,
            username => $_->username,
            message => $_->message,
            timestamp => $_->timestamp,
            is_read => $_->is_read,
            is_system_message => $_->is_system_message || 0,
            domain => $_->domain || 'Unknown',
            site_name => $_->site_name || 'Unknown',
        }
    } @messages;
    
    # Set template variables
    $c->stash->{messages} = \@formatted_messages;
    $c->stash->{template} = 'chat/admin.tt';
}

=head2 respond

API endpoint for admin to respond to a chat message

=cut

sub respond :Path('respond') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is admin
    unless ($c->check_user_roles('admin')) {
        $c->response->status(403);
        $c->response->body(encode_json({
            success => 0,
            error => 'Unauthorized'
        }));
        return;
    }
    
    # Get parameters
    my $message = $c->req->params->{message};
    my $to_username = $c->req->params->{to_username};
    
    # Validate parameters
    unless ($message && $to_username) {
        $c->response->status(400);
        $c->response->body(encode_json({
            success => 0,
            error => 'Message and recipient username are required'
        }));
        return;
    }
    
    try {
        # Store the response message
        my $chat_message = $c->model('DB::ChatMessage')->create({
            username => 'Admin',
            message => $message,
            timestamp => DateTime->now->iso8601,
            is_read => 0,
            is_system_message => 1,
            recipient_username => $to_username,
        });
        
        # Return success response
        $c->response->content_type('application/json');
        $c->response->body(encode_json({
            success => 1,
            message_id => $chat_message->id,
        }));
    } catch {
        # Log error
        $c->log->error("Chat: Error storing admin response: $_");
        
        # Return error response
        $c->response->status(500);
        $c->response->body(encode_json({
            success => 0,
            error => 'Failed to store response'
        }));
    };
}

__PACKAGE__->meta->make_immutable;

1;