package Comserv::Model::Schema::Ency::Result::Group;
use base 'DBIx::Class::Core';

__PACKAGE__->table('groups');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    name => {
        data_type => 'varchar',
        size => 255,
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->has_many(user_groups => 'Comserv::Model::Schema::Ency::Result::UserGroup', 'group_id');
__PACKAGE__->many_to_many(users => 'user_groups', 'user');

1;