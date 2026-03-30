package Comserv::Model::Schema::Ency::Result::HealthMealPlan;
use base 'DBIx::Class::Core';

__PACKAGE__->table('health_meal_plans');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        is_auto_increment => 1,
    },
    diet_plan_id => {
        data_type => 'int',
    },
    meal_slot => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    day_of_week => {
        data_type   => 'varchar',
        size        => 20,
        default_value => 'any',
        is_nullable => 1,
    },
    recipe_name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    ingredients => {
        data_type   => 'text',
        is_nullable => 1,
    },
    instructions => {
        data_type   => 'text',
        is_nullable => 1,
    },
    inventory_check => {
        data_type     => 'tinyint',
        size          => 1,
        default_value => 0,
        is_nullable   => 1,
    },
    created_at => {
        data_type   => 'datetime',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'diet_plan' => 'Comserv::Model::Schema::Ency::Result::HealthDietPlan',
    'diet_plan_id',
);

1;
