package Comserv::Model::Schema::Ency::Result::HealthExercisePlan;
use base 'DBIx::Class::Core';

__PACKAGE__->table('health_exercise_plans');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        is_auto_increment => 1,
    },
    plan_id => {
        data_type => 'int',
    },
    exercise_type => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    frequency_per_week => {
        data_type   => 'int',
        is_nullable => 1,
    },
    duration_minutes => {
        data_type   => 'int',
        is_nullable => 1,
    },
    intensity => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    description => {
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

1;
