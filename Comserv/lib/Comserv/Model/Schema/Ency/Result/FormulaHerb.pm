package Comserv::Model::Schema::Ency::Result::FormulaHerb;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('formula_herb');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    formula_id => {
        data_type   => 'int',
        is_nullable => 0,
    },
    herb_id => {
        data_type   => 'int',
        is_nullable => 1,
    },
    herb_name_raw => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    botanical_name_raw => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    quantity => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    plant_part => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    formula => 'Comserv::Model::Schema::Ency::Result::Formula',
    'formula_id',
    { is_foreign_key_constraint => 0 },
);

__PACKAGE__->belongs_to(
    herb => 'Comserv::Model::Schema::Forager::Result::Herb',
    'herb_id',
    { is_foreign_key_constraint => 0, join_type => 'LEFT' },
);

1;
