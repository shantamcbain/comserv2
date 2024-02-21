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
    print("__PACKAGE__ add_project\n");
    print "SiteName: in ", $c->session->{SiteName}, "\n";

    # Get a Comserv::Model::Project object
    my $project_model = $c->model('Project');
    print " project $project_model \n";
    # Get all projects
     my $projects = $project_model->get_projects($c->model('DBEncy'), $c->session->{SiteName});
        use Data::Dumper;
    print "projects: ", Dumper($projects), "\n";
  # Print the SiteName

    # Pass the projects to the template
    $c->stash->{projects} = $projects;

    # Get the Site resultset
    my $site_rs = $c->model('DBEncy')->resultset('Site');

    # Get all sites in ascending order by name
    my @sites = $site_rs->search({}, { order_by => 'name' });

    # Pass the sites to the template
    $c->stash->{sites} = \@sites;

    $c->stash(
        sitename => $c->session->{SiteName},
        template => 'todo/add_project.tt'
    );

    $c->forward($c->view('TT'));
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
            $c->res->redirect($c->uri_for($self->action_for('project')))
        );
        $c->res->redirect($c->uri_for($self->action_for('project/project')));
        $c->forward($c->view('TT'));
    }
}

__PACKAGE__->meta->make_immutable;
1;
