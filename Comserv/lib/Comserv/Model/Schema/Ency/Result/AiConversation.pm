package Comserv::Model::Schema::Ency::Result::AiConversation;
use base 'DBIx::Class::Core';
__PACKAGE__->load_components("InflateColumn::DateTime");
use warnings FATAL => 'all';

__PACKAGE__->table('ai_conversations');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    user_id => {
        data_type => 'integer',
        is_nullable => 0,
    },
    title => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    project_id => {
        data_type => 'integer',
        is_nullable => 1,
    },
    task_id => {
        data_type => 'integer',
        is_nullable => 1,
    },
    model => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    created_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable => 0,
    },
    updated_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
        is_nullable => 0,
    },
    status => {
        data_type => 'enum',
        extra => { list => ['active', 'archived'] },
        default_value => 'active',
        is_nullable => 0,
    },
    metadata => {
        data_type   => 'longtext',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

# Relationships
__PACKAGE__->belongs_to(
    'user' => 'Comserv::Model::Schema::Ency::Result::User',
    { 'foreign.id' => 'self.user_id' }
);

__PACKAGE__->belongs_to(
    'project' => 'Comserv::Model::Schema::Ency::Result::Project',
    { 'foreign.id' => 'self.project_id' },
    { join_type => 'LEFT', is_foreign_key_constraint => 0 }
);

__PACKAGE__->belongs_to(
    'task' => 'Comserv::Model::Schema::Ency::Result::Todo',
    { 'foreign.record_id' => 'self.task_id' },
    { join_type => 'LEFT', is_foreign_key_constraint => 0 }
);

__PACKAGE__->has_many(
    'ai_messages' => 'Comserv::Model::Schema::Ency::Result::AiMessage',
    { 'foreign.conversation_id' => 'self.id' },
    { cascade_delete => 1 }
);

# Helper methods
sub get_display_title {
    my $self = shift;
    return $self->title || 'New Conversation';
}

sub get_message_count {
    my $self = shift;
    return $self->ai_messages->count;
}

sub get_latest_message {
    my $self = shift;
    return $self->ai_messages->search(
        {},
        { 
            order_by => { -desc => 'created_at' },
            rows => 1
        }
    )->first;
}

1;