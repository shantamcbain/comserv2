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

    # Get all projects
    my $projects = $project_model->get_projects($c->model('DBEncy'));


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

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get the project id from the form data
    my $project_id = $c->request->body_parameters->{project_id};

    # Get a Comserv::Model::Project object
    my $project_model = $c->model('Project');
    # Get the project
    my $project = $project_model->get_project($schema, $project_id);

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

__PACKAGE__->meta->make_immutable;
1;
