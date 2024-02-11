package Comserv::Model::Schema::Ency::Result::UserGroup;
use base 'DBIx::Class::Core';

__PACKAGE__->table('user_groups');
__PACKAGE__->add_columns(
    user_id => {
        data_type => 'integer',
    },
    group_id => {
        data_type => 'integer',
    },
);
__PACKAGE__->set_primary_key('user_id', 'group_id');
__PACKAGE__->belongs_to(user => 'Comserv::Model::Schema::Ency::Result::User', 'user_id');
__PACKAGE__->belongs_to(group => 'Comserv::Model::Schema::Ency::Result::Group', 'group_id');

1;