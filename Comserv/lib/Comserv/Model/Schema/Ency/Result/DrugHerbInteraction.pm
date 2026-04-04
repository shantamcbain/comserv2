package Comserv::Model::Schema::Ency::Result::DrugHerbInteraction;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('drug_herb_interaction');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    drug_id => {
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
    severity => {
        data_type   => 'varchar',
        size        => 30,
        is_nullable => 1,
    },
    mechanism => {
        data_type   => 'text',
        is_nullable => 1,
    },
    clinical_significance => {
        data_type   => 'text',
        is_nullable => 1,
    },
    management => {
        data_type   => 'text',
        is_nullable => 1,
    },
    evidence_level => {
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
__PACKAGE__->add_unique_constraint(['drug_id', 'herb_id', 'interaction_type']);

__PACKAGE__->belongs_to(
    drug => 'Comserv::Model::Schema::Ency::Result::Drug',
    'drug_id',
    { is_foreign_key_constraint => 0 },
);

__PACKAGE__->belongs_to(
    herb => 'Comserv::Model::Schema::Forager::Result::Herb',
    'herb_id',
    { is_foreign_key_constraint => 0 },
);

1;
