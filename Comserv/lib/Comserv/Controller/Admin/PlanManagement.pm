package Comserv::Controller::Admin::PlanManagement;

use Moose;
use namespace::autoclean;
use JSON::MaybeXS;
use Try::Tiny;
use Data::Dumper;
use DateTime;
use Comserv::Util::Logging;

BEGIN { extends 'Comserv::Controller::Base'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub begin :Private {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'begin', 
        "User accessing path: " . $c->req->uri);
    
    my $roles = $c->session->{roles} || [];
    
    if (ref $roles ne 'ARRAY') {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'begin', 
            "Invalid or undefined roles in session for user: " . ($c->session->{username} || 'Guest'));
        $c->stash->{error_msg} = "Session expired or invalid. Please log in again.";
        $c->res->redirect($c->uri_for('/user/login'));
        $c->detach;
    }
    
    unless (grep { lc($_) eq 'admin' || lc($_) eq 'developer' } @$roles) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'begin', 
            "Unauthorized access attempt by user: " . ($c->session->{username} || 'Guest'));
        $c->stash->{error_msg} = "Unauthorized access. You do not have permission to view this page.";
        $c->res->redirect($c->uri_for('/'));
        $c->detach;
    }

    # Store SiteName-based visibility context in stash:
    # CSC admins can see all sites; non-CSC admins/developers only see their own site.
    my $session_sitename = $c->session->{SiteName} || 'CSC';
    my $is_csc_admin = (uc($session_sitename) eq 'CSC') && (grep { lc($_) eq 'admin' } @$roles);
    $c->stash->{plan_sitename}   = $session_sitename;
    $c->stash->{is_csc_admin}    = $is_csc_admin;

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'begin', 
        "User authorized to access PlanManagement: " . ($c->session->{username} || 'Guest')
        . " site=$session_sitename is_csc_admin=" . ($is_csc_admin ? 1 : 0));
}

sub list :Path('/admin/plan/list') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list', 
        'Fetching all plans');
    
    try {
        my $schema = $c->model('DBEncy');
        my $rs = $schema->resultset('DailyPlan');

        # CSC admins can view all sites (with optional filter); others only see their own site.
        my $is_csc_admin  = $c->stash->{is_csc_admin};
        my $sitename      = $c->stash->{plan_sitename} || $c->session->{SiteName} || 'CSC';
        my $filter_site   = $c->req->param('sitename');  # optional filter for CSC admin

        my %search_cond;
        if ($is_csc_admin && $filter_site) {
            %search_cond = (sitename => $filter_site);
        } elsif (!$is_csc_admin) {
            %search_cond = (sitename => $sitename);
        }
        # CSC admin with no filter sees all plans (empty search condition)

        my @plans = $rs->search(
            \%search_cond,
            { order_by => { -desc => 'created_at' } }
        );
        
        my @plan_data;
        foreach my $plan (@plans) {
            my %plan_hash = $plan->get_columns;
            $plan_hash{progress_percentage} = $plan->get_progress_percentage;
            $plan_hash{todo_count} = $plan->get_todo_count;
            $plan_hash{completed_todo_count} = $plan->get_completed_todo_count;
            $plan_hash{is_overdue} = $plan->is_overdue;
            push @plan_data, \%plan_hash;
        }
        
        if ($c->req->header('Accept') && $c->req->header('Accept') =~ /application\/json/) {
            $c->stash->{json} = { 
                success => 1, 
                plans => \@plan_data 
            };
            $c->forward('View::JSON');
        } else {
            $c->stash(
                plans        => \@plan_data,
                is_csc_admin => $c->stash->{is_csc_admin},
                plan_sitename => $c->stash->{plan_sitename},
                filter_site  => $filter_site,
                template     => 'admin/documentation/DailyPlan.tt'
            );
            $c->forward($c->view('TT'));
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'list', 
            "Error fetching plans: $_");
        $self->stash_message($c, "Error fetching plans: $_");
        $c->stash->{json} = { success => 0, error => "Error fetching plans: $_" };
        $c->forward('View::JSON');
    };
}

