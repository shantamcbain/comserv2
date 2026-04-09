package Comserv::Model::Schema::Ency::Result::Category;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('categories');
__PACKAGE__->add_columns(
    category_id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    category => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    description => {
        data_type   => 'text',
        is_nullable => 1,
    },
    parent_category_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    entity_type => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('category_id');

__PACKAGE__->belongs_to(
    parent_category => 'Comserv::Model::Schema::Ency::Result::Category',
    'parent_category_id',
);

__PACKAGE__->has_many(
    sub_categories => 'Comserv::Model::Schema::Ency::Result::Category',
    'parent_category_id',
);

1;
