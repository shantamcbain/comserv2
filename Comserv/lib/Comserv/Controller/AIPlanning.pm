package Comserv::Controller::AIPlanning;
use Moose;
use namespace::autoclean;
use Try::Tiny;
use JSON;
use DateTime;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    lazy => 1,
    default => sub { Comserv::Util::Logging->instance },
);

sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto',
        "AIPlanning controller auto method called");

    my $user_id = $c->session->{user_id};
    my $site_id = $c->session->{SiteID};

    unless ($user_id) {
        $c->response->status(401);
        $c->response->content_type('application/json');
        $c->response->body(encode_json({
            success     => 0,
            error       => 'Authentication required to access planning features',
            upgrade_url => '/membership/plans',
        }));
        $c->detach;
        return 0;
    }

    my $roles = $c->session->{roles};
    my $is_admin = 0;
    if (ref $roles eq 'ARRAY') {
        $is_admin = 1 if grep { lc($_) eq 'admin' || lc($_) eq 'site_admin' } @$roles;
    } elsif ($roles) {
        $is_admin = 1 if lc($roles) eq 'admin' || lc($roles) eq 'site_admin';
    }
    return 1 if $is_admin;

    my $has_access = 0;
    eval {
        $has_access = $c->model('Membership')->check_access($c, $user_id, 'planning', $site_id);
    };
    if (my $err = $@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'auto',
            "Error checking membership access for planning: $err");
        $has_access = 0;
    }

    unless ($has_access) {
        $c->response->status(403);
        $c->response->content_type('application/json');
        $c->response->body(encode_json({
            success     => 0,
            error       => 'Planning features require a membership plan with planning access',
            upgrade_url => '/membership/plans',
        }));
        $c->detach;
        return 0;
    }

    return 1;
}

sub attach_to_plan :Path('/ai/planning/attach') :Args(0) {
    my ($self, $c) = @_;
    
    $c->response->content_type('application/json');
    
    my $params = $c->req->params;
    my $zenflow_task_id = $params->{zenflow_task_id};
    my $zenflow_step = $params->{zenflow_step};
    my $title = $params->{title} || 'Zenflow Task';
    my $description = $params->{description} || '';
    my $project_id = $params->{project_id};
    my $priority = $params->{priority} || 5;
    
    unless ($zenflow_task_id) {
        $c->response->status(400);
        $c->response->body(encode_json({
            success => 0,
            error => 'zenflow_task_id required'
        }));
        return;
    }
    
    try {
        my $schema = $c->model('DBEncy')->schema;
        
        my $now = DateTime->now;
        my $start_date = $now->ymd;
        my $due_date = $now->clone->add(days => 7)->ymd;
        
        my $metadata = {
            zenflow_task_id => $zenflow_task_id,
            zenflow_step => $zenflow_step,
            created_by => 'ai_system',
            ai_generated => 1,
        };
        
        my $todo = $schema->resultset('Todo')->create({
            subject => $title,
            description => $description,
            start_date => $start_date,
            due_date => $due_date,
            priority => $priority,
            status => 2,
            project_id => $project_id,
            site_id => $c->session->{SiteID} || 1,
            sitename => $c->session->{SiteName} || 'CSC',
            assigned_to => $c->session->{username} || 'system',
            comments => "Zenflow Task: $zenflow_task_id" . ($zenflow_step ? " - Step: $zenflow_step" : ""),
            metadata => encode_json($metadata),
        });
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'attach_to_plan', "Created todo ${\$todo->id} for Zenflow task $zenflow_task_id");
        
        $c->response->body(encode_json({
            success => 1,
            todo_id => $todo->id,
            message => "Task attached to planning system"
        }));
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'attach_to_plan', "Error: $_");
        $c->response->status(500);
        $c->response->body(encode_json({
            success => 0,
            error => "Failed to attach to planning system: $_"
        }));
    };
}

