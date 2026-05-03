package Comserv::Model::Schema::Ency::Result::Ency::InsectHerb;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('insect_herb');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    insect_id => {
        data_type   => 'int',
        is_nullable => 0,
    },
    herb_id => {
        data_type   => 'int',
        is_nullable => 0,
    },
    interaction_type => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['insect_id', 'herb_id', 'interaction_type']);

__PACKAGE__->belongs_to(
    insect => 'Comserv::Model::Schema::Ency::Result::Ency::Insect',
    'insect_id',
    { is_foreign_key_constraint => 0 },
);

__PACKAGE__->belongs_to(
    herb => 'Comserv::Model::Schema::Forager::Result::Herb',
    'herb_id',
    { is_foreign_key_constraint => 0 },
);

1;
