package Comserv::Controller::Project;
use Moose;
use namespace::autoclean;
use DateTime;
use Data::Dumper;
use Comserv::Util::Logging;
use Comserv::Controller::Site;
BEGIN { extends 'Catalyst::Controller'; }
has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);
sub index :Path :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details('info', __FILE__, __LINE__, 'index', 'Starting index action');
    $c->res->redirect($c->uri_for($self->action_for('project')));
}

sub add_project :Path('addproject') :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_project', 'Starting add_project action' );

    # Store the previous URL for redirect after form submission
    $c->session->{previous_url} = $c->req->referer;

    # Get parent_id from query parameters if it exists (for sub-projects)
    my $parent_id = $c->request->query_parameters->{parent_id};

    # Use the fetch_projects_with_subprojects method to get the projects
    my $projects = $self->fetch_projects_with_subprojects($c);

    # Use the fetch_available_sites method from Site controller to get the sites
    my $site_controller = $c->controller('Site');
    my $sites = $site_controller->fetch_available_sites($c);

    # If this is a sub-project, get the parent project details
    my $parent_project;
    if ($parent_id) {
        my $schema = $c->model('DBEncy');
        $parent_project = $schema->resultset('Project')->find($parent_id);
        if ($parent_project) {
            # Pre-fill form data with parent project details
            $c->stash->{form_data} = {
                sitename => $parent_project->sitename,
                parent_id => $parent_id,  # This will be used to pre-select in the dropdown
                selected_parent => $parent_id,  # Additional field for template to identify selected parent
                # Inherit other relevant fields from parent
                project_code => $parent_project->project_code,
                client_name => $parent_project->client_name,
                developer_name => $parent_project->developer_name,
            };

            # Log the parent project details for debugging
            $self->logging->log_with_details(
                $c, 'debug', __FILE__, __LINE__, 'add_project',
                "Setting up sub-project for parent ID: $parent_id, Name: " . $parent_project->name
            );
        } else {
            $self->logging->log_with_details(
                $c, 'warn', __FILE__, __LINE__, 'add_project',
                "Parent project not found for ID: $parent_id"
            );
        }
    }

    # Set up the stash for the template
    $c->stash(
        sites => $sites,
        projects => $projects,
        parent_project => $parent_project,
        template => 'todo/add_project.tt'
    );

    $c->forward($c->view('TT'));
}


