package Comserv::Controller::Chat;
use Moose;
use namespace::autoclean;
use JSON;
use DateTime;
use Try::Tiny;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    lazy => 1,
    default => sub { Comserv::Util::Logging->instance },
    documentation => 'Logging instance for standardized logging'
);

=head1 NAME

Comserv::Controller::Chat - Chat Controller for Comserv

=head1 DESCRIPTION

Controller for handling chat functionality.

=head1 METHODS

=cut

=head2 index

Chat home page - displays main chat interface

=cut

sub index :Path :Args(0) {
    my ($self, $c) = @_;
    
    my $user_id = $c->session->{user_id} || 199;
    my $username = $c->session->{username} || 'Guest';
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
        "User accessing chat interface - user_id=$user_id, username=$username");
    
    # Set the template
    $c->stash->{template} = 'chat/index.tt';
    $c->stash->{user_id} = $user_id;
    $c->stash->{username} = $username;
}

=head2 send_message

API endpoint to send a chat message

=cut

sub send_message :Path('send_message') :Args(0) {
    my ($self, $c) = @_;
    
    # Get request parameters
    my $message = $c->req->params->{message};
    my $user_id = $c->session->{user_id} || 199;  # 199 = guest user
    my $username = $c->session->{username} || 'Guest';
    my $domain = $c->req->uri->host || 'unknown';
    my $site_name = $c->session->{SiteName} || 'unknown';
    my $conversation_id = $c->req->params->{conversation_id};
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'send_message',
        "Processing message from user_id=$user_id (username=$username) on domain=$domain");
    
    # Validate message
    unless ($message && length($message) > 0) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'send_message',
            "Empty message received from user_id=$user_id");
        $c->response->status(400);
        $c->response->body(encode_json({
            success => 0,
            error => 'Message cannot be empty'
        }));
        return;
    }
    
    try {
        my $schema = $c->model('DBEncy')->schema;
        
        # Create conversation if needed
        unless ($conversation_id) {
            my $conv_metadata = {
                domain => $domain,
                site_name => $site_name,
                created_from_chat_widget => 1,
                user_agent => $c->req->user_agent || 'unknown',
                ip_address => $c->req->address || 'unknown'
            };
            
            my $conversation = $schema->resultset('AiConversation')->create({
                user_id => $user_id,
                title => 'Chat Conversation',
                status => 'active',
                metadata => encode_json($conv_metadata)
            });
            
            $conversation_id = $conversation->id;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_message',
                "Created new conversation_id=$conversation_id for user_id=$user_id");
        }
        
        # Store user message
        my $msg_metadata = {
            domain => $domain,
            site_name => $site_name,
            username => $username,
            user_role => $c->session->{roles} || 'user'
        };
        
        my $ai_message = $schema->resultset('AiMessage')->create({
            conversation_id => $conversation_id,
            user_id => $user_id,
            role => 'user',
            content => $message,
            metadata => encode_json($msg_metadata),
            agent_type => 'chat',
            user_role => $c->session->{roles} || 'user'
        });
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_message',
            "Message stored - message_id=" . $ai_message->id . ", conversation_id=$conversation_id, user_id=$user_id");
        
        # Return success response
        $c->response->content_type('application/json');
        $c->response->body(encode_json({
            success => 1,
            message_id => $ai_message->id,
            conversation_id => $conversation_id,
            timestamp => $ai_message->created_at->iso8601
        }));
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'send_message',
            "Error storing message: $_");
        
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
    
    my $user_id = $c->session->{user_id} || 199;
    my $username = $c->session->{username} || 'Guest';
    my $last_id = $c->req->params->{last_id} || 0;
    my $conversation_id = $c->req->params->{conversation_id};
    my $is_admin = $c->check_user_roles('admin');
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'get_messages',
        "Retrieving messages - user_id=$user_id, conversation_id=$conversation_id, last_id=$last_id, is_admin=$is_admin");
    
    try {
        my $schema = $c->model('DBEncy')->schema;
        my @messages;
        
        # Build search criteria
        my %search_params = (
            id => { '>' => $last_id }
        );
        $search_params{conversation_id} = $conversation_id if $conversation_id;
        
        # Admin sees all messages in conversation; users see only their own
        if ($is_admin) {
            @messages = $schema->resultset('AiMessage')->search(
                \%search_params,
                { order_by => { -asc => 'id' } }
            )->all();
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'get_messages',
                "Admin retrieving messages - found " . scalar(@messages) . " messages");
        } else {
            $search_params{user_id} = $user_id;
            @messages = $schema->resultset('AiMessage')->search(
                \%search_params,
                { order_by => { -asc => 'id' } }
            )->all();
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'get_messages',
                "User $username retrieving own messages - found " . scalar(@messages) . " messages");
        }
        
        # Format messages for JSON response
        my @formatted_messages = map {
            my $metadata = {};
            if ($_->metadata) {
                eval { $metadata = decode_json($_->metadata); };
            }
            {
                id => $_->id,
                conversation_id => $_->conversation_id,
                user_id => $_->user_id,
                role => $_->role,
                content => $_->content,
                timestamp => $_->created_at->iso8601,
                agent_type => $_->agent_type || 'chat',
                metadata => $metadata
            }
        } @messages;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_messages',
            "Returning " . scalar(@formatted_messages) . " formatted messages");
        
        # Return messages
        $c->response->content_type('application/json');
        $c->response->body(encode_json({
            success => 1,
            messages => \@formatted_messages,
            count => scalar(@formatted_messages)
        }));
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_messages',
            "Error retrieving messages: $_");
        
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
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin',
        "Admin accessing chat management interface");
    
    # Check if user is admin
    unless ($c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'admin',
            "Non-admin user attempted to access chat admin - user_id=" . ($c->session->{user_id} || 'unknown'));
        $c->response->redirect($c->uri_for('/'));
        return;
    }
    
    try {
        my $schema = $c->model('DBEncy')->schema;
        
        # Get all conversations with agent_type='chat'
        my @conversations = $schema->resultset('AiConversation')->search(
            { 'ai_messages.agent_type' => 'chat' },
            {
                join => 'ai_messages',
                distinct => 1,
                order_by => { -desc => 'created_at' }
            }
        )->all();
        
        # Format for template - show conversations with messages
        my @formatted_conversations;
        foreach my $conv (@conversations) {
            my @conv_messages = $conv->ai_messages->search(
                { agent_type => 'chat' },
                { order_by => { -asc => 'created_at' } }
            )->all();
            
            if (@conv_messages) {
                push @formatted_conversations, {
                    conversation_id => $conv->id,
                    user_id => $conv->user_id,
                    title => $conv->title,
                    created_at => $conv->created_at->iso8601,
                    message_count => scalar(@conv_messages),
                    messages => [map {
                        my $metadata = {};
                        if ($_->metadata) {
                            eval { $metadata = decode_json($_->metadata); };
                        }
                        {
                            id => $_->id,
                            role => $_->role,
                            content => $_->content,
                            timestamp => $_->created_at->iso8601,
                            user_role => $_->user_role,
                            metadata => $metadata
                        }
                    } @conv_messages]
                };
            }
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin',
            "Admin loaded " . scalar(@formatted_conversations) . " chat conversations");
        
        # Set template variables
        $c->stash->{conversations} = \@formatted_conversations;
        $c->stash->{template} = 'chat/admin.tt';
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'admin',
            "Error loading chat conversations: $_");
        
        $c->response->status(500);
        $c->stash->{error} = 'Failed to load chat conversations';
        $c->stash->{template} = 'error.tt';
    };
}

