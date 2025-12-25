package Comserv::Model::Schema::Ency::Result::AiMessage;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

__PACKAGE__->table('ai_messages');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    conversation_id => {
        data_type => 'integer',
        is_nullable => 0,
    },
    user_id => {
        data_type => 'integer',
        is_nullable => 1,
    },
    role => {
        data_type => 'enum',
        extra => { list => ['user', 'assistant'] },
        is_nullable => 0,
    },
    content => {
        data_type => 'text',
        is_nullable => 0,
    },
    created_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable => 0,
    },
    metadata => {
        data_type => 'json',
        is_nullable => 1,
    },
    agent_type => {
        data_type => 'enum',
        extra => { list => ['documentation', 'helpdesk', 'ency', 'beekeeping', 'hamradio'] },
        default_value => 'documentation',
        is_nullable => 1,
    },
    model_used => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    search_context => {
        data_type => 'json',
        is_nullable => 1,
    },
    sources_cited => {
        data_type => 'json',
        is_nullable => 1,
    },
    user_role => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    response_time_ms => {
        data_type => 'integer',
        is_nullable => 1,
    },
    tokens_used => {
        data_type => 'integer',
        is_nullable => 1,
    },
    is_verified => {
        data_type => 'boolean',
        default_value => 0,
        is_nullable => 0,
    },
    ip_address => {
        data_type => 'varchar',
        size => 45,
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

# Relationships
__PACKAGE__->belongs_to(
    'conversation' => 'Comserv::Model::Schema::Ency::Result::AiConversation',
    { 'foreign.id' => 'self.conversation_id' }
);

__PACKAGE__->belongs_to(
    'user' => 'Comserv::Model::Schema::Ency::Result::User',
    { 'foreign.id' => 'self.user_id' },
    { join_type => 'left' }
);

# Helper methods
sub is_user_message {
    my $self = shift;
    return $self->role eq 'user';
}

sub is_assistant_message {
    my $self = shift;
    return $self->role eq 'assistant';
}

sub get_formatted_time {
    my $self = shift;
    my $dt = $self->created_at;
    return $dt->strftime('%Y-%m-%d %H:%M:%S') if ref $dt;
    return $dt;
}

sub get_content_preview {
    my ($self, $length) = @_;
    $length ||= 100;
    my $content = $self->content;
    return length($content) > $length 
        ? substr($content, 0, $length) . '...'
        : $content;
}

sub get_sources {
    my $self = shift;
    my $sources = $self->sources_cited;
    return $sources ? (ref $sources eq 'ARRAY' ? $sources : [$sources]) : [];
}

sub get_search_info {
    my $self = shift;
    my $context = $self->search_context;
    return $context ? (ref $context eq 'HASH' ? $context : {}) : {};
}

1;