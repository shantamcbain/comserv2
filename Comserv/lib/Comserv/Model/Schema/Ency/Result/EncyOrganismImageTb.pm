package Comserv::Model::Schema::Ency::Result::EncyOrganismImageTb;
use base 'DBIx::Class::Core';

__PACKAGE__->table('ency_organism_image_tb');
__PACKAGE__->add_columns(
    caption => {
        data_type => 'text',
        is_nullable => 1,
    },
    date_time_posted => {
        data_type => 'datetime',
        is_nullable => 1,
    },
    is_primary => {
        data_type => 'tinyint',
        size => 1,
        default_value => '0',
    },
    license => {
        data_type => 'varchar',
        size => 200,
        is_nullable => 1,
    },
    organism_id => {
        data_type => 'int',
        size => 11,
    },
    record_id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
    rights_holder => {
        data_type => 'text',
        is_nullable => 1,
    },
    sort_order => {
        data_type => 'smallint',
        size => 6,
        default_value => '0',
    },
    source => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    thumbnail_url => {
        data_type => 'text',
        is_nullable => 1,
    },
    url => {
        data_type => 'text',
        is_nullable => 1,
    },
    username_of_poster => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('record_id');

1;
