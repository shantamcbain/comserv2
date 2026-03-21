package Comserv::Model::Schema::Ency::Result::Category;
use base 'DBIx::Class::Core';

__PACKAGE__->table('categories');
__PACKAGE__->add_columns(
category_id => { data_type => 'INT', size => 11, is_nullable => 0 },
    category => {
        data_type => 'varchar',
        size => 255,
    },
);
__PACKAGE__->set_primary_key('category_id');

1;