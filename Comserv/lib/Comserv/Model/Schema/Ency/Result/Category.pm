# In Comserv/lib/Comserv/Model/Schema/Ency/Result/Category.pm
package Comserv::Model::Schema::Ency::Result::Category;
use base 'DBIx::Class::Core';

__PACKAGE__->table('categories');
__PACKAGE__->add_columns(
     category_id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    category => {
        data_type => 'varchar',
        size => 255,
    },
);
__PACKAGE__->set_primary_key('category_id');

1;