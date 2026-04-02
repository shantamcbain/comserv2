package Comserv::Model::Schema::Ency::Result::Disease;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('ency_disease_tb');
__PACKAGE__->add_columns(
    record_id => {
        data_type         => 'int',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    common_name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    scientific_name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    disease_type => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    host_type => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    causative_agent => {
        data_type   => 'text',
        is_nullable => 1,
    },
    transmission => {
        data_type   => 'text',
        is_nullable => 1,
    },
    symptoms_description => {
        data_type   => 'text',
        is_nullable => 1,
    },
    diagnosis => {
        data_type   => 'text',
        is_nullable => 1,
    },
    treatment_conventional => {
        data_type   => 'text',
        is_nullable => 1,
    },
    treatment_herbal => {
        data_type   => 'text',
        is_nullable => 1,
    },
    prevention => {
        data_type   => 'text',
        is_nullable => 1,
    },
    prognosis => {
        data_type   => 'text',
        is_nullable => 1,
    },
    icd_code => {
        data_type   => 'varchar',
        size        => 20,
        is_nullable => 1,
    },
    distribution => {
        data_type   => 'text',
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
    history => {
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
    disease_symptoms => 'Comserv::Model::Schema::Ency::Result::DiseaseSymptom',
    'disease_id',
);

__PACKAGE__->has_many(
    disease_animals => 'Comserv::Model::Schema::Ency::Result::DiseaseAnimal',
    'disease_id',
);

__PACKAGE__->has_many(
    disease_insects => 'Comserv::Model::Schema::Ency::Result::DiseaseInsect',
    'disease_id',
);

__PACKAGE__->has_many(
    disease_herbs => 'Comserv::Model::Schema::Ency::Result::DiseaseHerb',
    'disease_id',
);

__PACKAGE__->has_many(
    constituent_diseases => 'Comserv::Model::Schema::Ency::Result::ConstituentDisease',
    'disease_id',
);

1;