sub details :Path('/admin/plan') :Args(1) {
    my ($self, $c, $plan_id) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'details', 
        "Fetching plan details for ID: $plan_id");
    
    try {
        my $schema = $c->model('DBEncy');
        my $plan = $schema->resultset('DailyPlan')->find($plan_id);
        
        unless ($plan) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'details', 
                "Plan not found: $plan_id");
            $c->stash->{json} = { success => 0, error => "Plan not found" };
            $c->forward('View::JSON');
            $c->detach;
        }

        # Enforce SiteName-based access: non-CSC users cannot view other sites' plans
        unless ($c->stash->{is_csc_admin}) {
            my $user_site = $c->stash->{plan_sitename} || $c->session->{SiteName} || 'CSC';
            if ($plan->sitename ne $user_site) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'details',
                    "Access denied: plan site " . $plan->sitename . " != user site $user_site");
                $c->stash->{json} = { success => 0, error => "Access denied" };
                $c->forward('View::JSON');
                $c->detach;
            }
        }

        my %plan_data = $plan->get_columns;
        $plan_data{progress_percentage} = $plan->get_progress_percentage;
        
        my @projects;
        foreach my $dp_project ($plan->dailyplan_projects->all) {
            my $project = $dp_project->project;
            my %project_data = $project->get_columns;
            
            my @sub_projects;
            foreach my $sub_project ($project->sub_projects->all) {
                my %sub_data = $sub_project->get_columns;
                
                my @todos;
                foreach my $todo ($sub_project->todos->all) {
                    my %todo_data = $todo->get_columns;
                    push @todos, \%todo_data;
                }
                $sub_data{todos} = \@todos;
                push @sub_projects, \%sub_data;
            }
            
            $project_data{sub_projects} = \@sub_projects;
            
            my @direct_todos;
            foreach my $todo ($project->todos->all) {
                my %todo_data = $todo->get_columns;
                push @direct_todos, \%todo_data;
            }
            $project_data{todos} = \@direct_todos;
            
            push @projects, \%project_data;
        }
        
        $plan_data{projects} = \@projects;
        
        $c->stash->{json} = { 
            success => 1, 
            plan => \%plan_data 
        };
        $c->forward('View::JSON');
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'details', 
            "Error fetching plan details: $_");
        $c->stash->{json} = { success => 0, error => "Error fetching plan: $_" };
        $c->forward('View::JSON');
    };
}

sub create :Path('/admin/plan/create') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create', 
        'Creating new plan');
    
    try {
        my $params = $c->req->body_parameters;
        my $plan_name = $params->{plan_name};
        my $plan_description = $params->{plan_description};
        my $start_date = $params->{start_date};
        my $due_date = $params->{due_date};
        my $priority = $params->{priority} || 0;
        my $status = $params->{status} || 'active';
        
        unless ($plan_name) {
            $c->stash->{json} = { success => 0, error => "Plan name is required" };
            $c->forward('View::JSON');
            $c->detach;
        }
        
        my $schema = $c->model('DBEncy');
        my $plan = $schema->resultset('DailyPlan')->create({
            plan_name => $plan_name,
            plan_description => $plan_description,
            sitename => $c->session->{SiteName},
            status => $status,
            start_date => $start_date,
            due_date => $due_date,
            priority => $priority,
            created_by => $c->session->{username} || 'unknown',
        });
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create', 
            "Plan created successfully: " . $plan->id);
        
        $c->stash->{json} = { 
            success => 1, 
            plan_id => $plan->id,
            message => "Plan created successfully"
        };
        $c->forward('View::JSON');
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create', 
            "Error creating plan: $_");
        $c->stash->{json} = { success => 0, error => "Error creating plan: $_" };
        $c->forward('View::JSON');
    };
}

