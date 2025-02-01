package Comserv::Model::Schema::Forager::Result::Herb;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp', 'EncodedColumn');
__PACKAGE__->table('ency_herb_tb');
__PACKAGE__->add_columns(
    'therapeutic_action',
    'record_id',
    'apis',
    'botanical_name',
    'key_name',
    'common_names',
    'parts_used',
    'comments',
    'url',
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
    'date_time_posted',
    'share' => { data_type => 'integer', default_value => 0, is_nullable => 0 },
     'preparation' => { data_type => 'varchar', size => 150, is_nullable => 0 },
    'pollennotes' => { data_type => 'text', is_nullable => 0 },
    'nectarnotes' => { data_type => 'text', is_nullable => 0 },
    'apis' => { data_type => 'varchar', size => 100, is_nullable => 0 },
);

__PACKAGE__->set_primary_key('record_id');

1;
