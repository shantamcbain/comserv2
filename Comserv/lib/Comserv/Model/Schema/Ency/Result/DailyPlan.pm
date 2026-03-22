package Comserv::Model::Schema::Ency::Result::DailyPlan;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

__PACKAGE__->table('dailyplan');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    plan_name => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    plan_description => {
        data_type => 'text',
        is_nullable => 1,
    },
    sitename => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    status => {
        data_type => 'enum',
        extra => { list => ['active', 'completed', 'archived', 'paused'] },
        default_value => 'active',
        is_nullable => 0,
    },
    start_date => {
        data_type => 'date',
        is_nullable => 1,
    },
    due_date => {
        data_type => 'date',
        is_nullable => 1,
    },
    priority => {
        data_type => 'integer',
        default_value => 0,
        is_nullable => 0,
    },
    created_by => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    created_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable => 0,
    },
    last_modified => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['sitename', 'plan_name']);

__PACKAGE__->has_many(
    'dailyplan_projects' => 'Comserv::Model::Schema::Ency::Result::DailyPlanProject',
    'plan_id',
    { cascade_delete => 1 }
);

__PACKAGE__->has_many(
    'todos' => 'Comserv::Model::Schema::Ency::Result::Todo',
    'plan_id',
    { cascade_delete => 0 }
);

__PACKAGE__->has_many(
    'system_mappings' => 'Comserv::Model::Schema::Ency::Result::PlanSystemMapping',
    'plan_id',
    { cascade_delete => 1 }
);

__PACKAGE__->has_many(
    'entries' => 'Comserv::Model::Schema::Ency::Result::DailyPlanEntry',
    'plan_id',
    { cascade_delete => 1 }
);

__PACKAGE__->many_to_many(
    'projects' => 'dailyplan_projects',
    'project'
);

sub get_todo_count {
    my $self = shift;
    return $self->todos->count;
}

sub get_completed_todo_count {
    my $self = shift;
    return $self->todos->search({ status => 'Completed' })->count;
}

sub get_progress_percentage {
    my $self = shift;
    my $total = $self->get_todo_count;
    return 0 unless $total > 0;
    my $completed = $self->get_completed_todo_count;
    return int(($completed / $total) * 100);
}

sub is_overdue {
    my $self = shift;
    return 0 unless $self->due_date;
    my $now = DateTime->now->ymd;
    return $self->due_date lt $now && $self->status ne 'completed';
}

1;
