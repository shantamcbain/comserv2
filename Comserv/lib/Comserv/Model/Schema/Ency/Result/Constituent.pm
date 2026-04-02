package Comserv::Model::Schema::Ency::Result::Constituent;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('ency_constituent_tb');
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
    chemical_formula => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    chemical_class => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    iupac_name => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    cas_number => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    molecular_weight => {
        data_type     => 'decimal',
        size          => [10, 4],
        is_nullable   => 1,
    },
    therapeutic_action => {
        data_type   => 'text',
        is_nullable => 1,
    },
    toxicity => {
        data_type   => 'text',
        is_nullable => 1,
    },
    solubility => {
        data_type   => 'text',
        is_nullable => 1,
    },
    found_in_herbs => {
        data_type   => 'text',
        is_nullable => 1,
    },
    found_in_foods => {
        data_type   => 'text',
        is_nullable => 1,
    },
    found_in_drugs => {
        data_type   => 'text',
        is_nullable => 1,
    },
    pharmacological_effects => {
        data_type   => 'text',
        is_nullable => 1,
    },
    research_notes => {
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
    herb_constituents => 'Comserv::Model::Schema::Forager::Result::HerbConstituent',
    'constituent_id',
);

__PACKAGE__->has_many(
    constituent_diseases => 'Comserv::Model::Schema::Forager::Result::ConstituentDisease',
    'constituent_id',
);

__PACKAGE__->has_many(
    constituent_symptoms => 'Comserv::Model::Schema::Forager::Result::ConstituentSymptom',
    'constituent_id',
);

1;