sub update_step :Path('/ai/planning/update_step') :Args(0) {
    my ($self, $c) = @_;
    
    $c->response->content_type('application/json');
    
    my $params = $c->req->params;
    my $zenflow_task_id = $params->{zenflow_task_id};
    my $zenflow_step = $params->{zenflow_step};
    my $status = $params->{status} || 'in_progress';
    my $notes = $params->{notes} || '';
    
    unless ($zenflow_task_id) {
        $c->response->status(400);
        $c->response->body(encode_json({
            success => 0,
            error => 'zenflow_task_id required'
        }));
        return;
    }
    
    try {
        my $schema = $c->model('DBEncy')->schema;
        
        my @todos = $schema->resultset('Todo')->search({
            comments => { 'like' => "%Zenflow Task: $zenflow_task_id%" }
        })->all;
        
        unless (@todos) {
            $c->response->status(404);
            $c->response->body(encode_json({
                success => 0,
                error => 'No planning entry found for this Zenflow task'
            }));
            return;
        }
        
        my $status_code = $status eq 'completed' ? 3 : ($status eq 'in_progress' ? 2 : 1);
        
        my @updated_todos;
        foreach my $todo (@todos) {
            my $new_comments = $todo->comments;
            if ($notes) {
                $new_comments .= "\n\nZenflow Update [" . DateTime->now->datetime . "]: " . $notes;
            }
            
            $todo->update({
                status => $status_code,
                comments => $new_comments,
            });
            
            push @updated_todos, $todo->id;
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'update_step', "Updated " . scalar(@updated_todos) . " todos for Zenflow task $zenflow_task_id");
        
        $c->response->body(encode_json({
            success => 1,
            updated_count => scalar(@updated_todos),
            todo_ids => \@updated_todos,
            message => "Planning entries updated"
        }));
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'update_step', "Error: $_");
        $c->response->status(500);
        $c->response->body(encode_json({
            success => 0,
            error => "Failed to update planning entries: $_"
        }));
    };
}

sub get_project_tasks :Path('/ai/planning/tasks') :Args(0) {
    my ($self, $c) = @_;
    
    $c->response->content_type('application/json');
    
    my $project_id = $c->req->params->{project_id};
    my $zenflow_task_id = $c->req->params->{zenflow_task_id};
    
    try {
        my $schema = $c->model('DBEncy')->schema;
        
        my %search = ();
        $search{project_id} = $project_id if $project_id;
        
        if ($zenflow_task_id) {
            $search{comments} = { 'like' => "%Zenflow Task: $zenflow_task_id%" };
        }
        
        my @todos = $schema->resultset('Todo')->search(
            \%search,
            { order_by => { -desc => 'created_at' } }
        )->all;
        
        my @tasks_data;
        foreach my $todo (@todos) {
            my $metadata = {};
            eval {
                $metadata = decode_json($todo->metadata || '{}');
            };
            
            push @tasks_data, {
                id => $todo->id,
                subject => $todo->subject,
                description => $todo->description,
                status => $todo->status,
                priority => $todo->priority,
                start_date => $todo->start_date,
                due_date => $todo->due_date,
                assigned_to => $todo->assigned_to,
                project_id => $todo->project_id,
                zenflow_task_id => $metadata->{zenflow_task_id},
                zenflow_step => $metadata->{zenflow_step},
            };
        }
        
        $c->response->body(encode_json({
            success => 1,
            tasks => \@tasks_data,
            count => scalar(@tasks_data)
        }));
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'get_project_tasks', "Error: $_");
        $c->response->status(500);
        $c->response->body(encode_json({
            success => 0,
            error => "Failed to retrieve tasks: $_"
        }));
    };
}

