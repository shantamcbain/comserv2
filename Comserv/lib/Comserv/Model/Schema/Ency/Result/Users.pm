package Comserv::Model::Schema::Ency::Result::Users;
use base 'DBIx::Class::Core';

__PACKAGE__->table('users');
__PACKAGE__->add_columns(
    email => {
        data_type => 'varchar',
        size => 255,
    },
    first_name => {
        data_type => 'varchar',
        size => 255,
    },
    id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
    last_name => {
        data_type => 'varchar',
        size => 255,
    },
    password => {
        data_type => 'varchar',
        size => 255,
    },
    roles => {
        data_type => 'text',
    },
    username => {
        data_type => 'varchar',
        size => 255,
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('username_unique' => ['username']);

1;
