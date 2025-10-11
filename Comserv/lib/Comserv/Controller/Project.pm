package Comserv::Controller::Project;
use Moose;
use namespace::autoclean;
use DateTime;
use Data::Dumper;
use Comserv::Util::Logging;
BEGIN { extends 'Catalyst::Controller'; }
has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);
sub index :Path :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 'Starting index action');
    $c->res->redirect($c->uri_for($self->action_for('project')));
}

sub add_project :Path('addproject') :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_project', 'Starting add_project action' );
    $c->session->{previous_url} = $c->req->referer;

    my $project_model = $c->model('Project');
    my $projects = $project_model->get_projects($c->model('DBEncy'), $c->session->{SiteName});

    # Sort projects alphabetically by name
    my @sorted_projects = sort { $a->{name} cmp $b->{name} } @$projects;
    
    Comserv::Util::Logging->instance->log_with_details($c, 'debug', __FILE__, __LINE__, 'add_project', Dumper(\@sorted_projects));

    $c->stash->{projects} = \@sorted_projects;

    my $site_model = $c->model('Site');
    my $sites;

    # Fetch sites based on the current site name
    if (lc($c->session->{SiteName}) eq 'csc') {
        $sites = $site_model->get_all_sites();
    } else {
        my $site = $site_model->get_site_details_by_name($c->session->{SiteName});
        $sites = [$site] if $site;
    }

    $c->stash->{sites} = $sites;

    $c->stash(
        template => 'todo/add_project.tt'
    );

    $c->forward($c->view('TT'));
}


sub create_project :Path('create_project') :Args(0) {
    my ( $self, $c ) = @_;
    print Dumper($c->session);
    my $form_data = $c->request->body_parameters;
    my $username_of_poster = $c->session->{username};
    my $schema = $c->model('DBEncy');
    my $project_rs = $schema->resultset('Project');
    my $group_of_poster = $c->session->{roles};
    my $parent_id = $form_data->{parent_id};
    $parent_id = undef if $parent_id eq '';
    my $date_time_posted = DateTime->now;
    my $record_id = $form_data->{record_id} || 0;

    my $project = eval {
        $project_rs->create({
            record_id => $record_id,
            sitename => $form_data->{sitename},
            name => $form_data->{name},
            description => $form_data->{description},
            start_date => $form_data->{start_date},
            end_date => $form_data->{end_date},
            status => $form_data->{status},
            project_code => $form_data->{project_code},
            project_size => $form_data->{project_size},
            estimated_man_hours => $form_data->{estimated_man_hours},
            developer_name => $form_data->{developer_name},
            client_name => $form_data->{client_name},
            comments => $form_data->{comments},
            username_of_poster => $username_of_poster,
            parent_id => $parent_id,
            group_of_poster => $group_of_poster,
            date_time_posted => $date_time_posted->ymd . ' ' . $date_time_posted->hms,
        });
    };
    if ($@) {
        # Ensure the correct template is set for error handling
        $c->stash(
            form_data => $form_data,
            error_message => 'There was an error creating the project: ' . $@,
            template => 'todo/add_project.tt'  # Ensure this template exists
        );
        $c->forward($c->view('TT'));
    } else {
        # Redirect to the previous URL on success
        $c->stash(
            success_message => 'Project added successfully',
        );
        $c->res->redirect($c->session->{previous_url});
    }
}


