package Comserv::Controller::Project;
use Moose;
use namespace::autoclean;
use DateTime;
use Data::Dumper; # Add this line
BEGIN { extends 'Catalyst::Controller'; }

sub index :Path :Args(0) {
    my ( $self, $c ) = @_;
    # Redirect to the project route
    $c->res->redirect($c->uri_for($self->action_for('project')));
}

sub add_project :Path('addproject') :Args(0) {
    my ( $self, $c ) = @_;
    # Store the referrer URL in the session
    $c->session->{previous_url} = $c->req->referer;

    # Get a Comserv::Model::Project object
    my $project_model = $c->model('Project');

    # Get all projects
    my $projects = $project_model->get_projects($c->model('DBEncy'), $c->session->{SiteName});

    # Debug: print the projects to the console
    print Dumper($projects);

    # Pass the projects to the template
    $c->stash->{projects} = $projects;

    # Get a Comserv::Model::Site object
    my $site_model = $c->model('Site');

    # Get all sites
    my $sites = $site_model->get_all_sites();

    # Pass the sites to the template
    $c->stash->{sites} = $sites;

    $c->stash(
        template => 'todo/add_project.tt'
    );

    $c->forward($c->view('TT'));
}

sub create_project :Path('create_project') :Args(0) {
    my ( $self, $c ) = @_;
    print Dumper($c->session);
    # Get the form data from the request
    my $form_data = $c->request->body_parameters;

    # Get the username_of_poster from the session
    my $username_of_poster = $c->session->{username};

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get the Project resultset
    my $project_rs = $schema->resultset('Project');

    # Get the group name of poster from the session
    my $group_of_poster = $c->session->{roles};
    # Get the parent_id from the form data
    my $parent_id = $form_data->{parent_id};
    $parent_id = undef if $parent_id eq '';

    # Get the current date and time
    my $date_time_posted = DateTime->now;
    # Get the record_id from the form data
    my $record_id = $form_data->{record_id}||0;

    # Try to create a new project in the database
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
            group_of_poster => $group_of_poster, # Added this line
            date_time_posted => $date_time_posted->ymd . ' ' . $date_time_posted->hms, # Added this line
        });
    };
    if ($@) {
        # If there was an error creating the project, return to the add_project.tt template
        $c->stash(
            form_data => $form_data,
            error_message => 'There was an error creating the project: ' . $@,
            template => 'todo/add_project.tt'
        );
    } else {
        # If the project was created successfully, redirect to the project.tt template
        $c->stash(
            success_message => 'Project added successfully',
        );
              $c->res->redirect($c->session->{previous_url});

        $c->forward($c->view('TT'));
    }
}

sub project :Path('project') :Args(0) {
    my ( $self, $c ) = @_;

    # Get a Comserv::Model::Project object
    my $project_model = $c->model('Project');

    # Get all projects
    my $projects = $project_model->get_projects($c->model('DBEncy'), $c->session->{SiteName});

    # Pass the projects to the template
    $c->stash->{projects} = $projects;

    $c->stash(
        template => 'todo/project.tt'
    );

    $c->forward($c->view('TT'));
}

sub details :Path('details') :Args(0) {
    my ( $self, $c ) = @_;
   # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get the project id from the form data
    my $project_id = $c->request->body_parameters->{project_id};

    # Get a Comserv::Model::Project object
    my $project_model = $c->model('Project');

    # Get the project
    my $project = $project_model->get_project($schema, $project_id);

    # Pass the project to the template
    $c->stash->{project} = $project;

    $c->stash(
        template => 'todo/projectdetails.tt'
    );

    $c->forward($c->view('TT'));
}
# Route to display the edit project form
# Route to display the edit project form

sub editproject :Path('editproject') :Args(0) {
    my ( $self, $c ) = @_;

    # Get the project id from the form data
    my $project_id = $c->request->body_parameters->{project_id};

    # Get a Comserv::Model::Project object
    my $project_model = $c->model('Project');

    # Get the project
    my $project = $project_model->get_project($c->model('DBEncy'), $project_id);

    # Get all projects
    my $projects = $project_model->get_projects($c->model('DBEncy'), $c->session->{SiteName});

    # Pass the projects to the template
    $c->stash->{projects} = $projects;

    # Pass the project to the template
    $c->stash->{project} = $project;

    $c->stash(
        template => 'todo/editproject.tt'
    );

    $c->forward($c->view('TT'));
}
sub update_project :Local :Args(0)  {
    my ( $self, $c ) = @_;
    # Get the form data from the request
    my $form_data = $c->request->body_parameters;

    # Get the project id from the form data
    my $project_id = $form_data->{project_id};

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get the Project resultset
    my $project_rs = $schema->resultset('Project');

    # Find the project in the database
    my $project = $project_rs->find($project_id);

    if ($project) {
        # Update the project's fields with the new data
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
            # Add any other fields that need to be updated
        });

        # Redirect to the project home page
        $c->res->redirect($c->uri_for($self->action_for('project')));
    } else {
        # Return an error response if the project was not found
        $c->response->status(404);
        $c->response->body('Project not found');
    }
}
__PACKAGE__->meta->make_immutable;
1;
