package Comserv::Model::Schema::Ency::Result::Event;
use base 'DBIx::Class::Core';

__PACKAGE__->table('event');
__PACKAGE__->add_columns(
    event_id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    event_name => {
        data_type => 'varchar',
        size => 255,
    },
    start_date => {
        data_type => 'date',
    },
    end_date => {
        data_type => 'date',
    },
    description => {
        data_type => 'text',
    },
    location => {
        data_type => 'varchar',
        size => 255,
    },
    "organizer",
    { data_type => "varchar", default_value => "", is_nullable => 1, size => 50 },
    "attendees",
    { data_type => "text", is_nullable => 1 },
    status => {
        data_type => 'varchar',
        size => 255,
    },
    "last_modified_by",
    { data_type => "varchar", default_value => "", is_nullable => 1, size => 50 },
    last_mod_date => {
        data_type => 'date',
    },
    user_id => {
        data_type => 'integer',
    },
);

__PACKAGE__->set_primary_key('event_id');
__PACKAGE__->belongs_to(user => 'Comserv::Model::Schema::Ency::Result::User', 'user_id');

1;