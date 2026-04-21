package Comserv::Model::Schema::Ency::Result::Ticket_messages;
use base 'DBIx::Class::Core';

__PACKAGE__->table('ticket_messages');
__PACKAGE__->add_columns(
    body => {
        data_type => 'text',
    },
    created_at => {
        data_type => 'datetime',
    },
    id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
    sender_email => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    sender_name => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    sender_type => {
        data_type => 'varchar',
        size => 20,
        default_value => 'user',
    },
    ticket_id => {
        data_type => 'int',
        size => 11,
    },
);
__PACKAGE__->set_primary_key('id');

1;
