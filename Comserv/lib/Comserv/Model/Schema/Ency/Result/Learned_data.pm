package Comserv::Model::Schema::Ency::Result::Learned_data;
use base 'DBIx::Class::Core';

__PACKAGE__->table('learned_data');
__PACKAGE__->add_columns(
file => {
        data_type => 'varchar',
        size => 1024,
        is_nullable => 1,
    },
    frequency => {
        data_type => 'int',
        size => 11,
        is_nullable => 1,
    },
    id => { data_type => 'INT', size => 11, is_nullable => 0 },
    word => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('id');

1;