sub project :Path('project') :Args(0) {
    my ( $self, $c ) = @_;

    # Log the start of the project action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'project', 'Starting project action');

    # Get filter parameters from query string
    my $role_filter = $c->request->query_parameters->{role} || '';
    my $project_filter = $c->request->query_parameters->{project_id} || '';
    my $priority_filter = $c->request->query_parameters->{priority} || '';

    # Log the filter parameters
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'project',
        "Filter parameters - Role: $role_filter, Project: $project_filter, Priority: $priority_filter");

    # Use the existing method to fetch projects with sub-projects
    my $projects = $self->fetch_projects_with_subprojects($c);

    # Enhance project data with additional fields needed for filtering
    $projects = $self->enhance_project_data($c, $projects);

    # Calculate project summaries for each project in the tree
    $projects = $self->calculate_project_summaries($c, $projects);

    # Calculate overall summary for all projects
    my $overall_summary = $self->calculate_overall_summary($c);

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'project',
        "Overall summary calculated - Projects: $overall_summary->{total_projects}, " .
        "Todos: $overall_summary->{total_todos}, Time: $overall_summary->{total_accumulated_time}");

    # Add the projects and filter info to the stash
    $c->stash(
        projects => $projects,
        role_filter => $role_filter,
        project_filter => $project_filter,
        priority_filter => $priority_filter,
        build_priority => $self->build_priority,  # Priority mapping for display
        overall_summary => $overall_summary,  # Add overall summary data
        template => 'todo/project.tt', # Use the original template
        template_timestamp => time(), # Add a timestamp to force template reload
        success_message => 'Project priority display has been updated. All projects without a priority are now shown as Medium priority.',
        additional_css => ['/static/css/components/project-cards.css?v=' . time()], # Add timestamp to force CSS reload
        use_fluid_container => 1, # Use fluid container for better card layout
        debug_mode => 1 # Enable debug mode to see template version
    );

    # Log that we're using the project cards CSS
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'project',
        "Loading bootstrap cards CSS and project cards CSS with timestamp: " . time());

    # Log completion of the project action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'project', 'Completed project action');

    $c->forward($c->view('TT'));
}

sub details :Path('details') :Args(0) {
    my ( $self, $c ) = @_;
    my $schema = $c->model('DBEncy');
    my $project_id = $c->request->body_parameters->{project_id};
    my $project_model = $c->model('Project');
    my $project = $project_model->get_project($schema, $project_id);

    # Fetch todos associated with the project
    my @todos = $schema->resultset('Todo')->search(
        { project_id => $project_id },
        { order_by => { -asc => 'start_date' } }
    );

    # Add the project and todos to the stash
    $c->stash(
        project => $project,
        todos => \@todos,
        template => 'todo/projectdetails.tt'
    );

    $c->forward($c->view('TT'));
}



sub editproject :Path('editproject') :Args(0) {
    my ( $self, $c ) = @_;

    my $project_id = $c->request->body_parameters->{project_id};
    my $project_model = $c->model('Project');
    my $project = $project_model->get_project($c->model('DBEncy'), $project_id);
    my $projects = $project_model->get_projects($c->model('DBEncy'), $c->session->{SiteName});

    $c->stash->{projects} = $projects;
    $c->stash->{project} = $project;

    $c->stash(
        template => 'todo/editproject.tt'
    );

    $c->forward($c->view('TT'));
}

sub update_project :Local :Args(0)  {
    my ( $self, $c ) = @_;
    my $form_data = $c->request->body_parameters;
    my $project_id = $form_data->{project_id};
    my $schema = $c->model('DBEncy');
    my $project_rs = $schema->resultset('Project');
    my $project = $project_rs->find($project_id);

    if ($project) {
        $project->update({
            sitename => $form_data->{sitename},
            name => $form_data->{name},
            description => $form_data->{description},
            start_date => $form_data->{start_date},
            end_date => $form_data->{end_date},
            status => $form_data->{status},
            project_code => $form_data->{project_code},
            project_size => $form_data->{project_size},
            estimated_man_hours => $form_data->{estimated_man_hours},
            developer_name => $form_data->{developer_name},
            client_name => $form_data->{client_name},
            comments => $form_data->{comments},
        });

        $c->res->redirect($c->uri_for($self->action_for('project')));
    } else {
        $c->response->status(404);
        $c->response->body('Project not found');
    }
}

sub calculate_project_summaries {
    my ($self, $c, $projects) = @_;

    foreach my $project (@$projects) {
        # Calculate summary for this project including subprojects
        my $project_summary = $self->calculate_project_summary($c, $project->{id}, 1);
        $project->{summary} = $project_summary;

        # Calculate summaries for subprojects
        if ($project->{sub_projects} && @{$project->{sub_projects}}) {
            $self->calculate_project_summaries($c, $project->{sub_projects});
        }
    }

    return $projects;
}

