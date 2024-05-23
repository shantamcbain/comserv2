package Comserv::Model::Schema::Forager::Result::Herb;

use strict;
use warnings;

use base 'DBIx::Class::Core';

# Set the table name
__PACKAGE__->table('ency_herb_tb');

# Set the columns in the table
__PACKAGE__->add_columns(
    'therapeutic_action',
    'record_id',
    'apis',
    'botanical_name',
    'common_names',
    'key_name',
    'parts_used',
    'comments',
    'medical_uses',
    'homiopathic',
    'ident_character',
    'image',
    'stem',
    'nectar',
    'pollinator',
    'pollen',
    'leaves',
    'flowers',
    'fruit',
    'taste',
    'odour',
    'distribution',
    'url',
    'root',
    'constituents',
    'solvents',
    'chinese',
    'culinary',
    'contra_indications',
    'dosage',
    'administration',
    'formulas',
    'vetrinary',
    'cultivation',
    'sister_plants',
    'harvest',
    'non_med',
    'history',
    'reference',
    'username_of_poster',
    'group_of_poster',
    'date_time_posted'
);

# Set the primary key for the table
__PACKAGE__->set_primary_key('record_id');

1;