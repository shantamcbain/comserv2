package Comserv::Model::Schema::Ency::Result::Ency::DiseaseHost;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('ency_disease_host_tb');
__PACKAGE__->add_columns(
    record_id => {
        data_type         => 'int',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    disease_id => {
        data_type   => 'int',
        is_nullable => 0,
    },
    organism_id => {
        data_type   => 'int',
        is_nullable => 1,
    },
    host_category => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 0,
        default_value => 'human',
    },
    sub_population => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('record_id');

__PACKAGE__->belongs_to(
    disease => 'Comserv::Model::Schema::Ency::Result::Ency::Disease',
    'disease_id',
);

__PACKAGE__->belongs_to(
    organism => 'Comserv::Model::Schema::Ency::Result::Ency::Organism',
    'organism_id',
    { join_type => 'LEFT' },
);

1;
