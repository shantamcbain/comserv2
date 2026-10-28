package Comserv::Model::Schema::Ency::Result::HealthKitchen::MealPlanEntry;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('hk_meal_plan_entry');

# One meal slot in a plan. recipe_id -> ency_recipe.id (food_recipe), or free-text custom_name.

__PACKAGE__->add_columns(
    id           => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    meal_plan_id => { data_type => 'integer', is_nullable => 0 },
    plan_date    => { data_type => 'date', is_nullable => 1 },
    meal_slot    => { data_type => 'varchar', size => 20, is_nullable => 0, default_value => 'dinner',
                      comment => 'breakfast | lunch | dinner | snack' },
    recipe_id    => { data_type => 'integer', is_nullable => 1 },
    custom_name  => { data_type => 'varchar', size => 255, is_nullable => 1 },
    servings     => { data_type => 'decimal', size => [10, 2], is_nullable => 0, default_value => 1 },
    notes        => { data_type => 'text', is_nullable => 1 },
    created_at   => { data_type => 'datetime', is_nullable => 1, set_on_create => 1 },
    updated_at   => { data_type => 'datetime', is_nullable => 1, set_on_create => 1, set_on_update => 1 },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    meal_plan => 'Comserv::Model::Schema::Ency::Result::HealthKitchen::MealPlan',
    'meal_plan_id',
    { is_foreign_key_constraint => 0 },
);
__PACKAGE__->belongs_to(
    recipe => 'Comserv::Model::Schema::Ency::Result::Ency::Recipe',
    { 'foreign.id' => 'self.recipe_id' },
    { is_foreign_key_constraint => 0, join_type => 'LEFT' },
);

1;
