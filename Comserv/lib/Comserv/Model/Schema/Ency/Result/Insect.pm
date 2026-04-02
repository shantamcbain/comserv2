package Comserv::Model::Schema::Ency::Result::Insect;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('ency_insect_tb');
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
    order_name => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    family_name => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    genus => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    species => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    ecological_role => {
        data_type   => 'text',
        is_nullable => 1,
    },
    plants_foraged => {
        data_type   => 'text',
        is_nullable => 1,
    },
    plants_damaged => {
        data_type   => 'text',
        is_nullable => 1,
    },
    habitat => {
        data_type   => 'text',
        is_nullable => 1,
    },
    lifecycle => {
        data_type   => 'text',
        is_nullable => 1,
    },
    behavior => {
        data_type   => 'text',
        is_nullable => 1,
    },
    distribution => {
        data_type   => 'text',
        is_nullable => 1,
    },
    honey_production => {
        data_type   => 'text',
        is_nullable => 1,
    },
    pollination_notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    pest_notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    beneficial_notes => {
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
    disease_insects => 'Comserv::Model::Schema::Ency::Result::DiseaseInsect',
    'insect_id',
);

__PACKAGE__->has_many(
    insect_herbs => 'Comserv::Model::Schema::Ency::Result::InsectHerb',
    'insect_id',
);

1;
