package Comserv::Model::Schema::Ency::Result::DailyPlanProject;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

__PACKAGE__->table('dailyplan_project');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    plan_id => {
        data_type => 'integer',
        is_nullable => 0,
    },
    project_id => {
        data_type => 'integer',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('dailyplan_project_plan_id_project_id' => ['plan_id', 'project_id']);

__PACKAGE__->belongs_to(
    'plan' => 'Comserv::Model::Schema::Ency::Result::DailyPlan',
    'plan_id',
    { on_delete => 'cascade' }
);

__PACKAGE__->belongs_to(
    'project' => 'Comserv::Model::Schema::Ency::Result::Project',
    'project_id',
    { on_delete => 'cascade' }
);

1;
