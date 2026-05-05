package Comserv::Model::Schema::Ency::Result::Ency::Herb;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('ency_herb_tb');
__PACKAGE__->add_columns(
    record_id          => { data_type => 'integer',  is_auto_increment => 1, is_nullable => 0 },
    botanical_name     => { data_type => 'text',     is_nullable => 0, default_value => '' },
    key_name           => { data_type => 'varchar',  size => 255, is_nullable => 1, default_value => '' },
    common_names       => { data_type => 'text',     is_nullable => 1 },
    parts_used         => { data_type => 'text',     is_nullable => 1 },
    sister_plants      => { data_type => 'text',     is_nullable => 1 },
    comments           => { data_type => 'text',     is_nullable => 1, default_value => '' },
    ident_character    => { data_type => 'text',     is_nullable => 1, default_value => '' },
    stem               => { data_type => 'text',     is_nullable => 1 },
    leaves             => { data_type => 'text',     is_nullable => 1 },
    flowers            => { data_type => 'text',     is_nullable => 1, default_value => '' },
    fruit              => { data_type => 'text',     is_nullable => 1 },
    taste              => { data_type => 'text',     is_nullable => 1 },
    odour              => { data_type => 'text',     is_nullable => 1, default_value => '' },
    root               => { data_type => 'text',     is_nullable => 1, default_value => '' },
    image              => { data_type => 'varchar',  size => 1000, is_nullable => 1, default_value => '' },
    url                => { data_type => 'varchar',  size => 500,  is_nullable => 1, default_value => '' },
    distribution       => { data_type => 'text',     is_nullable => 1, default_value => '' },
    cultivation        => { data_type => 'text',     is_nullable => 1, default_value => '' },
    harvest            => { data_type => 'text',     is_nullable => 1, default_value => '' },
    therapeutic_action => { data_type => 'text',     is_nullable => 1, default_value => '' },
    medical_uses       => { data_type => 'text',     is_nullable => 1 },
    constituents       => { data_type => 'text',     is_nullable => 1, default_value => '' },
    solvents           => { data_type => 'text',     is_nullable => 1, default_value => '' },
    dosage             => { data_type => 'text',     is_nullable => 1, default_value => '' },
    administration     => { data_type => 'text',     is_nullable => 1, default_value => '' },
    formulas           => { data_type => 'text',     is_nullable => 1, default_value => '' },
    contra_indications => { data_type => 'text',     is_nullable => 1, default_value => '' },
    preparation        => { data_type => 'text',     is_nullable => 1, default_value => '' },
    chinese            => { data_type => 'text',     is_nullable => 1, default_value => '' },
    vetrinary          => { data_type => 'text',     is_nullable => 1, default_value => '' },
    homiopathic        => { data_type => 'text',     is_nullable => 1, default_value => '' },
    apis               => { data_type => 'varchar',  size => 100, is_nullable => 0, default_value => '0' },
    pollinator         => { data_type => 'text',     is_nullable => 1 },
    pollen             => { data_type => 'integer',  is_nullable => 0, default_value => 0 },
    pollennotes        => { data_type => 'text',     is_nullable => 1, default_value => '' },
    nectar             => { data_type => 'integer',  is_nullable => 0, default_value => 0 },
    nectarnotes        => { data_type => 'text',     is_nullable => 1, default_value => '' },
    non_med            => { data_type => 'text',     is_nullable => 1, default_value => '' },
    culinary           => { data_type => 'text',     is_nullable => 1 },
    history            => { data_type => 'text',     is_nullable => 1, default_value => '' },
    reference          => { data_type => 'text',     is_nullable => 1, default_value => '' },
    username_of_poster => { data_type => 'varchar',  size => 100, is_nullable => 1 },
    group_of_poster    => { data_type => 'varchar',  size => 100, is_nullable => 1 },
    date_time_posted   => { data_type => 'varchar',  size => 30,  is_nullable => 1 },
    share              => { data_type => 'integer',  is_nullable => 0, default_value => 0 },
);

__PACKAGE__->set_primary_key('record_id');

__PACKAGE__->has_many(
    herb_constituents => 'Comserv::Model::Schema::Ency::Result::Ency::HerbConstituent',
    'herb_id',
);

__PACKAGE__->has_many(
    herb_diseases => 'Comserv::Model::Schema::Ency::Result::Ency::HerbDisease',
    'herb_id',
);

__PACKAGE__->has_many(
    herb_symptoms => 'Comserv::Model::Schema::Ency::Result::Ency::HerbSymptom',
    'herb_id',
);

__PACKAGE__->has_many(
    disease_herbs => 'Comserv::Model::Schema::Ency::Result::Ency::DiseaseHerb',
    'herb_id',
);

__PACKAGE__->has_many(
    insect_herbs => 'Comserv::Model::Schema::Ency::Result::Ency::InsectHerb',
    'herb_id',
);

__PACKAGE__->has_many(
    animal_herbs => 'Comserv::Model::Schema::Ency::Result::Ency::AnimalHerb',
    'herb_id',
);

__PACKAGE__->has_many(
    herb_categories => 'Comserv::Model::Schema::Ency::Result::Ency::HerbCategory',
    'herb_id',
);

1;
