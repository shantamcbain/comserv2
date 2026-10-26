package Comserv::Model::Schema::Ency::Result::HealthKitchen::IntakeLog;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('hk_intake_log');

# What a user ate. Nutrient values are snapshotted (already multiplied by servings)
# so daily totals stay stable if hk_food_nutrient rows are later re-imported.

__PACKAGE__->add_columns(
    id               => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    user_id          => { data_type => 'integer', is_nullable => 0 },
    sitename         => { data_type => 'varchar', size => 255, is_nullable => 0 },
    log_date         => { data_type => 'date', is_nullable => 0 },
    meal_slot        => { data_type => 'varchar', size => 20, is_nullable => 1 },
    food_nutrient_id => { data_type => 'integer', is_nullable => 1 },
    food_name        => { data_type => 'varchar', size => 255, is_nullable => 0 },
    servings         => { data_type => 'decimal', size => [10, 2], is_nullable => 0, default_value => 1 },
    calories         => { data_type => 'decimal', size => [10, 2], is_nullable => 1 },
    protein_g        => { data_type => 'decimal', size => [10, 2], is_nullable => 1 },
    carbs_g          => { data_type => 'decimal', size => [10, 2], is_nullable => 1 },
    fat_g            => { data_type => 'decimal', size => [10, 2], is_nullable => 1 },
    fiber_g          => { data_type => 'decimal', size => [10, 2], is_nullable => 1 },
    sugar_g          => { data_type => 'decimal', size => [10, 2], is_nullable => 1 },
    sodium_mg        => { data_type => 'decimal', size => [10, 2], is_nullable => 1 },
    notes            => { data_type => 'text', is_nullable => 1 },
    created_at       => { data_type => 'datetime', is_nullable => 1, set_on_create => 1 },
    updated_at       => { data_type => 'datetime', is_nullable => 1, set_on_create => 1, set_on_update => 1 },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    food => 'Comserv::Model::Schema::Ency::Result::HealthKitchen::FoodNutrient',
    { 'foreign.id' => 'self.food_nutrient_id' },
    { is_foreign_key_constraint => 0, join_type => 'LEFT' },
);

1;
