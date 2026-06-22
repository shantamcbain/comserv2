package Comserv::Model::AI::Conversation;
use Moose;
use namespace::autoclean;
use Try::Tiny;
use JSON;
use Comserv::Util::Logging;

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

=head1 NAME

Comserv::Model::AI::Conversation - Persistence and retrieval of AI conversations and messages

=head1 DESCRIPTION

Handles AiConversation + AiMessage lifecycle:
- list conversations
- get messages
- persist new user+assistant turns (_persist_chat)
- delete conversations
- reset conversation state

This moves the giant conversation-related private methods out of the controller.

=cut

=head2 list

    my $convs = $conv->list($c, %filters);

Returns arrayref of conversation hashrefs for display or API.

=cut

sub list {
    my ($self, $c, %args) = @_;

    my $user_id         = $args{user_id}         // $c->session->{user_id} // 199;
    my $guest_session_id = $args{guest_session_id} // $c->session->{guest_session_id};
    my $view_all        = $args{view_all}        // 0;
    my $is_guest        = $args{is_guest}        // (!$c->session->{username});

    my @conversations;
    my $total = 0;

    try {
        my $schema = $c->model('DBEncy')->schema;
        my $search = $view_all ? {} : { user_id => $user_id };

        my $count_rs = $schema->resultset('AiConversation')->search($search);
        $total = $count_rs->count;

        my $rs = $schema->resultset('AiConversation')->search(
            $search,
            { order_by => { -desc => 'created_at' } }
        );

        for my $conv ($rs->all) {
            # Guest filtering
            if ($is_guest && $guest_session_id) {
                my $meta = {};
                eval { $meta = decode_json($conv->metadata || '{}'); };
                next unless ($meta->{guest_session_id} && $meta->{guest_session_id} eq $guest_session_id);
            }

            push @conversations, {
                id            => $conv->id,
                title         => $conv->get_display_title,
                model         => $conv->model,
                status        => $conv->status,
                project_id    => $conv->project_id,
                task_id       => $conv->task_id,
                created_at    => $conv->created_at . '',
                updated_at    => $conv->updated_at . '',
                message_count => $conv->ai_messages->count,
            };
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'list',
            "Failed to list conversations: $_");
    };

    return {
        conversations => \@conversations,
        total         => $total,
    };
}

=head2 get_messages

    my $data = $conv->get_messages($c, $conversation_id);

Returns { conversation => {...}, messages => [...] }

=cut

sub get_messages {
    my ($self, $c, $conversation_id) = @_;

    return { error => 'Conversation ID required' } unless $conversation_id;

    my $user_id          = $c->session->{user_id} // 199;
    my $guest_session_id = $c->session->{guest_session_id};
    my $is_guest         = !$c->session->{username};

    my $schema = eval { $c->model('DBEncy')->schema };
    return { error => 'Schema unavailable' } unless $schema;

    my $conv = $schema->resultset('AiConversation')->find($conversation_id);
    return { error => 'Conversation not found' } unless $conv;

    if ($conv->user_id != $user_id) {
        return { error => 'Access denied' };
    }

    if ($is_guest && $guest_session_id) {
        my $meta = {};
        eval { $meta = decode_json($conv->metadata || '{}'); };
        return { error => 'Access denied' }
            unless ($meta->{guest_session_id} && $meta->{guest_session_id} eq $guest_session_id);
    }

    my @messages;
    for my $msg ($conv->ai_messages->search({}, { order_by => { -asc => 'created_at' } })->all) {
        my $meta = {};
        eval { $meta = decode_json($msg->metadata || '{}'); };
        push @messages, {
            id             => $msg->id,
            role           => $msg->role,
            content        => $msg->content,
            agent_type     => $msg->agent_type || '',
            model_used     => $msg->model_used || '',
            created_at     => $msg->created_at . '',
            thinking_trace => $meta->{thinking_trace} || [],
        };
    }

    return {
        conversation => {
            id         => $conv->id,
            title      => $conv->get_display_title,
            created_at => $conv->created_at . '',
            model      => $conv->model,
        },
        messages => \@messages,
    };
}

=head2 persist

    my $conv_id = $conv->persist($c, %args);

Creates or updates a conversation and appends user + assistant messages.
This is the extracted version of the old _persist_chat.

Returns the conversation id or undef on failure.

=cut

sub persist {
    my ($self, $c, %args) = @_;

    my $username        = $args{username}        || '';
    my $conversation_id = $args{conversation_id} || undef;
    my $project_id      = $args{project_id}      || undef;
    my $task_id         = $args{task_id}         || undef;
    my $model           = $args{model}           || '';
    my $prompt          = $args{prompt}          || '';
    my $response        = $args{response}        || '';

    my $user_id = $c->session->{user_id};
    unless ($user_id) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'persist',
            "No user_id in session for user '$username', skipping DB persist");
        return undef;
    }

    my $schema = eval { $c->model('DBEncy')->schema };
    return undef unless $schema;

    my $conv;

    eval {
        if ($conversation_id) {
            $conv = $schema->resultset('AiConversation')->find({
                id      => $conversation_id,
                user_id => $user_id,
            });
        }

        unless ($conv) {
            my $title = length($prompt) > 80 ? substr($prompt, 0, 80) . '...' : $prompt;
            $conv = $schema->resultset('AiConversation')->create({
                user_id    => $user_id,
                title      => $title,
                project_id => $project_id,
                task_id    => $task_id,
                model      => $model,
                status     => 'active',
            });
        } else {
            $conv->update({
                model      => $model,
                project_id => $project_id // $conv->project_id,
                task_id    => $task_id    // $conv->task_id,
            });
        }

        $schema->resultset('AiMessage')->create({
            conversation_id => $conv->id,
            role            => 'user',
            content         => $prompt,
        });

        $schema->resultset('AiMessage')->create({
            conversation_id => $conv->id,
            role            => 'assistant',
            content         => $response,
            metadata        => encode_json({ model => $model }),
        });
    };

    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'persist',
            "Failed to persist chat for user '$username': $@");
        return undef;
    }

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'persist',
        "Persisted chat to conversation " . $conv->id . " for user '$username'");

    return $conv->id;
}

=head2 delete

    $conv->delete($c, $conversation_id);

Deletes a conversation (and its messages via FK cascade or explicit delete).

=cut

sub delete {
    my ($self, $c, $conversation_id) = @_;

    my $user_id = $c->session->{user_id} // 199;
    return 0 unless $conversation_id;

    my $schema = eval { $c->model('DBEncy')->schema };
    return 0 unless $schema;

    eval {
        my $conv = $schema->resultset('AiConversation')->find({
            id      => $conversation_id,
            user_id => $user_id,
        });
        $conv->delete if $conv;
    };

    return 1;
}

=head2 reset

Placeholder for future "clear history but keep conversation" logic.
Currently just returns success.

=cut

sub reset {
    my ($self, $c, $conversation_id) = @_;
    # For now we do nothing special; clients usually just start a new conv.
    return 1;
}

1;

__PACKAGE__->meta->make_immutable;