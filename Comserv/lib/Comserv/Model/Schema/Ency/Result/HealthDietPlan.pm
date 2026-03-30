package Comserv::Model::Schema::Ency::Result::HealthDietPlan;
use base 'DBIx::Class::Core';

__PACKAGE__->table('health_diet_plans');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        is_auto_increment => 1,
    },
    plan_id => {
        data_type => 'int',
    },
    dietary_protocol => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    description => {
        data_type   => 'text',
        is_nullable => 1,
    },
    foods_to_emphasise => {
        data_type   => 'text',
        is_nullable => 1,
    },
    foods_to_avoid => {
        data_type   => 'text',
        is_nullable => 1,
    },
    created_at => {
        data_type   => 'datetime',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'member_plan' => 'Comserv::Model::Schema::Ency::Result::HealthMemberPlan',
    'plan_id',
);

__PACKAGE__->has_many(
    'meal_plans' => 'Comserv::Model::Schema::Ency::Result::HealthMealPlan',
    'diet_plan_id',
);

1;
