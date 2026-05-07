package Comserv::Model::Schema::Ency::Result::Ency::Organism;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('ency_organism_tb');
__PACKAGE__->add_columns(
    record_id => {
        data_type         => 'int',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    scientific_name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    organism_type => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 0,
        default_value => 'animal',
    },
    kingdom => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    phylum => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    class_name => {
        data_type   => 'varchar',
        size        => 100,
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
    ncbi_tax_id => {
        data_type   => 'int',
        is_nullable => 1,
    },
    gbif_id => {
        data_type   => 'int',
        is_nullable => 1,
    },
    iucn_id => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    description => {
        data_type   => 'text',
        is_nullable => 1,
    },
    habitat => {
        data_type   => 'text',
        is_nullable => 1,
    },
    sub_population_note => {
        data_type   => 'text',
        is_nullable => 1,
    },
    image => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    url => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    reference => {
        data_type   => 'text',
        is_nullable => 1,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    username_of_poster => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    group_of_poster => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    date_time_posted => {
        data_type   => 'datetime',
        is_nullable => 1,
    },
    share => {
        data_type     => 'tinyint',
        size          => 1,
        is_nullable   => 0,
        default_value => 1,
    },
);
__PACKAGE__->set_primary_key('record_id');

__PACKAGE__->has_many(
    disease_hosts => 'Comserv::Model::Schema::Ency::Result::Ency::DiseaseHost',
    'organism_id',
);

__PACKAGE__->has_many(
    common_names => 'Comserv::Model::Schema::Ency::Result::Ency::CommonName',
    'organism_id',
);

__PACKAGE__->has_many(
    herbs => 'Comserv::Model::Schema::Ency::Result::Ency::Herb',
    'organism_id',
);

1;
