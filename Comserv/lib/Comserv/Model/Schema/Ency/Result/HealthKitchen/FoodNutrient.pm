package Comserv::Model::Schema::Ency::Result::HealthKitchen::FoodNutrient;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('hk_food_nutrient');

# Nutrient facts per serving. Manual entry now; source + source_ref let a public
# food DB import (e.g. USDA FoodData Central, Open Food Facts) upsert rows later.
# sitename NULL = shared/global row (imports); otherwise site-owned manual row.

__PACKAGE__->add_columns(
    id                => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    sitename          => { data_type => 'varchar', size => 255, is_nullable => 1 },
    name              => { data_type => 'varchar', size => 255, is_nullable => 0 },
    brand             => { data_type => 'varchar', size => 255, is_nullable => 1 },
    source            => { data_type => 'varchar', size => 32, is_nullable => 0, default_value => 'manual',
                           comment => 'manual | usda_fdc | open_food_facts | ...' },
    source_ref        => { data_type => 'varchar', size => 64, is_nullable => 1, comment => 'External id in source DB' },
    inventory_item_id => { data_type => 'integer', is_nullable => 1 },
    serving_size      => { data_type => 'decimal', size => [10, 2], is_nullable => 0, default_value => 100 },
    serving_unit      => { data_type => 'varchar', size => 32, is_nullable => 0, default_value => 'g' },
    calories          => { data_type => 'decimal', size => [10, 2], is_nullable => 1 },
    protein_g         => { data_type => 'decimal', size => [10, 2], is_nullable => 1 },
    carbs_g           => { data_type => 'decimal', size => [10, 2], is_nullable => 1 },
    fat_g             => { data_type => 'decimal', size => [10, 2], is_nullable => 1 },
    fiber_g           => { data_type => 'decimal', size => [10, 2], is_nullable => 1 },
    sugar_g           => { data_type => 'decimal', size => [10, 2], is_nullable => 1 },
    sodium_mg         => { data_type => 'decimal', size => [10, 2], is_nullable => 1 },
    extra_json        => { data_type => 'text', is_nullable => 1, comment => 'Other nutrients from imports (JSON)' },
    created_by        => { data_type => 'integer', is_nullable => 1 },
    created_at        => { data_type => 'datetime', is_nullable => 1, set_on_create => 1 },
    updated_at        => { data_type => 'datetime', is_nullable => 1, set_on_create => 1, set_on_update => 1 },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(hk_food_nutrient_source => [qw/source source_ref/]);

1;
