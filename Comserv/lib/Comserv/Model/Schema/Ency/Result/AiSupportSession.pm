package Comserv::Model::Schema::Ency::Result::AiSupportSession;
use base 'DBIx::Class::Core';
__PACKAGE__->load_components("InflateColumn::DateTime");
use warnings FATAL => 'all';

__PACKAGE__->table('ai_support_sessions');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    user_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    admin_user_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    conversation_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 0,
    },
    status => {
        data_type     => 'enum',
        extra         => { list => ['pending', 'accepted', 'active', 'closed', 'cancelled'] },
        default_value => 'pending',
        is_nullable   => 0,
    },
    subject => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    user_description => {
        data_type   => 'text',
        is_nullable => 1,
    },
    page_url => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    closed_at => {
        data_type   => 'timestamp',
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable   => 0,
    },
    updated_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
        is_nullable   => 0,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'user' => 'Comserv::Model::Schema::Ency::Result::User',
    { 'foreign.id' => 'self.user_id' }
);

__PACKAGE__->belongs_to(
    'admin_user' => 'Comserv::Model::Schema::Ency::Result::User',
    { 'foreign.id' => 'self.admin_user_id' },
    { join_type => 'left' }
);

__PACKAGE__->belongs_to(
    'conversation' => 'Comserv::Model::Schema::Ency::Result::AiConversation',
    { 'foreign.id' => 'self.conversation_id' },
    { join_type => 'left' }
);

__PACKAGE__->has_many(
    'support_messages' => 'Comserv::Model::Schema::Ency::Result::AiSupportMessage',
    { 'foreign.session_id' => 'self.id' },
    { cascade_delete => 1 }
);

sub is_active {
    my $self = shift;
    return $self->status eq 'active' || $self->status eq 'accepted';
}

1;
