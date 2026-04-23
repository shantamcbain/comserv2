package Comserv::Model::Schema::Ency::Result::Drug;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('ency_drug_tb');
__PACKAGE__->add_columns(
    record_id => {
        data_type         => 'int',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    brand_name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    generic_name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    inn_name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    drug_class => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    drug_subclass => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    formulation => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    strength => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    package_size => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    route_of_administration => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    prescription_status => {
        data_type     => 'varchar',
        size          => 20,
        is_nullable   => 1,
        default_value => 'Rx',
    },
    din_number => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    ndc_code => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    atc_code => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    manufacturer => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    active_ingredients => {
        data_type   => 'text',
        is_nullable => 1,
    },
    inactive_ingredients => {
        data_type   => 'text',
        is_nullable => 1,
    },
    mechanism_of_action => {
        data_type   => 'text',
        is_nullable => 1,
    },
    pharmacokinetics => {
        data_type   => 'text',
        is_nullable => 1,
    },
    pharmacodynamics => {
        data_type   => 'text',
        is_nullable => 1,
    },
    indications => {
        data_type   => 'text',
        is_nullable => 1,
    },
    contraindications => {
        data_type   => 'text',
        is_nullable => 1,
    },
    warnings => {
        data_type   => 'text',
        is_nullable => 1,
    },
    side_effects => {
        data_type   => 'text',
        is_nullable => 1,
    },
    drug_interactions => {
        data_type   => 'text',
        is_nullable => 1,
    },
    herb_drug_interactions => {
        data_type   => 'text',
        is_nullable => 1,
    },
    dosage_adult => {
        data_type   => 'text',
        is_nullable => 1,
    },
    dosage_pediatric => {
        data_type   => 'text',
        is_nullable => 1,
    },
    dosage_geriatric => {
        data_type   => 'text',
        is_nullable => 1,
    },
    duration_typical => {
        data_type   => 'text',
        is_nullable => 1,
    },
    storage => {
        data_type   => 'text',
        is_nullable => 1,
    },
    pregnancy_category => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    breastfeeding_notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    herbal_alternatives => {
        data_type   => 'text',
        is_nullable => 1,
    },
    naturopathic_notes => {
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
    drug_diseases => 'Comserv::Model::Schema::Ency::Result::DrugDisease',
    'drug_id',
);

__PACKAGE__->has_many(
    drug_constituents => 'Comserv::Model::Schema::Ency::Result::DrugConstituent',
    'drug_id',
);

__PACKAGE__->has_many(
    drug_symptoms => 'Comserv::Model::Schema::Ency::Result::DrugSymptom',
    'drug_id',
);

__PACKAGE__->has_many(
    drug_herb_interactions => 'Comserv::Model::Schema::Ency::Result::DrugHerbInteraction',
    'drug_id',
);

1;