sub  create_project :Local :Args(0) {
    my ($self, $c) = @_;

    my $form_data = $c->request->body_parameters;
    my $schema = $c->model('DBEncy');
    my $project_rs = $schema->resultset('Project');
    my $date_time_posted = DateTime->now;

    # Get username safely
    my $username = '';
    if ($c->user_exists) {
        $username = $c->user->username;
    } elsif ($c->session->{username}) {
        $username = $c->session->{username};
    } else {
        $username = 'anonymous';
    }

    # Handle parent_id properly
    my $parent_id = $form_data->{parent_id};
    if (ref $parent_id eq 'ARRAY') {
        $parent_id = $parent_id->[0];
    }
    if (!$parent_id || $parent_id eq '') {
        $parent_id = undef;
    }

    # Get group_of_poster safely
    my $group_of_poster = 'general';  # Default value
    if ($c->session->{roles} && ref $c->session->{roles} eq 'ARRAY' && defined $c->session->{roles}->[0]) {
        $group_of_poster = $c->session->{roles}->[0];
    } else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'create_project',
            "No roles found in session, using default group 'general'");
    }

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_project',
        "Parent ID: " . (defined $parent_id ? $parent_id : 'undef') . ", Group of poster: $group_of_poster");

    my $project = eval {
        $project_rs->create({
            sitename => $c->session->{SiteName},
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
            username_of_poster => $username,
            parent_id => $parent_id,
            group_of_poster => $group_of_poster,
            date_time_posted => $date_time_posted->ymd . ' ' . $date_time_posted->hms,
            record_id => 0  # Set to 0 instead of undef
        });
    };

    if ($@) {
        my $error_msg = $@;
        $error_msg =~ s/\s+at\s+.*//s;

        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_project',
            "Database error creating project: $error_msg");

        my $site_controller = $c->controller('Site');
        my $sites = $site_controller->fetch_available_sites($c);
        my $projects = $self->fetch_projects_with_subprojects($c);

        $c->stash(
            form_data => $form_data,
            sites => $sites,
            projects => $projects,
            error_message => "Failed to create project: $error_msg",
            template => 'todo/add_project.tt'
        );

        $c->forward($c->view('TT'));
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_project',
        "Project created with ID: " . $project->id);

    $c->flash->{success_message} = 'Project added successfully';
    $c->res->redirect($c->uri_for($self->action_for('project')));
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

    # Add the projects and filter info to the stash
    $c->stash(
        projects => $projects,
        role_filter => $role_filter,
        project_filter => $project_filter,
        priority_filter => $priority_filter,
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

    # Logging: Start of the details action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'details', 'Starting details action.');

    # Retrieve project_id from body or query parameters
    my $project_id = $c->request->body_parameters->{project_id} || $c->request->query_parameters->{project_id};

    if (!$project_id) {
        # Logging: Parameter missing
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'details', 'Missing parent_id or project_id parameter in request.');

        # Check if this was meant to be a sub-project creation
        my $parent_id = $c->request->query_parameters->{parent_id};
        if ($parent_id) {
            # Redirect back to add project form with parent_id
            $c->response->redirect($c->uri_for($self->action_for('add_project'), { parent_id => $parent_id }));
            return;
        }

        $c->stash(
            error_msg => 'Project ID is required to view project details. Please select a project from the list.',
            template => 'todo/projectdetails.tt'
        );
        $c->forward($c->view('TT'));
        return;
    }

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'details', "Received project_id: $project_id.");

    # Get the DB schema and project model
    my $schema = $c->model('DBEncy');
    my $project_model = $c->model('Project');

    # Log the project_id we're looking for
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'details',
        "Looking for project with ID: $project_id");

    # Fetch project by ID
    my $project;
    eval {
        $project = $schema->resultset('Project')->find($project_id);
    };
    if ($@ || !$project) {
        # Logging: Error fetching project or project not found
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'details', "Failed to fetch project for ID: $project_id. Error: $@");
        $c->stash(
            error_msg => "Project with ID $project_id not found.",
            template => 'todo/projectdetails.tt'
        );
        $c->forward($c->view('TT'));
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'details', "Successfully fetched project for ID: $project_id.");

    # Fetch todos associated with the project
    my @todos;
    eval {
        @todos = $schema->resultset('Todo')->search(
            { project_id => $project_id },
            { order_by => { -asc => 'start_date' } }
        );
    };
    if ($@) {
        # Logging: Error fetching todos
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'details', "Error fetching todos for project ID: $project_id. Error: $@");
        $c->stash(
            error_msg => "Failed to fetch todos for project with ID $project_id.",
            template => 'todo/projectdetails.tt'
        );
        $c->forward($c->view('TT'));
        return;
    }

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'details', "Fetched " . scalar(@todos) . " todos for project ID: $project_id.");

    # Fetch sub-projects and their todos recursively
    my $project_tree = $self->build_project_tree($c, $project);

    # Add the project tree (including sub-projects and todos) to the stash
    $c->stash(
        project => $project_tree,
        todos => \@todos,
        template => 'todo/projectdetails.tt'
    );

    # Logging: End of details action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'details', "Finished details action for project ID: $project_id.");

    $c->forward($c->view('TT'));
}

# This enhance_project_data implementation has been moved to line 482
# See the implementation there