sub get_daily_plan :Path('/ai/planning/daily_plan') :Args(0) {
    my ($self, $c) = @_;
    
    $c->response->content_type('application/json');
    
    my $params = $c->req->params;
    my $plan_id = $params->{plan_id};
    my $plan_name = $params->{plan_name};
    my $sitename = $params->{sitename} || $c->session->{SiteName} || 'CSC';
    my $include_entries = $params->{include_entries};
    
    try {
        my $schema = $c->model('DBEncy')->schema;
        
        my %search = (sitename => $sitename);
        $search{id} = $plan_id if $plan_id;
        $search{plan_name} = $plan_name if $plan_name;
        
        my @plans = $schema->resultset('DailyPlan')->search(
            \%search,
            { order_by => { -desc => 'created_at' } }
        )->all;
        
        my @plans_data;
        foreach my $plan (@plans) {
            my $plan_data = {
                id => $plan->id,
                plan_name => $plan->plan_name,
                plan_description => $plan->plan_description,
                sitename => $plan->sitename,
                status => $plan->status,
                start_date => $plan->start_date,
                due_date => $plan->due_date,
                priority => $plan->priority,
                created_by => $plan->created_by,
                created_at => $plan->created_at->datetime,
            };
            
            if ($include_entries) {
                my @entries = $plan->entries->search(
                    {},
                    { order_by => ['entry_time', 'created_at'] }
                )->all;
                
                my @entries_data;
                foreach my $entry (@entries) {
                    push @entries_data, {
                        id => $entry->id,
                        entry_type => $entry->entry_type,
                        entry_time => $entry->entry_time,
                        title => $entry->title,
                        description => $entry->description,
                        zenflow_task_id => $entry->zenflow_task_id,
                        ai_conversation_id => $entry->ai_conversation_id,
                        status => $entry->status,
                        created_at => $entry->created_at->datetime,
                        created_by => $entry->created_by,
                        metadata => $entry->get_metadata,
                    };
                }
                $plan_data->{entries} = \@entries_data;
                $plan_data->{entry_count} = scalar(@entries_data);
            }
            
            push @plans_data, $plan_data;
        }
        
        $c->response->body(encode_json({
            success => 1,
            plans => \@plans_data,
            count => scalar(@plans_data)
        }));
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'get_daily_plan', "Error: $_");
        $c->response->status(500);
        $c->response->body(encode_json({
            success => 0,
            error => "Failed to retrieve daily plans: $_"
        }));
    };
}

sub create_plan_entry :Path('/ai/planning/daily_plan/entry') :Args(0) {
    my ($self, $c) = @_;
    
    $c->response->content_type('application/json');
    
    my $params = $c->req->params;
    my $plan_id = $params->{plan_id};
    my $entry_type = $params->{entry_type} || 'task';
    my $title = $params->{title};
    my $description = $params->{description};
    my $zenflow_task_id = $params->{zenflow_task_id};
    my $ai_conversation_id = $params->{ai_conversation_id};
    my $entry_time = $params->{entry_time};
    my $status = $params->{status} || 'pending';
    
    unless ($plan_id && $title) {
        $c->response->status(400);
        $c->response->body(encode_json({
            success => 0,
            error => 'plan_id and title required'
        }));
        return;
    }
    
    try {
        my $schema = $c->model('DBEncy')->schema;
        
        my $plan = $schema->resultset('DailyPlan')->find($plan_id);
        unless ($plan) {
            $c->response->status(404);
            $c->response->body(encode_json({
                success => 0,
                error => 'Daily plan not found'
            }));
            return;
        }
        
        my $metadata = {};
        if ($params->{metadata}) {
            eval {
                $metadata = decode_json($params->{metadata});
            };
        }
        
        my $entry = $schema->resultset('DailyPlanEntry')->create({
            plan_id => $plan_id,
            entry_type => $entry_type,
            entry_time => $entry_time,
            title => $title,
            description => $description,
            zenflow_task_id => $zenflow_task_id,
            ai_conversation_id => $ai_conversation_id,
            status => $status,
            created_by => $c->session->{username} || 'system',
            metadata => encode_json($metadata),
        });
        
        $entry->discard_changes;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'create_plan_entry', "Created entry ${\$entry->id} for plan $plan_id");
        
        $c->response->body(encode_json({
            success => 1,
            entry => {
                id => $entry->id,
                plan_id => $entry->plan_id,
                entry_type => $entry->entry_type,
                entry_time => $entry->entry_time,
                title => $entry->title,
                description => $entry->description,
                zenflow_task_id => $entry->zenflow_task_id,
                ai_conversation_id => $entry->ai_conversation_id,
                status => $entry->status,
                created_at => $entry->created_at ? $entry->created_at->datetime : undef,
                created_by => $entry->created_by,
            },
            message => "Daily plan entry created"
        }));
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'create_plan_entry', "Error: $_");
        $c->response->status(500);
        $c->response->body(encode_json({
            success => 0,
            error => "Failed to create entry: $_"
        }));
    };
}

