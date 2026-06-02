package Comserv::Model::Schema::Ency::Result::Session;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

__PACKAGE__->table('sessions');
__PACKAGE__->add_columns(
    id => {
        data_type => 'varchar',
        size      => 72,
    },
    session_data => {
        data_type   => 'text',
        is_nullable => 1,
    },
    expires => {
        data_type   => 'integer',
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('id');

1;
