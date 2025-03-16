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

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_project',
        "Parent ID: " . (defined $parent_id ? $parent_id : 'undef'));

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
            group_of_poster => $c->session->{roles}->[0],
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

    # Use the existing method to fetch projects with sub-projects
    my $projects = $self->fetch_projects_with_subprojects($c);

    $c->stash->{projects} = $projects;

    $c->stash(
        template => 'todo/project.tt'
    );

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

sub fetch_projects_with_subprojects :Private {
    my ($self, $c) = @_;
    # Log the start of the project-fetching subroutine
    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'fetch_projects_with_subprojects',
        'Fetching parent projects with sub-projects'
    );

    # Get the schema and SiteName
    my $schema = $c->model('DBEncy');
    my $SiteName = $c->session->{SiteName};

    # Fetch projects with limited recursive prefetch for sub-projects
    # Reduced from 4 levels to 3 levels to prevent deep recursion
    my $project_rs = $schema->resultset('Project')->search(
        { 'me.sitename' => $SiteName, 'me.parent_id' => undef },
        {
            prefetch => { sub_projects => { sub_projects => 'sub_projects' } },
            order_by => { -asc => 'me.name' },
        }
    );

    # Convert the resultset into a structured array of hashrefs
    # Reduced from 4 levels to 3 levels to match the prefetch depth
    my @projects = map {
        {
            id           => $_->id,
            name         => $_->name,
            parent_id    => $_->parent_id,
            sub_projects => [
                map {
                    {
                        id           => $_->id,
                        name         => $_->name,
                        parent_id    => $_->parent_id,
                        sub_projects => [
                            map {
                                {
                                    id           => $_->id,
                                    name         => $_->name,
                                    parent_id    => $_->parent_id,
                                    # No further sub_projects level to prevent deep recursion
                                }
                            } $_->sub_projects->all
                        ],
                    }
                } $_->sub_projects->all
            ],
        }
    } $project_rs->all;

    # Log the successful preparation of the project data structure
    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'fetch_projects_with_subprojects',
        'Successfully prepared project data structure'
    );

    return \@projects;
}

sub editproject :Path('editproject') :Args(0) {
    my ( $self, $c ) = @_;

    my $project_id = $c->request->body_parameters->{project_id};
    my $project_model = $c->model('Project');
    my $project = $project_model->get_project($c->model('DBEncy'), $project_id);
     # Use the fetch_available_sites method from the Site controller to get the sites
    my $site_controller = $c->controller('Site');
    my $sites = $site_controller->fetch_available_sites($c);

    # Use the fetch_projects_with_subprojects method to get the projects
    my $projects = $self->fetch_projects_with_subprojects($c);

    $c->stash->{projects} = $projects;
    $c->stash->{project} = $project;
    $c->stash->{sites} = $sites;
    $c->stash(
        template => 'todo/editproject.tt'
    );

    $c->forward($c->view('TT'));
}

sub build_project_tree :Private {
    my ($self, $c, $project, $depth) = @_;

    # Set default depth or increment current depth
    $depth = defined($depth) ? $depth + 1 : 0;

    # Maximum recursion depth - adjust as needed
    my $max_depth = 5;

    # Get the schema
    my $schema = $c->model('DBEncy');

    # Create the base project hash with all its attributes
    my $project_hash = {
        map { $_ => $project->$_ } $project->result_source->columns
    };

    # Fetch todos for this project
    my @todos = $schema->resultset('Todo')->search(
        { project_id => $project->id },
        { order_by => { -asc => 'start_date' } }
    );
    $project_hash->{todos} = \@todos;

    # Only fetch sub-projects if we haven't reached the maximum depth
    if ($depth < $max_depth) {
        # Fetch sub-projects
        my @sub_projects = $schema->resultset('Project')->search(
            { parent_id => $project->id },
            { order_by => { -asc => 'name' } }
        );

        # If there are sub-projects, process them recursively
        if (@sub_projects) {
            $project_hash->{sub_projects} = [
                map { $self->build_project_tree($c, $_, $depth) } @sub_projects
            ];

            # Log the number of sub-projects found
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'build_project_tree',
                "Found " . scalar(@sub_projects) . " sub-projects for project ID: " . $project->id . " at depth $depth");
        }
    } else {
        # Log that we've reached the maximum depth
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'build_project_tree',
            "Reached maximum depth ($max_depth) for project ID: " . $project->id);

        # Add a flag to indicate there might be more sub-projects
        if ($schema->resultset('Project')->search({ parent_id => $project->id })->count > 0) {
            $project_hash->{has_more_sub_projects} = 1;
        }
    }

    return $project_hash;
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
__PACKAGE__->meta->make_immutable;
1;
