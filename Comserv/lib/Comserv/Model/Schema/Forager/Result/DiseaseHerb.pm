package Comserv::Model::Schema::Forager::Result::DiseaseHerb;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('disease_herb');
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
    herb_id => {
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
__PACKAGE__->add_unique_constraint(['disease_id', 'herb_id']);

__PACKAGE__->belongs_to(
    disease => 'Comserv::Model::Schema::Ency::Result::Disease',
    'disease_id',
    { is_foreign_key_constraint => 0 },
);

__PACKAGE__->belongs_to(
    herb => 'Comserv::Model::Schema::Forager::Result::Herb',
    'herb_id',
);

1;
