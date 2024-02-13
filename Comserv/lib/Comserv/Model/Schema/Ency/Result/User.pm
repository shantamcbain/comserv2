package Comserv::Model::Schema::Ency::Result::User;
use base 'DBIx::Class::Core';

__PACKAGE__->table('users');
__PACKAGE__->add_columns(
    id => {
        data_type => 'int',
        is_auto_increment => 1,
    },
    username => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    password => {
        data_type => 'varchar',
        size => 255,
    },
    first_name => {
        data_type => 'varchar',
        size => 255,
    },
    last_name => {
        data_type => 'varchar',
        size => 255,
    },
    email => {
        data_type => 'varchar',
        size => 255,
    },
    roles => {
        data_type => 'text',
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('username_unique' => ['username']);

1;