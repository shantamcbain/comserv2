package Comserv::Model::Schema::Ency::Result::Ency::DiseaseSymptom;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('disease_symptom');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    disease_id => {
        data_type   => 'int',
        is_nullable => 0,
    },
    symptom_id => {
        data_type   => 'int',
        is_nullable => 0,
    },
    frequency => {
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
__PACKAGE__->add_unique_constraint(['disease_id', 'symptom_id']);

__PACKAGE__->belongs_to(
    disease => 'Comserv::Model::Schema::Ency::Result::Ency::Disease',
    'disease_id',
    { is_foreign_key_constraint => 0 },
);

__PACKAGE__->belongs_to(
    symptom => 'Comserv::Model::Schema::Ency::Result::Ency::Symptom',
    'symptom_id',
    { is_foreign_key_constraint => 0 },
);

1;
