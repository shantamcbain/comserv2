package Comserv::Model::Schema::Ency::Result::DrugConstituent;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('drug_constituent');
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
    constituent_id => {
        data_type   => 'int',
        is_nullable => 0,
    },
    quantity => {
        data_type     => 'decimal',
        size          => [10, 4],
        is_nullable   => 1,
    },
    unit => {
        data_type   => 'varchar',
        size        => 30,
        is_nullable => 1,
    },
    role => {
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
__PACKAGE__->add_unique_constraint(['drug_id', 'constituent_id']);

__PACKAGE__->belongs_to(
    drug => 'Comserv::Model::Schema::Ency::Result::Drug',
    'drug_id',
    { is_foreign_key_constraint => 0 },
);

__PACKAGE__->belongs_to(
    constituent => 'Comserv::Model::Schema::Ency::Result::Constituent',
    'constituent_id',
    { is_foreign_key_constraint => 0 },
);

1;
