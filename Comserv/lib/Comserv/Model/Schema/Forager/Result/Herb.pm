package Comserv::Model::Schema::Forager::Result::Herb;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp', 'EncodedColumn');
__PACKAGE__->table('ency_herb_tb');
__PACKAGE__->add_columns(
    'therapeutic_action' => { data_type => 'varchar', size => 250, is_nullable => 0, default_value => '' },
    'username' => { data_type => 'varchar', size => 30, is_nullable => 0, default_value => '' },
    'record_id' => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    'botanical_name' => { data_type => 'text', is_nullable => 0 },
    'common_names' => { data_type => 'text', is_nullable => 0 },
    'key_name' => { data_type => 'varchar', size => 30, is_nullable => 0, default_value => '' },
    'parts_used' => { data_type => 'text', is_nullable => 1 },
    'share' => { data_type => 'integer', default_value => 0, is_nullable => 0 },
    'comments' => { data_type => 'text', is_nullable => 0 },
    'medical_uses' => { data_type => 'text', is_nullable => 1 },
    'ident_character' => { data_type => 'text', is_nullable => 0 },
    'image' => { data_type => 'varchar', size => 1000, is_nullable => 0, default_value => '' },
    'stem' => { data_type => 'text', is_nullable => 1 },
    'leaves' => { data_type => 'text', is_nullable => 1 },
    'flowers' => { data_type => 'varchar', size => 500, is_nullable => 0, default_value => '' },
    'fruit' => { data_type => 'text', is_nullable => 1 },
    'taste' => { data_type => 'text', is_nullable => 1 },
    'odour' => { data_type => 'varchar', size => 250, is_nullable => 0, default_value => '' },
    'distribution' => { data_type => 'varchar', size => 500, is_nullable => 0, default_value => '' },
    'body_parts' => { data_type => 'varchar', size => 175, is_nullable => 0, default_value => '' },
    'url' => { data_type => 'varchar', size => 150, is_nullable => 0, default_value => '' },
    'constituents' => { data_type => 'text', is_nullable => 0 },
    'solvents' => { data_type => 'varchar', size => 250, is_nullable => 0, default_value => '' },
    'root' => { data_type => 'text', is_nullable => 0 },
    'chinese' => { data_type => 'text', is_nullable => 0 },
    'homiopathic' => { data_type => 'text', is_nullable => 0 },
    'contra_indications' => { data_type => 'varchar', size => 500, is_nullable => 0, default_value => '' },
    'preparation' => { data_type => 'varchar', size => 500, is_nullable => 0, default_value => '' },
    'dosage' => { data_type => 'text', is_nullable => 0 },
    'administration' => { data_type => 'text', is_nullable => 0 },
    'formulas' => { data_type => 'text', is_nullable => 0 },
    'vetrinary' => { data_type => 'text', is_nullable => 0 },
    'Culinary' => { data_type => 'varchar', size => 500, is_nullable => 0, default_value => '' },
    'cultivation' => { data_type => 'text', is_nullable => 0 },
    'pollinator' => { data_type => 'varchar', size => 250, is_nullable => 0, default_value => '' },
    'apis' => { data_type => 'varchar', size => 250, is_nullable => 0, default_value => '' },
    'nectar' => { data_type => 'integer', is_nullable => 0 },
    'nectarnotes' => { data_type => 'text', is_nullable => 0 },
    'pollen' => { data_type => 'integer', is_nullable => 0 },
    'pollennotes' => { data_type => 'text', is_nullable => 0 },
    'sister_plants' => { data_type => 'varchar', size => 250, is_nullable => 0, default_value => '' },
    'harvest' => { data_type => 'text', is_nullable => 0 },
    'non_med' => { data_type => 'text', is_nullable => 0 },
    'history' => { data_type => 'text', is_nullable => 0 },
    'reference' => { data_type => 'text', is_nullable => 0 },
    'username_of_poster' => { data_type => 'varchar', size => 30, is_nullable => 1 },
    'group_of_poster' => { data_type => 'varchar', size => 30, is_nullable => 1 },
    'date_time_posted' => { data_type => 'varchar', size => 30, is_nullable => 1 },
);

__PACKAGE__->set_primary_key('record_id');

1;