sub update_plan_entry :Path('/ai/planning/daily_plan/entry') :Args(1) {
    my ($self, $c, $entry_id) = @_;
    
    return unless $c->req->method eq 'PUT' || $c->req->method eq 'POST';
    
    $c->response->content_type('application/json');
    
    my $params = $c->req->params;
    
    unless ($entry_id) {
        $c->response->status(400);
        $c->response->body(encode_json({
            success => 0,
            error => 'entry_id required'
        }));
        return;
    }
    
    try {
        my $schema = $c->model('DBEncy')->schema;
        
        my $entry = $schema->resultset('DailyPlanEntry')->find($entry_id);
        unless ($entry) {
            $c->response->status(404);
            $c->response->body(encode_json({
                success => 0,
                error => 'Entry not found'
            }));
            return;
        }
        
        my %update_data;
        $update_data{title} = $params->{title} if $params->{title};
        $update_data{description} = $params->{description} if defined $params->{description};
        $update_data{status} = $params->{status} if $params->{status};
        $update_data{entry_time} = $params->{entry_time} if $params->{entry_time};
        $update_data{entry_type} = $params->{entry_type} if $params->{entry_type};
        
        if ($params->{metadata}) {
            my $metadata = {};
            eval {
                $metadata = decode_json($params->{metadata});
            };
            $update_data{metadata} = encode_json($metadata) if keys %$metadata;
        }
        
        $entry->update(\%update_data);
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'update_plan_entry', "Updated entry $entry_id");
        
        $c->response->body(encode_json({
            success => 1,
            entry => {
                id => $entry->id,
                plan_id => $entry->plan_id,
                entry_type => $entry->entry_type,
                entry_time => $entry->entry_time,
                title => $entry->title,
                description => $entry->description,
                status => $entry->status,
            },
            message => "Entry updated"
        }));
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'update_plan_entry', "Error: $_");
        $c->response->status(500);
        $c->response->body(encode_json({
            success => 0,
            error => "Failed to update entry: $_"
        }));
    };
}

sub delete_plan_entry :Path('/ai/planning/daily_plan/entry') :Args(1) {
    my ($self, $c, $entry_id) = @_;
    
    return unless $c->req->method eq 'DELETE';
    
    $c->response->content_type('application/json');
    
    unless ($entry_id) {
        $c->response->status(400);
        $c->response->body(encode_json({
            success => 0,
            error => 'entry_id required'
        }));
        return;
    }
    
    try {
        my $schema = $c->model('DBEncy')->schema;
        
        my $entry = $schema->resultset('DailyPlanEntry')->find($entry_id);
        unless ($entry) {
            $c->response->status(404);
            $c->response->body(encode_json({
                success => 0,
                error => 'Entry not found'
            }));
            return;
        }
        
        $entry->delete;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'delete_plan_entry', "Deleted entry $entry_id");
        
        $c->response->body(encode_json({
            success => 1,
            message => "Entry deleted"
        }));
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'delete_plan_entry', "Error: $_");
        $c->response->status(500);
        $c->response->body(encode_json({
            success => 0,
            error => "Failed to delete entry: $_"
        }));
    };
}

sub get_plan_entries :Path('/ai/planning/daily_plan/entries') :Args(0) {
    my ($self, $c) = @_;
    
    $c->response->content_type('application/json');
    
    my $params = $c->req->params;
    my $plan_id = $params->{plan_id};
    my $zenflow_task_id = $params->{zenflow_task_id};
    my $ai_conversation_id = $params->{ai_conversation_id};
    
    try {
        my $schema = $c->model('DBEncy')->schema;
        
        my %search;
        $search{plan_id} = $plan_id if $plan_id;
        $search{zenflow_task_id} = $zenflow_task_id if $zenflow_task_id;
        $search{ai_conversation_id} = $ai_conversation_id if $ai_conversation_id;
        
        my @entries = $schema->resultset('DailyPlanEntry')->search(
            \%search,
            { order_by => ['entry_time', 'created_at'] }
        )->all;
        
        my @entries_data;
        foreach my $entry (@entries) {
            push @entries_data, {
                id => $entry->id,
                plan_id => $entry->plan_id,
                entry_type => $entry->entry_type,
                entry_time => $entry->entry_time,
                title => $entry->title,
                description => $entry->description,
                zenflow_task_id => $entry->zenflow_task_id,
                ai_conversation_id => $entry->ai_conversation_id,
                status => $entry->status,
                created_at => $entry->created_at->datetime,
                created_by => $entry->created_by,
                metadata => $entry->get_metadata,
            };
        }
        
        $c->response->body(encode_json({
            success => 1,
            entries => \@entries_data,
            count => scalar(@entries_data)
        }));
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'get_plan_entries', "Error: $_");
        $c->response->status(500);
        $c->response->body(encode_json({
            success => 0,
            error => "Failed to retrieve entries: $_"
        }));
    };
}

