package Comserv::Model::Schema::Forager::Result::ConstituentSymptom;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('constituent_symptom');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    constituent_id => {
        data_type   => 'int',
        is_nullable => 0,
    },
    symptom_id => {
        data_type   => 'int',
        is_nullable => 0,
    },
    relationship_type => {
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
__PACKAGE__->add_unique_constraint(['constituent_id', 'symptom_id', 'relationship_type']);

__PACKAGE__->belongs_to(
    constituent => 'Comserv::Model::Schema::Ency::Result::Constituent',
    'constituent_id',
    { is_foreign_key_constraint => 0 },
);

__PACKAGE__->belongs_to(
    symptom => 'Comserv::Model::Schema::Ency::Result::Symptom',
    'symptom_id',
    { is_foreign_key_constraint => 0 },
);

1;