sub update :Path('/admin/plan') :Args(1) {
    my ($self, $c, $plan_id) = @_;
    
    return unless $c->req->method eq 'PUT';
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update', 
        "Updating plan: $plan_id");
    
    try {
        my $schema = $c->model('DBEncy');
        my $plan = $schema->resultset('DailyPlan')->find($plan_id);
        
        unless ($plan) {
            $c->stash->{json} = { success => 0, error => "Plan not found" };
            $c->forward('View::JSON');
            $c->detach;
        }
        
        my $params = $c->req->body_parameters;
        
        my %update_data;
        $update_data{plan_name} = $params->{plan_name} if defined $params->{plan_name};
        $update_data{plan_description} = $params->{plan_description} if defined $params->{plan_description};
        $update_data{status} = $params->{status} if defined $params->{status};
        $update_data{start_date} = $params->{start_date} if defined $params->{start_date};
        $update_data{due_date} = $params->{due_date} if defined $params->{due_date};
        $update_data{priority} = $params->{priority} if defined $params->{priority};
        
        $plan->update(\%update_data);
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update', 
            "Plan updated successfully: $plan_id");
        
        $c->stash->{json} = { 
            success => 1,
            message => "Plan updated successfully"
        };
        $c->forward('View::JSON');
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update', 
            "Error updating plan: $_");
        $c->stash->{json} = { success => 0, error => "Error updating plan: $_" };
        $c->forward('View::JSON');
    };
}

sub delete :Path('/admin/plan') :Args(1) {
    my ($self, $c, $plan_id) = @_;
    
    return unless $c->req->method eq 'DELETE';
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete', 
        "Deleting plan: $plan_id");
    
    try {
        my $schema = $c->model('DBEncy');
        my $plan = $schema->resultset('DailyPlan')->find($plan_id);
        
        unless ($plan) {
            $c->stash->{json} = { success => 0, error => "Plan not found" };
            $c->forward('View::JSON');
            $c->detach;
        }
        
        $plan->delete;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete', 
            "Plan deleted successfully: $plan_id");
        
        $c->stash->{json} = { 
            success => 1,
            message => "Plan deleted successfully"
        };
        $c->forward('View::JSON');
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'delete', 
            "Error deleting plan: $_");
        $c->stash->{json} = { success => 0, error => "Error deleting plan: $_" };
        $c->forward('View::JSON');
    };
}

sub add_project :Path('/admin/plan') :Args(2) {
    my ($self, $c, $plan_id, $action) = @_;
    
    return unless $action eq 'project' && $c->req->method eq 'POST';
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_project', 
        "Adding project to plan: $plan_id");
    
    try {
        my $params = $c->req->body_parameters;
        my $project_id = $params->{project_id};
        
        unless ($project_id) {
            $c->stash->{json} = { success => 0, error => "Project ID is required" };
            $c->forward('View::JSON');
            $c->detach;
        }
        
        my $schema = $c->model('DBEncy');
        my $plan = $schema->resultset('DailyPlan')->find($plan_id);
        
        unless ($plan) {
            $c->stash->{json} = { success => 0, error => "Plan not found" };
            $c->forward('View::JSON');
            $c->detach;
        }
        
        my $project = $schema->resultset('Project')->find($project_id);
        
        unless ($project) {
            $c->stash->{json} = { success => 0, error => "Project not found" };
            $c->forward('View::JSON');
            $c->detach;
        }
        
        my $existing = $schema->resultset('DailyPlanProject')->search({
            plan_id => $plan_id,
            project_id => $project_id,
        })->first;
        
        if ($existing) {
            $c->stash->{json} = { 
                success => 0, 
                error => "Project already added to this plan" 
            };
            $c->forward('View::JSON');
            $c->detach;
        }
        
        my $dp_project = $schema->resultset('DailyPlanProject')->create({
            plan_id => $plan_id,
            project_id => $project_id,
        });
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_project', 
            "Project added to plan successfully");
        
        $c->stash->{json} = { 
            success => 1,
            message => "Project added to plan successfully"
        };
        $c->forward('View::JSON');
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_project', 
            "Error adding project to plan: $_");
        $c->stash->{json} = { success => 0, error => "Error adding project: $_" };
        $c->forward('View::JSON');
    };
}

