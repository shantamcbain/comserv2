package Comserv::Model::Schema::Ency::Result::Symptom;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('ency_symptom_tb');
__PACKAGE__->add_columns(
    record_id => {
        data_type         => 'int',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    common_name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    description => {
        data_type   => 'text',
        is_nullable => 1,
    },
    body_system => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    severity => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    acute_chronic => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    host_type => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    image => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    url => {
        data_type   => 'text',
        is_nullable => 1,
    },
    reference => {
        data_type   => 'text',
        is_nullable => 1,
    },
    sitename => {
        data_type     => 'varchar',
        size          => 100,
        is_nullable   => 1,
        default_value => 'ENCY',
    },
    username_of_poster => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    group_of_poster => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    date_time_posted => {
        data_type   => 'varchar',
        size        => 30,
        is_nullable => 1,
    },
    share => {
        data_type     => 'integer',
        is_nullable   => 0,
        default_value => 0,
    },
);

__PACKAGE__->set_primary_key('record_id');

__PACKAGE__->has_many(
    disease_symptoms => 'Comserv::Model::Schema::Forager::Result::DiseaseSymptom',
    'symptom_id',
);

__PACKAGE__->has_many(
    herb_symptoms => 'Comserv::Model::Schema::Forager::Result::HerbSymptom',
    'symptom_id',
);

__PACKAGE__->has_many(
    constituent_symptoms => 'Comserv::Model::Schema::Forager::Result::ConstituentSymptom',
    'symptom_id',
);

1;
