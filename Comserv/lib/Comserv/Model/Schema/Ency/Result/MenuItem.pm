package Comserv::Model::Schema::Ency::Result::MenuItem;
use base 'DBIx::Class::Core';

__PACKAGE__->table('menu_items');
__PACKAGE__->add_columns(
    'id' => {
        data_type => 'integer',
        is_auto_increment => 1,
        is_nullable => 0,
    },
    'menu_id' => {
        data_type => 'integer',
        is_nullable => 0,
    },
    'title' => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    'url' => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    'page_id' => {
        data_type => 'integer',
        is_nullable => 1,
    },
    'parent_id' => {
        data_type => 'integer',
        is_nullable => 1,
    },
    'order' => {
        data_type => 'integer',
        default_value => 0,
    },
    'created_at' => {
        data_type => 'datetime',
        set_on_create => 1,
    },
    'updated_at' => {
        data_type => 'datetime',
        set_on_create => 1,
        set_on_update => 1,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->belongs_to('menu' => 'Comserv::Model::Schema::Ency::Result::Menu', 'menu_id');
__PACKAGE__->belongs_to('page' => 'Comserv::Model::Schema::Ency::Result::Page', 'page_id');
__PACKAGE__->belongs_to('parent' => 'Comserv::Model::Schema::Ency::Result::MenuItem', 'parent_id');
__PACKAGE__->has_many('children' => 'Comserv::Model::Schema::Ency::Result::MenuItem', 'parent_id');

1;