sub fetch_projects_with_subprojects :Private {
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

# This build_project_tree implementation has been moved to line 672
# See the implementation there

sub editproject :Path('editproject') :Args(0) {
    my ( $self, $c ) = @_;

    # Log the start of the editproject action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'editproject', 'Starting editproject action');

    # Get project_id from either body parameters (POST) or query parameters (GET)
    my $project_id = $c->request->body_parameters->{project_id} || $c->request->query_parameters->{project_id};

    # Log the project_id
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'editproject',
        "Project ID: " . (defined $project_id ? $project_id : 'undefined'));

    # Validate project_id
    if (!defined $project_id || $project_id eq '') {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'editproject', 'Missing project_id parameter');
        $c->stash(
            error_msg => "Project ID is required to edit a project.",
            template => 'todo/error.tt'
        );
        $c->forward($c->view('TT'));
        return;
    }

    # Handle the case where project_id is an array reference (from multi-select)
    if (ref $project_id eq 'ARRAY') {
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'editproject',
            "Project ID is an array reference, using first element");
        $project_id = $project_id->[0];
    }

    # Get the project from the database
    my $project_model = $c->model('Project');
    my $schema = $c->model('DBEncy');
    my $project;

    eval {
        $project = $project_model->get_project($schema, $project_id);
    };

    if ($@ || !$project) {
        my $error_msg = $@ || "Project not found";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'editproject',
            "Error finding project with ID $project_id: $error_msg");
        $c->stash(
            error_msg => "Project with ID $project_id not found. Please check the application.log for more Details.",
            template => 'todo/error.tt'
        );
        $c->forward($c->view('TT'));
        return;
    }

    # Log that we found the project
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'editproject',
        "Found project with ID $project_id: " . $project->name);

    # Use the fetch_available_sites method from the Site controller to get the sites
    my $site_controller = $c->controller('Site');
    my $sites = $site_controller->fetch_available_sites($c);

    # Use the fetch_projects_with_subprojects method to get the projects
    my $projects = $self->fetch_projects_with_subprojects($c);

    # Stash everything for the template
    $c->stash(
        projects => $projects,
        project => $project,
        sites => $sites,
        template => 'todo/editproject.tt'
    );

    # Log the end of the editproject action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'editproject',
        "Ending editproject action for project ID $project_id");

    $c->forward($c->view('TT'));
}

sub build_project_tree :Private {
    my ($self, $c, $project, $depth) = @_;

    # Set default depth or increment current depth
    $depth = defined($depth) ? $depth + 1 : 0;

    # Maximum recursion depth - adjust as needed
    my $max_depth = 3;

    # Get the schema
    my $schema = $c->model('DBEncy');

    # Log the start of building the project tree
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'build_project_tree',
        "Building project tree for project ID: " . $project->id . " at depth $depth");

    # Create the base project hash with essential attributes only
    my $project_hash = {
        id => $project->id,
        name => $project->name,
        description => $project->description,
        start_date => $project->start_date,
        end_date => $project->end_date,
        status => $project->status,
        project_code => $project->project_code,
        project_size => $project->project_size,
        estimated_man_hours => $project->estimated_man_hours,
        developer_name => $project->developer_name,
        client_name => $project->client_name,
        comments => $project->comments,
        sitename => $project->sitename,
        parent_id => $project->parent_id,
        username_of_poster => $project->username_of_poster,
        group_of_poster => $project->group_of_poster,
        date_time_posted => $project->date_time_posted,
        record_id => $project->record_id
    };

    # Fetch todos for this project
    my @todos = ();
    eval {
        @todos = $schema->resultset('Todo')->search(
            { project_id => $project->id },
            { order_by => { -asc => 'start_date' } }
        )->all;
    };

    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'build_project_tree',
            "Error fetching todos for project ID: " . $project->id . ": $@");
    } else {
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'build_project_tree',
            "Fetched " . scalar(@todos) . " todos for project ID: " . $project->id);
    }

    # Create an array of todo hashrefs with only the needed attributes
    my @todo_hashrefs = ();
    foreach my $todo (@todos) {
        push @todo_hashrefs, {
            id => $todo->id,
            record_id => $todo->record_id,
            subject => $todo->subject,
            description => $todo->description,
            start_date => $todo->start_date,
            due_date => $todo->due_date,
            status => $todo->status,
            priority => $todo->priority
        };
    }
    $project_hash->{todos} = \@todo_hashrefs;

    # Only fetch sub-projects if we haven't reached the maximum depth
    if ($depth < $max_depth) {
        # Fetch sub-projects
        my @sub_projects = ();
        eval {
            @sub_projects = $schema->resultset('Project')->search(
                { parent_id => $project->id },
                { order_by => { -asc => 'name' } }
            )->all;
        };

        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'build_project_tree',
                "Error fetching sub-projects for project ID: " . $project->id . ": $@");
        } else {
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'build_project_tree',
                "Fetched " . scalar(@sub_projects) . " sub-projects for project ID: " . $project->id);
        }

        # If there are sub-projects, process them iteratively
        if (@sub_projects) {
            my @sub_project_hashrefs = ();
            foreach my $sub_project (@sub_projects) {
                # Recursively build the sub-project tree, but only if we're not too deep
                if ($depth + 1 < $max_depth) {
                    push @sub_project_hashrefs, $self->build_project_tree($c, $sub_project, $depth);
                } else {
                    # Just add basic info for the sub-project
                    push @sub_project_hashrefs, {
                        id => $sub_project->id,
                        name => $sub_project->name,
                        description => $sub_project->description,
                        parent_id => $sub_project->parent_id,
                        has_more_sub_projects => ($schema->resultset('Project')->search({ parent_id => $sub_project->id })->count > 0) ? 1 : 0
                    };
                }
            }
            $project_hash->{sub_projects} = \@sub_project_hashrefs;
        } else {
            $project_hash->{sub_projects} = [];
        }
    } else {
        # Log that we've reached the maximum depth
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'build_project_tree',
            "Reached maximum depth ($max_depth) for project ID: " . $project->id);

        # Add a flag to indicate there might be more sub-projects
        my $has_more = 0;
        eval {
            $has_more = $schema->resultset('Project')->search({ parent_id => $project->id })->count > 0 ? 1 : 0;
        };

        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'build_project_tree',
                "Error checking for more sub-projects for project ID: " . $project->id . ": $@");
        }

        $project_hash->{has_more_sub_projects} = $has_more;
        $project_hash->{sub_projects} = [];
    }

    return $project_hash;
}