# Method to calculate project summary data (todo count and accumulated time)
sub calculate_project_summary {
    my ($self, $c, $project_id, $include_subprojects) = @_;

    my $schema = $c->model('DBEncy');
    my $project = $schema->resultset('Project')->find($project_id);
    my @project_codes = ($project->project_code);

    # If including subprojects, get their project codes too
    if ($include_subprojects) {
        my $subprojects = $schema->resultset('Project')->search(
            { parent_id => $project_id },
            { order_by => { -asc => 'name' } }
        );

        while (my $subproject = $subprojects->next) {
            push @project_codes, $subproject->project_code if $subproject->project_code;

            # Recursively include sub-subprojects (but avoid infinite recursion)
            my $sub_subprojects = $schema->resultset('Project')->search(
                { parent_id => $subproject->id },
                { order_by => { -asc => 'name' } }
            );

            while (my $sub_subproject = $sub_subprojects->next) {
                push @project_codes, $sub_subproject->project_code if $sub_subproject->project_code;
            }
        }
    }

    # Calculate summary data
    my $total_todos = 0;
    my $total_seconds = 0;

    foreach my $project_code (@project_codes) {
        next unless $project_code;

        # Count todos for this project code
        my $todo_count = $schema->resultset('Todo')->search({
            project_code => $project_code,
            sitename => $c->session->{SiteName} || ''
        })->count;

        $total_todos += $todo_count;

        # Sum accumulated time for todos in this project
        my $todos = $schema->resultset('Todo')->search({
            project_code => $project_code,
            sitename => $c->session->{SiteName} || '',
            accumulative_time => { '!=' => undef }
        });

        while (my $todo = $todos->next) {
            if ($todo->accumulative_time) {
                # Parse time format HH:MM:SS
                my $time_str = $todo->accumulative_time;
                if ($time_str =~ /^(\d+):(\d+):(\d+)$/) {
                    my ($hours, $minutes, $seconds) = ($1, $2, $3);
                    $total_seconds += ($hours * 3600) + ($minutes * 60) + $seconds;
                }
            }
        }
    }

    # Also search by project_id if we have project IDs available and no todos were found by project_code
    if ($total_todos == 0 && scalar @project_codes > 0) {
        my @project_ids = ($project_id);

        # Add subproject IDs if including subprojects
        if ($include_subprojects) {
            my $subprojects = $schema->resultset('Project')->search(
                { parent_id => $project_id },
                { order_by => { -asc => 'name' } }
            );

            while (my $subproject = $subprojects->next) {
                push @project_ids, $subproject->id;

                # Recursively include sub-subprojects
                my $sub_subprojects = $schema->resultset('Project')->search(
                    { parent_id => $subproject->id },
                    { order_by => { -asc => 'name' } }
                );

                while (my $sub_subproject = $sub_subprojects->next) {
                    push @project_ids, $sub_subproject->id;
                }
            }
        }

        foreach my $pid (@project_ids) {
            # Count todos for this project_id
            my $todo_count = $schema->resultset('Todo')->search({
                project_id => $pid,
                sitename => $c->session->{SiteName} || ''
            })->count;

            $total_todos += $todo_count;

            # Sum accumulated time for todos in this project
            my $todos = $schema->resultset('Todo')->search({
                project_id => $pid,
                sitename => $c->session->{SiteName} || '',
                accumulative_time => { '!=' => undef }
            });

            while (my $todo = $todos->next) {
                if ($todo->accumulative_time) {
                    # Parse time format HH:MM:SS
                    my $time_str = $todo->accumulative_time;
                    if ($time_str =~ /^(\d+):(\d+):(\d+)$/) {
                        my ($hours, $minutes, $seconds) = ($1, $2, $3);
                        $total_seconds += ($hours * 3600) + ($minutes * 60) + $seconds;
                    }
                }
            }
        }
    }

    # Convert total seconds back to HH:MM:SS format
    my $hours = int($total_seconds / 3600);
    my $minutes = int(($total_seconds % 3600) / 60);
    my $seconds = $total_seconds % 60;
    my $formatted_time = sprintf("%02d:%02d:%02d", $hours, $minutes, $seconds);

    return {
        project_id => $project_id,
        project_name => $project->name,
        todo_count => $total_todos,
        accumulated_time => $formatted_time,
        accumulated_seconds => $total_seconds
    };
}

