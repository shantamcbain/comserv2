package Comserv::Model::Schema::Forager::Result::Herb;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp', 'EncodedColumn');
__PACKAGE__->table('ency_herb_tb');
__PACKAGE__->add_columns(
    record_id          => { data_type => 'integer',  is_auto_increment => 1, is_nullable => 0 },
    botanical_name     => { data_type => 'varchar',  size => 255, is_nullable => 0, default_value => '' },
    key_name           => { data_type => 'varchar',  size => 255, is_nullable => 1 },
    common_names       => { data_type => 'text',     is_nullable => 1 },
    parts_used         => { data_type => 'varchar',  size => 500, is_nullable => 1 },
    sister_plants      => { data_type => 'text',     is_nullable => 1 },
    comments           => { data_type => 'text',     is_nullable => 1 },
    ident_character    => { data_type => 'text',     is_nullable => 1 },
    stem               => { data_type => 'text',     is_nullable => 1 },
    leaves             => { data_type => 'text',     is_nullable => 1 },
    flowers            => { data_type => 'text',     is_nullable => 1 },
    fruit              => { data_type => 'text',     is_nullable => 1 },
    taste              => { data_type => 'varchar',  size => 255, is_nullable => 1 },
    odour              => { data_type => 'varchar',  size => 255, is_nullable => 1 },
    root               => { data_type => 'text',     is_nullable => 1 },
    image              => { data_type => 'varchar',  size => 500, is_nullable => 1 },
    url                => { data_type => 'varchar',  size => 500, is_nullable => 1 },
    distribution       => { data_type => 'text',     is_nullable => 1 },
    cultivation        => { data_type => 'text',     is_nullable => 1 },
    harvest            => { data_type => 'text',     is_nullable => 1 },
    therapeutic_action => { data_type => 'text',     is_nullable => 1 },
    medical_uses       => { data_type => 'text',     is_nullable => 1 },
    constituents       => { data_type => 'text',     is_nullable => 1 },
    solvents           => { data_type => 'text',     is_nullable => 1 },
    dosage             => { data_type => 'text',     is_nullable => 1 },
    administration     => { data_type => 'text',     is_nullable => 1 },
    formulas           => { data_type => 'text',     is_nullable => 1 },
    contra_indications => { data_type => 'text',     is_nullable => 1 },
    preparation        => { data_type => 'text',     is_nullable => 1 },
    chinese            => { data_type => 'text',     is_nullable => 1 },
    vetrinary          => { data_type => 'text',     is_nullable => 1 },
    homiopathic        => { data_type => 'text',     is_nullable => 1 },
    apis               => { data_type => 'varchar',  size => 100, is_nullable => 0, default_value => '0' },
    pollinator         => { data_type => 'text',     is_nullable => 1 },
    pollen             => { data_type => 'tinyint',  is_nullable => 0, default_value => 0 },
    pollennotes        => { data_type => 'text',     is_nullable => 1 },
    nectar             => { data_type => 'tinyint',  is_nullable => 0, default_value => 0 },
    nectarnotes        => { data_type => 'text',     is_nullable => 1 },
    non_med            => { data_type => 'text',     is_nullable => 1 },
    culinary           => { data_type => 'text',     is_nullable => 1 },
    history            => { data_type => 'text',     is_nullable => 1 },
    reference          => { data_type => 'text',     is_nullable => 1 },
    username_of_poster => { data_type => 'varchar',  size => 100, is_nullable => 1 },
    group_of_poster    => { data_type => 'varchar',  size => 100, is_nullable => 1 },
    date_time_posted   => { data_type => 'varchar',  size => 30,  is_nullable => 1 },
    share              => { data_type => 'integer',  is_nullable => 0, default_value => 0 },
);

__PACKAGE__->set_primary_key('record_id');

__PACKAGE__->has_many(
    herb_constituents => 'Comserv::Model::Schema::Ency::Result::HerbConstituent',
    'herb_id',
);

__PACKAGE__->has_many(
    herb_diseases => 'Comserv::Model::Schema::Ency::Result::HerbDisease',
    'herb_id',
);

__PACKAGE__->has_many(
    herb_symptoms => 'Comserv::Model::Schema::Ency::Result::HerbSymptom',
    'herb_id',
);

__PACKAGE__->has_many(
    disease_herbs => 'Comserv::Model::Schema::Ency::Result::DiseaseHerb',
    'herb_id',
);

__PACKAGE__->has_many(
    insect_herbs => 'Comserv::Model::Schema::Ency::Result::InsectHerb',
    'herb_id',
);

__PACKAGE__->has_many(
    animal_herbs => 'Comserv::Model::Schema::Ency::Result::AnimalHerb',
    'herb_id',
);

__PACKAGE__->has_many(
    herb_categories => 'Comserv::Model::Schema::Ency::Result::HerbCategory',
    'herb_id',
);

1;
