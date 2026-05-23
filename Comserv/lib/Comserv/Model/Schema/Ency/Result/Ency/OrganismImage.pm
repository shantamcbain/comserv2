package Comserv::Model::Schema::Ency::Result::Ency::OrganismImage;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('ency_organism_image_tb');

__PACKAGE__->add_columns(
    record_id => {
        data_type         => 'int',
        size              => 11,
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    organism_id => {
        data_type   => 'int',
        size        => 11,
        is_nullable => 0,
        comment     => 'FK to ency_organism_tb',
    },
    url => {
        data_type   => 'varchar',
        size        => 1000,
        is_nullable => 1,
        comment     => 'External URL or local path (/static/uploads/...)',
    },
    thumbnail_url => {
        data_type   => 'varchar',
        size        => 1000,
        is_nullable => 1,
        comment     => 'Smaller version for gallery display',
    },
    caption => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    source => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
        comment     => 'e.g. GBIF, Wikipedia, manual',
    },
    license => {
        data_type   => 'varchar',
        size        => 200,
        is_nullable => 1,
        comment     => 'e.g. CC BY 4.0',
    },
    rights_holder => {
        data_type   => 'varchar',
        size        => 300,
        is_nullable => 1,
    },
    is_primary => {
        data_type     => 'tinyint',
        size          => 1,
        is_nullable   => 0,
        default_value => 0,
        comment       => '1 = main display image for this organism',
    },
    sort_order => {
        data_type     => 'smallint',
        is_nullable   => 0,
        default_value => 0,
    },
    date_time_posted => {
        data_type   => 'datetime',
        is_nullable => 1,
    },
    username_of_poster => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('record_id');

__PACKAGE__->belongs_to(
    organism => 'Comserv::Model::Schema::Ency::Result::Ency::Organism',
    'organism_id',
);

1;