sub update_project_status :Path('/admin/plan/project') :Args(2) {
    my ($self, $c, $project_id, $action) = @_;
    
    return unless $action eq 'status' && $c->req->method eq 'PUT';
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_project_status', 
        "Updating project status: $project_id");
    
    try {
        my $params = $c->req->body_parameters;
        my $status = $params->{status};
        
        unless ($status) {
            $c->stash->{json} = { success => 0, error => "Status is required" };
            $c->forward('View::JSON');
            $c->detach;
        }
        
        my $schema = $c->model('DBEncy');
        my $project = $schema->resultset('Project')->find($project_id);
        
        unless ($project) {
            $c->stash->{json} = { success => 0, error => "Project not found" };
            $c->forward('View::JSON');
            $c->detach;
        }
        
        $project->update({ status => $status });
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_project_status', 
            "Project status updated successfully");
        
        $c->stash->{json} = { 
            success => 1,
            message => "Project status updated successfully"
        };
        $c->forward('View::JSON');
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_project_status', 
            "Error updating project status: $_");
        $c->stash->{json} = { success => 0, error => "Error updating status: $_" };
        $c->forward('View::JSON');
    };
}

sub add_todo :Path('/admin/plan/project') :Args(2) {
    my ($self, $c, $project_id, $action) = @_;
    
    return unless $action eq 'todo' && $c->req->method eq 'POST';
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_todo', 
        "Adding todo to project: $project_id");
    
    try {
        my $params = $c->req->body_parameters;
        my $subject = $params->{subject};
        my $description = $params->{description};
        my $plan_id = $params->{plan_id};
        
        unless ($subject) {
            $c->stash->{json} = { success => 0, error => "Subject is required" };
            $c->forward('View::JSON');
            $c->detach;
        }
        
        my $schema = $c->model('DBEncy');
        my $project = $schema->resultset('Project')->find($project_id);
        
        unless ($project) {
            $c->stash->{json} = { success => 0, error => "Project not found" };
            $c->forward('View::JSON');
            $c->detach;
        }
        
        my %status_map = ( 1 => 'NEW', 2 => 'IN PROGRESS', 3 => 'DONE' );
        my $status_value = $params->{status} || 'NEW';
        $status_value = $status_map{$status_value} if exists $status_map{$status_value};
        
        my $current_user = $c->session->{username} || 'system';
        my $current_date = DateTime->now->ymd;
        
        my $todo = $schema->resultset('Todo')->create({
            subject => $subject,
            description => $description || '',
            project_id => $project_id,
            plan_id => $plan_id,
            sitename => $c->session->{SiteName},
            status => $status_value,
            priority => $params->{priority} || 5,
            start_date => $params->{start_date} || $current_date,
            due_date => $params->{due_date},
            project_code => $project->project_code || 'default',
            username_of_poster => $current_user,
            last_mod_by => $current_user,
            last_mod_date => $current_date,
            user_id => $c->session->{user_id},
            reporter => $current_user,
            owner => $current_user,
            developer => $current_user,
            group_of_poster => (ref $c->session->{roles} eq 'ARRAY' && @{$c->session->{roles}}) 
                              ? $c->session->{roles}->[0] 
                              : 'user',
        });
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_todo', 
            "Todo added to project successfully");
        
        $c->stash->{json} = { 
            success => 1,
            todo_id => $todo->record_id,
            message => "Todo added successfully"
        };
        $c->forward('View::JSON');
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_todo', 
            "Error adding todo: $_");
        $c->stash->{json} = { success => 0, error => "Error adding todo: $_" };
        $c->forward('View::JSON');
    };
}

__PACKAGE__->meta->make_immutable;

1;