sub update_project :Local :Args(0)  {
    my ( $self, $c ) = @_;

    # Log the start of the update_project action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_project', 'Starting update_project action');

    my $form_data = $c->request->body_parameters;
    my $project_id = $form_data->{project_id};

    # Handle the case where project_id is an array reference (from multi-select)
    if (ref $project_id eq 'ARRAY') {
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'update_project',
            "Project ID is an array reference, using first element");
        $project_id = $project_id->[0];
    }

    # Validate project_id
    if (!$project_id) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_project', 'Missing project_id parameter');
        $c->response->status(400);
        $c->response->body('Project ID is required');
        return;
    }

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'update_project', "Updating project with ID: $project_id");

    my $schema = $c->model('DBEncy');
    my $project_rs = $schema->resultset('Project');

    # Find the project with error handling
    my $project;
    eval {
        $project = $project_rs->find($project_id);
    };

    if ($@ || !$project) {
        my $error_msg = $@ || "Project not found";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_project', "Error finding project: $error_msg");
        $c->response->status(404);
        $c->response->body("Project with ID $project_id not found");
        return;
    }

    # Handle parent_id properly
    my $parent_id = $form_data->{parent_id};
    if (ref $parent_id eq 'ARRAY') {
        $parent_id = $parent_id->[0];
    }
    if (!$parent_id || $parent_id eq '') {
        $parent_id = undef;
    }

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'update_project',
        "Parent ID: " . (defined $parent_id ? $parent_id : 'undef'));

    # Update the project with error handling
    eval {
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
            parent_id => $parent_id,
        });
    };

    if ($@) {
        my $error_msg = $@;
        $error_msg =~ s/\s+at\s+.*//s; # Clean up the error message

        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_project', "Error updating project: $error_msg");
        $c->response->status(500);
        $c->response->body("Failed to update project: $error_msg");
        return;
    }

    # Log successful update
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_project',
        "Successfully updated project with ID: $project_id, Name: " . $project->name .
        ", Parent ID: " . (defined $parent_id ? $parent_id : 'None'));

    # Set success message
    $c->flash->{success_message} = 'Project "' . $project->name . '" updated successfully';

    # Redirect to the project details page
    $c->res->redirect($c->uri_for($self->action_for('details'), { project_id => $project_id }));
}
__PACKAGE__->meta->make_immutable;
1;
