package Comserv::Model::Schema::Ency::Result::Ency::FormulaDisease;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('formula_disease');
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
    disease_id => {
        data_type   => 'int',
        is_nullable => 1,
    },
    condition_name => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    formula => 'Comserv::Model::Schema::Ency::Result::Ency::Formula',
    'formula_id',
    { is_foreign_key_constraint => 0 },
);

__PACKAGE__->belongs_to(
    disease => 'Comserv::Model::Schema::Ency::Result::Ency::Disease',
    'disease_id',
    { is_foreign_key_constraint => 0, join_type => 'LEFT' },
);

1;
