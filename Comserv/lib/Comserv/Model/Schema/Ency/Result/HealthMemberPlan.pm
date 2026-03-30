package Comserv::Model::Schema::Ency::Result::HealthMemberPlan;
use base 'DBIx::Class::Core';

__PACKAGE__->table('health_member_plans');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        is_auto_increment => 1,
    },
    user_id => {
        data_type => 'int',
    },
    sitename => {
        data_type => 'varchar',
        size      => 255,
    },
    goal => {
        data_type   => 'text',
        is_nullable => 1,
    },
    status => {
        data_type     => 'varchar',
        size          => 50,
        default_value => 'active',
    },
    start_date => {
        data_type   => 'date',
        is_nullable => 1,
    },
    end_date => {
        data_type   => 'date',
        is_nullable => 1,
    },
    disease_id => {
        data_type   => 'int',
        is_nullable => 1,
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    created_by => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    created_at => {
        data_type   => 'datetime',
        is_nullable => 1,
    },
    updated_at => {
        data_type   => 'datetime',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'disease' => 'Comserv::Model::Schema::Ency::Result::HealthDisease',
    'disease_id',
    { join_type => 'left' },
);

__PACKAGE__->belongs_to(
    'user' => 'Comserv::Model::Schema::Ency::Result::User',
    'user_id',
);

__PACKAGE__->has_many(
    'diet_plans' => 'Comserv::Model::Schema::Ency::Result::HealthDietPlan',
    'plan_id',
);

__PACKAGE__->has_many(
    'herb_prescriptions' => 'Comserv::Model::Schema::Ency::Result::HealthHerbPrescription',
    'plan_id',
);

__PACKAGE__->has_many(
    'exercise_plans' => 'Comserv::Model::Schema::Ency::Result::HealthExercisePlan',
    'plan_id',
);

1;