sub create_entry_from_conversation :Path('/ai/planning/daily_plan/entry/from_conversation') :Args(0) {
    my ($self, $c) = @_;
    
    $c->response->content_type('application/json');
    
    my $params = $c->req->params;
    my $conversation_id = $params->{conversation_id};
    my $plan_id = $params->{plan_id};
    my $title = $params->{title};
    my $description = $params->{description};
    my $zenflow_task_id = $params->{zenflow_task_id};
    
    unless ($conversation_id && $plan_id && $title) {
        $c->response->status(400);
        $c->response->body(encode_json({
            success => 0,
            error => 'conversation_id, plan_id, and title required'
        }));
        return;
    }
    
    try {
        my $schema = $c->model('DBEncy')->schema;
        
        my $conversation = $schema->resultset('AiConversation')->find($conversation_id);
        unless ($conversation) {
            $c->response->status(404);
            $c->response->body(encode_json({
                success => 0,
                error => 'Conversation not found'
            }));
            return;
        }
        
        my $plan = $schema->resultset('DailyPlan')->find($plan_id);
        unless ($plan) {
            $c->response->status(404);
            $c->response->body(encode_json({
                success => 0,
                error => 'Daily plan not found'
            }));
            return;
        }
        
        my $metadata = {
            source => 'ai_conversation',
            agent => $params->{agent_id} || 'unknown',
        };
        
        my $entry = $schema->resultset('DailyPlanEntry')->create({
            plan_id => $plan_id,
            entry_type => 'ai_action',
            title => $title,
            description => $description,
            zenflow_task_id => $zenflow_task_id,
            ai_conversation_id => $conversation_id,
            status => 'pending',
            created_by => $c->session->{username} || 'ai_system',
            metadata => encode_json($metadata),
        });
        
        $entry->discard_changes;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'create_entry_from_conversation', 
            "Created AI entry ${\$entry->id} linked to conversation $conversation_id");
        
        $c->response->body(encode_json({
            success => 1,
            entry => {
                id => $entry->id,
                plan_id => $entry->plan_id,
                entry_type => $entry->entry_type,
                title => $entry->title,
                description => $entry->description,
                ai_conversation_id => $entry->ai_conversation_id,
                status => $entry->status,
            },
            message => "AI-generated daily plan entry created"
        }));
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'create_entry_from_conversation', "Error: $_");
        $c->response->status(500);
        $c->response->body(encode_json({
            success => 0,
            error => "Failed to create entry: $_"
        }));
    };
}

sub get_conversation_entries :Path('/ai/planning/daily_plan/entries/by_conversation') :Args(1) {
    my ($self, $c, $conversation_id) = @_;
    
    $c->response->content_type('application/json');
    
    unless ($conversation_id) {
        $c->response->status(400);
        $c->response->body(encode_json({
            success => 0,
            error => 'conversation_id required'
        }));
        return;
    }
    
    try {
        my $schema = $c->model('DBEncy')->schema;
        
        my @entries = $schema->resultset('DailyPlanEntry')->search(
            { ai_conversation_id => $conversation_id },
            { order_by => ['created_at'] }
        )->all;
        
        my @entries_data;
        foreach my $entry (@entries) {
            push @entries_data, {
                id => $entry->id,
                plan_id => $entry->plan_id,
                entry_type => $entry->entry_type,
                title => $entry->title,
                description => $entry->description,
                status => $entry->status,
                created_at => $entry->created_at->datetime,
            };
        }
        
        $c->response->body(encode_json({
            success => 1,
            entries => \@entries_data,
            count => scalar(@entries_data),
            conversation_id => $conversation_id
        }));
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'get_conversation_entries', "Error: $_");
        $c->response->status(500);
        $c->response->body(encode_json({
            success => 0,
            error => "Failed to retrieve entries: $_"
        }));
    };
}

__PACKAGE__->meta->make_immutable;
1;
