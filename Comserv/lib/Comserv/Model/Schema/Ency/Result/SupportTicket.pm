package Comserv::Model::Schema::Ency::Result::SupportTicket;
use base 'DBIx::Class::Core';

__PACKAGE__->table('support_tickets');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    ticket_number => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 0,
    },
    site_name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    user_id => {
        data_type   => 'int',
        is_nullable => 1,
    },
    username => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    email => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    subject => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 0,
    },
    description => {
        data_type   => 'text',
        is_nullable => 0,
    },
    category => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
        default_value => 'other',
    },
    priority => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
        default_value => 'medium',
    },
    status => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 0,
        default_value => 'open',
    },
    assigned_to => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    resolution => {
        data_type   => 'text',
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'datetime',
        is_nullable   => 0,
        set_on_create => 1,
    },
    updated_at => {
        data_type     => 'datetime',
        is_nullable   => 1,
        set_on_create => 1,
        set_on_update => 1,
    },
    closed_at => {
        data_type   => 'datetime',
        is_nullable => 1,
    },
    conversation_id => {
        data_type   => 'int',
        is_nullable => 1,
    },
    metadata => {
        data_type   => 'text',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    conversation => 'Comserv::Model::Schema::Ency::Result::AiConversation',
    'conversation_id',
    { join_type => 'LEFT' }
);

1;