=head2 respond

API endpoint for admin to respond to a chat message

=cut

sub respond :Path('respond') :Args(0) {
    my ($self, $c) = @_;
    
    my $admin_user_id = $c->session->{user_id};
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'respond',
        "Admin respond request from user_id=$admin_user_id");
    
    # Check if user is admin
    unless ($c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'respond',
            "Non-admin user attempted to send admin response - user_id=$admin_user_id");
        $c->response->status(403);
        $c->response->body(encode_json({
            success => 0,
            error => 'Unauthorized'
        }));
        return;
    }
    
    # Get parameters
    my $message = $c->req->params->{message};
    my $conversation_id = $c->req->params->{conversation_id};
    
    # Validate parameters
    unless ($message && $conversation_id) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'respond',
            "Missing required parameters - message=" . (defined $message ? 'yes' : 'no') . ", conversation_id=$conversation_id");
        $c->response->status(400);
        $c->response->body(encode_json({
            success => 0,
            error => 'Message and conversation_id are required'
        }));
        return;
    }
    
    try {
        my $schema = $c->model('DBEncy')->schema;
        
        # Get conversation to verify it exists
        my $conversation = $schema->resultset('AiConversation')->find($conversation_id);
        unless ($conversation) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'respond',
                "Conversation not found - conversation_id=$conversation_id");
            $c->response->status(404);
            $c->response->body(encode_json({
                success => 0,
                error => 'Conversation not found'
            }));
            return;
        }
        
        # Store admin response message
        my $msg_metadata = {
            admin_response => 1,
            admin_user_id => $admin_user_id,
            responded_at => DateTime->now->iso8601
        };
        
        my $response_msg = $schema->resultset('AiMessage')->create({
            conversation_id => $conversation_id,
            user_id => $admin_user_id,
            role => 'assistant',
            content => $message,
            metadata => encode_json($msg_metadata),
            agent_type => 'chat',
            user_role => 'admin'
        });
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'respond',
            "Admin response stored - message_id=" . $response_msg->id . ", conversation_id=$conversation_id, admin_id=$admin_user_id");
        
        # Return success response
        $c->response->content_type('application/json');
        $c->response->body(encode_json({
            success => 1,
            message_id => $response_msg->id,
            timestamp => $response_msg->created_at->iso8601
        }));
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'respond',
            "Error storing admin response: $_");
        
        $c->response->status(500);
        $c->response->body(encode_json({
            success => 0,
            error => 'Failed to store response'
        }));
    };
}

__PACKAGE__->meta->make_immutable;

1;