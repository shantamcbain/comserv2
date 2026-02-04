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

sub create_daily_plan_entry :Path('/ai/planning/daily_plan') :Args(0) {
    my ($self, $c) = @_;
    
    $c->response->content_type('application/json');
    
    my $params = $c->req->params;
    my $date = $params->{date} || DateTime->now->ymd;
    my $task_description = $params->{task_description};
    my $zenflow_task_id = $params->{zenflow_task_id};
    
    unless ($task_description) {
        $c->response->status(400);
        $c->response->body(encode_json({
            success => 0,
            error => 'task_description required'
        }));
        return;
    }
    
    try {
        my $schema = $c->model('DBEncy')->schema;
        
        my $daily_plan = $schema->resultset('DailyPlan')->find_or_create({
            date => $date,
            user_id => $c->session->{user_id} || 1,
        });
        
        my $current_notes = $daily_plan->notes || '';
        my $new_entry = "\n\n[" . DateTime->now->hms . "] ";
        $new_entry .= "(Zenflow: $zenflow_task_id) " if $zenflow_task_id;
        $new_entry .= $task_description;
        
        $daily_plan->update({
            notes => $current_notes . $new_entry
        });
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'create_daily_plan_entry', "Added entry to daily plan for $date");
        
        $c->response->body(encode_json({
            success => 1,
            daily_plan_id => $daily_plan->id,
            date => $date,
            message => "Entry added to daily plan"
        }));
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'create_daily_plan_entry', "Error: $_");
        $c->response->status(500);
        $c->response->body(encode_json({
            success => 0,
            error => "Failed to create daily plan entry: $_"
        }));
    };
}

__PACKAGE__->meta->make_immutable;
1;
