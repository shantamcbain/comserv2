package Comserv::Model::Schema::Ency::Result::Ency::ExternalID;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('ency_external_id_tb');

__PACKAGE__->add_columns(
    record_id => {
        data_type         => 'int',
        size              => 11,
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    entity_type => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 0,
        comment     => 'herb|constituent|disease|symptom|organism|glossary',
    },
    entity_id => {
        data_type   => 'int',
        size        => 11,
        is_nullable => 0,
    },
    db_name => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 0,
        comment     => 'NCBI|PubChem|ChEBI|GBIF|IUCN|DOID|MeSH|USDA|DrugBank|Trefle',
    },
    external_id => {
        data_type   => 'varchar',
        size        => 200,
        is_nullable => 0,
    },
    source_url => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    retrieved_at => {
        data_type     => 'datetime',
        is_nullable   => 1,
    },
    bias_rating => {
        data_type     => 'tinyint',
        size          => 1,
        is_nullable   => 1,
        comment       => '1=high bias/allopathic 5=neutral/evidence 9=traditional',
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('record_id');
__PACKAGE__->add_unique_constraint(
    unique_entity_db => [qw(entity_type entity_id db_name)],
);

1;
