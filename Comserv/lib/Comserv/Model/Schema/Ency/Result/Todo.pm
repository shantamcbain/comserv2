package Comserv::Model::Schema::Ency::Result::Todo;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

__PACKAGE__->table('todo');
__PACKAGE__->add_columns(
    record_id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    sitename => {
        data_type => 'varchar',
        size => 255,
    },
    start_date => {
        data_type => 'date',
    },
    parent_todo => {
        data_type => 'varchar',
    },
    due_date => {
        data_type => 'date',
    },
    subject => {
        data_type => 'varchar',
        size => 255,
    },
    description => {
        data_type => 'text',
    },
    estimated_man_hours => {
        data_type => 'integer',
    },
  "comments",
  { data_type => "text", is_nullable => 1 },
    accumulative_time => {
        data_type => 'time',
    },
    "reporter",
    { data_type => "varchar", default_value => "", is_nullable => 1, size => 50 },
    "company_code",
    { data_type => "varchar", default_value => "", is_nullable => 1, size => 30 },
    "owner",
    { data_type => "varchar", default_value => "", is_nullable => 1, size => 30 },
    project_code => {
        data_type => 'varchar',
        size => 255,
    },
    "developer",
    { data_type => "varchar", default_value => "", is_nullable => 1, size => 50 },
    "username_of_poster",
    { data_type => "varchar", default_value => "", is_nullable => 1, size => 30 },
    status => {
        data_type => 'varchar',
        size => 255,
    },
    priority => {
        data_type => 'integer',
    },
    share => {
        data_type => 'integer',
    },
    last_mod_by => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
        default_value => 'system',
    },
    last_mod_date => {
        data_type => 'date',
    },
    group_of_poster => {
        data_type => 'varchar',
        size => 255,
    },
    user_id => {
        data_type => 'integer',
    },
    project_id => {
        data_type => 'integer',
    },
    "date_time_posted",
    { data_type => "varchar", default_value => "", is_nullable => 1, size => 30 },
    plan_id => {
        data_type => 'integer',
        is_nullable => 1,
    },
    blocked_by_todo_id => {
        data_type => 'integer',
        is_nullable => 1,
    },
    parent_id => {
        data_type => 'integer',
        is_nullable => 1,
    },
    sort_order => {
        data_type => 'integer',
        default_value => 0,
        is_nullable => 0,
    },
    is_blocking => {
        data_type => 'boolean',
        default_value => 0,
        is_nullable => 0,
    },
    scheduled_date => {
        data_type => 'date',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('record_id');
__PACKAGE__->has_many(
    'logs' => 'Comserv::Model::Schema::Ency::Result::Log',
    { 'foreign.todo_record_id' => 'self.record_id' },
    { cascade_delete => 1 }
);
__PACKAGE__->belongs_to(user => 'Comserv::Model::Schema::Ency::Result::User', 'user_id');
__PACKAGE__->belongs_to(project => 'Comserv::Model::Schema::Ency::Result::Project', 'project_id');

__PACKAGE__->belongs_to(
    'plan' => 'Comserv::Model::Schema::Ency::Result::DailyPlan',
    'plan_id',
    { join_type => 'left', on_delete => 'set null' }
);

__PACKAGE__->belongs_to(
    'parent' => 'Comserv::Model::Schema::Ency::Result::Todo',
    'parent_id',
    { join_type => 'left', on_delete => 'set null' }
);

__PACKAGE__->belongs_to(
    'blocker' => 'Comserv::Model::Schema::Ency::Result::Todo',
    'blocked_by_todo_id',
    { join_type => 'left', on_delete => 'set null' }
);

__PACKAGE__->has_many(
    'subtodos' => 'Comserv::Model::Schema::Ency::Result::Todo',
    'parent_id',
    { cascade_delete => 0 }
);

__PACKAGE__->has_many(
    'blocking_dependencies' => 'Comserv::Model::Schema::Ency::Result::TodoDependency',
    'blocking_todo_id',
    { cascade_delete => 1 }
);

__PACKAGE__->has_many(
    'dependent_dependencies' => 'Comserv::Model::Schema::Ency::Result::TodoDependency',
    'dependent_todo_id',
    { cascade_delete => 1 }
);

sub get_all_subtodos {
    my ($self, $depth) = @_;
    $depth ||= 0;
    return [] if $depth > 10;
    
    my @result;
    my @children = $self->subtodos->all;
    foreach my $child (@children) {
        push @result, $child;
        push @result, @{$child->get_all_subtodos($depth + 1)};
    }
    return \@result;
}

sub get_blocking_chain {
    my ($self, $visited) = @_;
    $visited ||= {};
    return [] if $visited->{$self->record_id};
    $visited->{$self->record_id} = 1;
    
    my @chain;
    if ($self->blocker) {
        push @chain, $self->blocker;
        push @chain, @{$self->blocker->get_blocking_chain($visited)};
    }
    
    my @deps = $self->dependent_dependencies->search({ dependency_type => 'blocks' })->all;
    foreach my $dep (@deps) {
        my $blocker = $dep->blocking_todo;
        next if $visited->{$blocker->record_id};
        push @chain, $blocker;
        push @chain, @{$blocker->get_blocking_chain($visited)};
    }
    
    return \@chain;
}

1;
