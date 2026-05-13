package Comserv::Model::Schema::Ency::Result::Ency::EcologicalLink;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('ency_ecological_link_tb');

__PACKAGE__->add_columns(
    record_id => {
        data_type         => 'int',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    consumer_type => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 0,
        default_value => '',
        comment     => 'herb, animal, insect, bird, fungi, human, other',
    },
    consumer_id => {
        data_type   => 'int',
        is_nullable => 1,
        comment     => 'FK into the relevant entity table (nullable — may be raw text only)',
    },
    consumer_name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
        default_value => '',
        comment     => 'Denormalised display name for the consumer',
    },
    plant_type => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 0,
        default_value => 'herb',
        comment     => 'herb, plant, tree, shrub, fungus',
    },
    plant_id => {
        data_type   => 'int',
        is_nullable => 1,
        comment     => 'FK into ency_herb_tb or forager herb table',
    },
    plant_name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
        default_value => '',
        comment     => 'Denormalised botanical/common name for the plant',
    },
    relationship_type => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 0,
        default_value => '',
        comment     => 'eats_seeds, eats_leaves, eats_fruit, eats_nectar, eats_pollen, eats_roots, eats_bark, eats_whole, medicinal_use, nesting_material, shelter, toxic_to, parasitizes',
    },
    plant_part => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 0,
        default_value => '',
        comment     => 'seeds, leaves, fruit, nectar, pollen, roots, bark, whole, flowers, stems',
    },
    season => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 0,
        default_value => '',
        comment     => 'spring, summer, autumn, winter, year-round',
    },
    notes => {
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
        is_nullable   => 0,
        default_value => 'ENCY',
    },
    username_of_poster => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    date_time_posted => {
        data_type   => 'varchar',
        size        => 30,
        is_nullable => 1,
    },
    share => {
        data_type     => 'tinyint',
        is_nullable   => 0,
        default_value => 0,
    },
);

__PACKAGE__->set_primary_key('record_id');

__PACKAGE__->add_unique_constraint(
    unique_ecological_link => ['consumer_type', 'consumer_id', 'plant_type', 'plant_id', 'relationship_type', 'plant_part']
);

1;