# Method to calculate overall summary for all projects
sub calculate_overall_summary {
    my ($self, $c) = @_;

    my $schema = $c->model('DBEncy');
    my $SiteName = $c->session->{SiteName} || '';

    # Get all top-level projects
    my @top_projects = $schema->resultset('Project')->search(
        {
            'sitename' => $SiteName,
            'parent_id' => undef
        },
        {
            order_by => { -asc => 'name' }
        }
    )->all;

    my $total_projects = 0;
    my $total_todos = 0;
    my $total_seconds = 0;

    # Process each top-level project and its subprojects
    foreach my $project (@top_projects) {
        $total_projects++;

        my $project_summary = $self->calculate_project_summary($c, $project->id, 1); # Include subprojects

        $total_todos += $project_summary->{todo_count};
        $total_seconds += $project_summary->{accumulated_seconds};

        # Count subprojects recursively
        my $subproject_count = $self->count_subprojects_recursive($c, $project->id);
        $total_projects += $subproject_count;
    }

    # Convert total seconds back to HH:MM:SS format
    my $hours = int($total_seconds / 3600);
    my $minutes = int(($total_seconds % 3600) / 60);
    my $seconds = $total_seconds % 60;
    my $formatted_time = sprintf("%02d:%02d:%02d", $hours, $minutes, $seconds);

    return {
        total_projects => $total_projects,
        total_todos => $total_todos,
        total_accumulated_time => $formatted_time,
        total_accumulated_seconds => $total_seconds
    };
}

# Helper method to count subprojects recursively
sub count_subprojects_recursive {
    my ($self, $c, $project_id) = @_;

    my $schema = $c->model('DBEncy');

    my @subprojects = $schema->resultset('Project')->search(
        { parent_id => $project_id }
    )->all;

    my $count = scalar @subprojects;

    # Recursively count sub-subprojects
    foreach my $subproject (@subprojects) {
        $count += $self->count_subprojects_recursive($c, $subproject->id);
    }

    return $count;
}

