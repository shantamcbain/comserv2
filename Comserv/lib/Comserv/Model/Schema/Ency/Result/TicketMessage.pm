package Comserv::Model::Schema::Ency::Result::TicketMessage;
use base 'DBIx::Class::Core';

__PACKAGE__->table('ticket_messages');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    ticket_id => {
        data_type   => 'int',
        is_nullable => 0,
    },
    sender_type => {
        data_type     => 'varchar',
        size          => 20,
        is_nullable   => 0,
        default_value => 'user',
    },
    sender_name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    sender_email => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    body => {
        data_type   => 'text',
        is_nullable => 0,
    },
    created_at => {
        data_type     => 'datetime',
        is_nullable   => 0,
        set_on_create => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    ticket => 'Comserv::Model::Schema::Ency::Result::SupportTicket',
    'ticket_id',
    { join_type => 'LEFT' }
);

1;
