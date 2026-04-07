package Comserv::Model::Schema::Ency::Result::AiSupportMessage;
use base 'DBIx::Class::Core';
__PACKAGE__->load_components("InflateColumn::DateTime");
use warnings FATAL => 'all';

__PACKAGE__->table('ai_support_messages');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    session_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    sender_user_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    sender_role => {
        data_type   => 'enum',
        extra       => { list => ['user', 'admin', 'ai'] },
        is_nullable => 0,
    },
    content => {
        data_type   => 'text',
        is_nullable => 0,
    },
    created_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable   => 0,
    },
    read_at => {
        data_type   => 'timestamp',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'session' => 'Comserv::Model::Schema::Ency::Result::AiSupportSession',
    { 'foreign.id' => 'self.session_id' }
);

__PACKAGE__->belongs_to(
    'sender' => 'Comserv::Model::Schema::Ency::Result::User',
    { 'foreign.id' => 'self.sender_user_id' }
);

sub is_from_admin {
    my $self = shift;
    return $self->sender_role eq 'admin';
}

sub is_from_ai {
    my $self = shift;
    return $self->sender_role eq 'ai';
}

1;
