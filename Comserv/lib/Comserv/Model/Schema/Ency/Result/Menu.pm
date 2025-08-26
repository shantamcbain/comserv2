package Comserv::Model::Schema::Ency::Result::Menu;
use base 'DBIx::Class::Core';

__PACKAGE__->table('menus');
__PACKAGE__->add_columns(
    'id' => {
        data_type => 'integer',
        is_auto_increment => 1,
        is_nullable => 0,
    },
    'name' => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    'description' => {
        data_type => 'text',
        is_nullable => 1,
    },
    'site_id' => {
        data_type => 'integer',
        is_nullable => 0,
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
__PACKAGE__->belongs_to('site' => 'Comserv::Model::Schema::Ency::Result::Site', 'site_id');
__PACKAGE__->has_many('menu_items' => 'Comserv::Model::Schema::Ency::Result::MenuItem', 'menu_id');

1;