sub fetch_projects_with_subprojects {
    my ($self, $c) = @_;
    # Log the start of the project-fetching subroutine
    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'fetch_projects_with_subprojects',
        'Fetching parent projects with sub-projects'
    );

    # Get the schema and SiteName
    my $schema = $c->model('DBEncy');
    my $SiteName = $c->session->{SiteName} || '';

    # Check if SiteName is defined
    if (!$SiteName) {
        $self->logging->log_with_details(
            $c, 'warn', __FILE__, __LINE__, 'fetch_projects_with_subprojects',
            'SiteName is not defined in session, using empty string'
        );
    }

    # Fetch top-level projects (those without a parent)
    my @top_projects;
    eval {
        @top_projects = $schema->resultset('Project')->search(
            {
                'sitename' => $SiteName,
                'parent_id' => undef
            },
            {
                order_by => { -asc => 'name' }
            }
        )->all;
    };

    if ($@) {
        $self->logging->log_with_details(
            $c, 'error', __FILE__, __LINE__, 'fetch_projects_with_subprojects',
            "Error fetching top-level projects: $@"
        );
        return [];
    }

    # Create an array to hold our project structure
    my @projects = ();

    # Process each top-level project
    foreach my $project (@top_projects) {
        # Create a hashref for this project
        my $project_hash = {
            id => $project->id,
            name => $project->name,
            parent_id => $project->parent_id,
            status => $project->status || 1, # Default to 'New' status
            start_date => $project->start_date,
            end_date => $project->end_date,
            developer_name => $project->developer_name || '',
            client_name => $project->client_name || '',
            priority => 2, # Default to medium priority since field doesn't exist
            sub_projects => []
        };

        # Fetch first-level sub-projects
        my @level1_subprojects;
        eval {
            @level1_subprojects = $schema->resultset('Project')->search(
                { parent_id => $project->id },
                { order_by => { -asc => 'name' } }
            )->all;
        };

        if ($@) {
            $self->logging->log_with_details(
                $c, 'error', __FILE__, __LINE__, 'fetch_projects_with_subprojects',
                "Error fetching level 1 sub-projects for project ID " . $project->id . ": $@"
            );
            next;
        }

        # Process first-level sub-projects
        foreach my $subproject1 (@level1_subprojects) {
            my $subproject1_hash = {
                id => $subproject1->id,
                name => $subproject1->name,
                parent_id => $subproject1->parent_id,
                status => $subproject1->status || 1, # Default to 'New' status
                start_date => $subproject1->start_date,
                end_date => $subproject1->end_date,
                developer_name => $subproject1->developer_name || '',
                client_name => $subproject1->client_name || '',
                priority => 2, # Default to medium priority since field doesn't exist
                sub_projects => []
            };

            # Fetch second-level sub-projects
            my @level2_subprojects;
            eval {
                @level2_subprojects = $schema->resultset('Project')->search(
                    { parent_id => $subproject1->id },
                    { order_by => { -asc => 'name' } }
                )->all;
            };

            if ($@) {
                $self->logging->log_with_details(
                    $c, 'error', __FILE__, __LINE__, 'fetch_projects_with_subprojects',
                    "Error fetching level 2 sub-projects for project ID " . $subproject1->id . ": $@"
                );
                next;
            }

            # Process second-level sub-projects
            foreach my $subproject2 (@level2_subprojects) {
                push @{$subproject1_hash->{sub_projects}}, {
                    id => $subproject2->id,
                    name => $subproject2->name,
                    parent_id => $subproject2->parent_id,
                    status => $subproject2->status || 1, # Default to 'New' status
                    start_date => $subproject2->start_date,
                    end_date => $subproject2->end_date,
                    developer_name => $subproject2->developer_name || '',
                    client_name => $subproject2->client_name || '',
                    priority => 2, # Default to medium priority since field doesn't exist
                    sub_projects => [] # Empty array, we don't go deeper
                };
            }

            push @{$project_hash->{sub_projects}}, $subproject1_hash;
        }

        push @projects, $project_hash;
    }

    # Log the successful preparation of the project data structure
    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'fetch_projects_with_subprojects',
        'Successfully prepared project data structure with ' . scalar(@projects) . ' top-level projects'
    );

    return \@projects;
}

# Enhance project data with additional fields needed for filtering
sub enhance_project_data :Private {
    my ($self, $c, $projects) = @_;

    # Log the start of the enhance_project_data method
    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'enhance_project_data',
        'Enhancing project data for filtering'
    );

    # Process each project to ensure it has all required fields
    foreach my $project (@$projects) {
        # Set default values for any missing fields
        $project->{priority} = $project->{priority} || 2; # Default to medium priority
        $project->{status} = $project->{status} || 1; # Default to new status
        $project->{developer_name} = $project->{developer_name} || '';
        $project->{client_name} = $project->{client_name} || '';

        # Fetch todos for this project using the Todo model
        $project->{todos} = $c->model('Todo')->get_todos_by_project($c, $project->{id});

        # Process sub-projects recursively
        if ($project->{sub_projects} && @{$project->{sub_projects}}) {
            $self->enhance_project_data($c, $project->{sub_projects});
        }
    }

    # Log completion of the enhance_project_data method
    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'enhance_project_data',
        'Completed enhancing project data for filtering'
    );

    return $projects;
}

# Build priority mapping for display
sub build_priority {
    my $self = shift;
    return {
        1 => 'High',
        2 => 'Medium',
        3 => 'Low'
    };
}

__PACKAGE__->meta->make_immutable;
1;
