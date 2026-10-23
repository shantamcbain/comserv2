package Comserv::Model::Schema::Ency::Result::HealthKitchen::MealPlan;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('hk_meal_plan');

# Inventory-first meal plan header. Entries reference ency_recipe (food_recipe);
# requirements are checked against pantry/inventory before a shopping list is made.

__PACKAGE__->add_columns(
    id         => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    user_id    => { data_type => 'integer', is_nullable => 0 },
    sitename   => { data_type => 'varchar', size => 255, is_nullable => 0 },
    name       => { data_type => 'varchar', size => 255, is_nullable => 0 },
    start_date => { data_type => 'date', is_nullable => 1 },
    end_date   => { data_type => 'date', is_nullable => 1 },
    status     => { data_type => 'varchar', size => 20, is_nullable => 0, default_value => 'draft',
                    comment => 'draft | active | done | archived' },
    notes      => { data_type => 'text', is_nullable => 1 },
    created_at => { data_type => 'datetime', is_nullable => 1, set_on_create => 1 },
    updated_at => { data_type => 'datetime', is_nullable => 1, set_on_create => 1, set_on_update => 1 },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->has_many(
    entries => 'Comserv::Model::Schema::Ency::Result::HealthKitchen::MealPlanEntry',
    { 'foreign.meal_plan_id' => 'self.id' },
    { cascade_delete => 1 },
);

1;
