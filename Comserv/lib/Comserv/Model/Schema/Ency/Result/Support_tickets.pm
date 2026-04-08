package Comserv::Model::Schema::Ency::Result::Support_tickets;
use base 'DBIx::Class::Core';

__PACKAGE__->table('support_tickets');
__PACKAGE__->add_columns(
    assigned_to => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    category => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
        default_value => 'other',
    },
    closed_at => {
        data_type => 'datetime',
        is_nullable => 1,
    },
    conversation_id => {
        data_type => 'int',
        size => 11,
        is_nullable => 1,
    },
    created_at => {
        data_type => 'datetime',
    },
    description => {
        data_type => 'text',
    },
    email => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
    metadata => {
        data_type => 'text',
        is_nullable => 1,
    },
    priority => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 1,
        default_value => 'medium',
    },
    resolution => {
        data_type => 'text',
        is_nullable => 1,
    },
    site_name => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    status => {
        data_type => 'varchar',
        size => 50,
        default_value => 'open',
    },
    subject => {
        data_type => 'text',
    },
    ticket_number => {
        data_type => 'varchar',
        size => 50,
    },
    updated_at => {
        data_type => 'datetime',
        is_nullable => 1,
    },
    user_id => {
        data_type => 'int',
        size => 11,
        is_nullable => 1,
    },
    username => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('id');

1;
