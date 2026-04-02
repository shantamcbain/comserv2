package Comserv::Model::Schema::Forager::Result::HerbCategory;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('herb_category');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    herb_id => {
        data_type   => 'int',
        is_nullable => 0,
    },
    category_id => {
        data_type   => 'int',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['herb_id', 'category_id']);

__PACKAGE__->belongs_to(
    herb => 'Comserv::Model::Schema::Forager::Result::Herb',
    'herb_id',
    { is_foreign_key_constraint => 0 },
);

__PACKAGE__->belongs_to(
    category => 'Comserv::Model::Schema::Ency::Result::Category',
    'category_id',
    { is_foreign_key_constraint => 0 },
);

1;
