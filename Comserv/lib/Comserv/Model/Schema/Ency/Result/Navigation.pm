package Comserv::Model::Schema::Ency::Result::Navigation;

use base 'DBIx::Class::Core';

__PACKAGE__->table('navigation');

__PACKAGE__->add_columns(
    'id' => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    'page_id' => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    'menu' => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    'parent_id' => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    'order' => {
        data_type   => 'integer',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'page',
    'Comserv::Model::Schema::Ency::Result::Page',
    { 'foreign.id' => 'self.page_id' },
    { is_deferrable => 1, on_delete => 'CASCADE', on_update => 'CASCADE' }
);

__PACKAGE__->belongs_to(
    'parent',
    'Comserv::Model::Schema::Ency::Result::Navigation',
    { 'foreign.id' => 'self.parent_id' },
    { join_type => 'LEFT' }
);

1;