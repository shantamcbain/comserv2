package Comserv::Controller::Project;
use Moose;
use namespace::autoclean;
use DateTime;
use Data::Dumper;
use Comserv::Util::Logging;
use Comserv::Util::SiteHelper;
use List::Util 'sum';
BEGIN { extends 'Catalyst::Controller'; }
has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);
sub index :Path :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details($c, __FILE__, __LINE__, 'index', 'Starting index action');
    $c->res->redirect($c->uri_for($self->action_for('project')));
}

use Comserv::Util::SiteHelper;

sub add_project :Path('addproject') :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details($c, __FILE__, __LINE__, 'add_project', 'Starting add_project action' );
    $c->session->{previous_url} = $c->req->referer;
    my $project_model = $c->model('Project');
    my $projects = $project_model->get_projects($c->model('DBEncy'), $c->session->{SiteName});

    # Sort projects alphabetically by name
    my @sorted_projects = sort { $a->{name} cmp $b->{name} } @$projects;
    $c->stash->{projects} = \@sorted_projects;

    my $site_model = $c->model('Site');
    my $sites = Comserv::Util::SiteHelper::get_sites($c, $site_model);
    $self->logging->log_with_details($c, __FILE__, __LINE__, 'add_project', 'Current site: ' . $c->session->{SiteName});

    $c->stash(
        sites => $sites,
        current_site => $c->session->{SiteName},
        template => 'todo/add_project.tt'
    );
    $c->forward($c->view('TT'));
}



sub create_project :Path('create_project') :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details($c, __FILE__, __LINE__, 'create_project', 'Session data: ' . Dumper($c->session));
    my $form_data = $c->request->body_parameters;
    my $username_of_poster = $c->session->{username};
    my $schema = $c->model('DBEncy');
    my $project_resultset = $schema->resultset('Project');

    # Validate required session data
    unless ($c->session->{roles}) {
        $c->stash(
            error_msg => 'User roles not found in session. Please log in again.',
            template => 'todo/add_project.tt'
        );
        $c->forward($c->view('TT'));
        return;
    }

    # Ensure roles is an array reference
    my $roles = $c->session->{roles};
    unless (ref $roles eq 'ARRAY') {
        $roles = [];  # Initialize as an empty array if not an array reference
    }

    my $group_of_poster = join(',', @$roles);
    my $parent_id = $form_data->{parent_id};
    $parent_id = undef if $parent_id eq '';
    my $date_time_posted = DateTime->now;
    my $record_id = $form_data->{record_id} || 0;

    # Validate required fields
    my @required_fields = qw(client_name description developer_name name project_code sitename start_date status);
    foreach my $field (@required_fields) {
        unless (defined $form_data->{$field} && $form_data->{$field} ne '') {
            $c->stash(
                error_msg => "Field '$field' is required.",
                form_data => $form_data,
                template => 'todo/add_project.tt'
            );
            $c->forward($c->view('TT'));
            return;
        }
    }

    my $project = eval {
        $project_resultset->create({
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
            error_msg => 'Error creating project: ' . $@ . "\nPlease ensure all required fields are filled out.",
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

    my $project_model = $c->model('Project');
    my $projects = $project_model->get_projects($c->model('DBEncy'), $c->session->{SiteName});

    $c->stash->{projects} = $projects;

    $c->stash(
        template => 'todo/project.tt'
    );

    $c->forward($c->view('TT'));
}

sub details :Path('details') :Args(0) {
    my ( $self, $c ) = @_;
    my $schema = $c->model('DBEncy');
    my $project_id = $c->request->body_parameters->{project_id};
    my $project_model = $c->model('Project');
    my $project = $project_model->get_project($schema, $project_id);

    # Fetch todos and their associated logs
    my @todos = $schema->resultset('Todo')->search(
        { project_id => $project_id },
        { 
            order_by => [
                { -asc => 'me.priority' },
                { -asc => 'me.start_date' }
            ],
            prefetch => ['logs'],  # Prefetch related logs
            '+select' => ['logs.time'],
            '+as' => ['total_logged_time']
        }
    );

    # Calculate total logged time for each todo
    foreach my $todo (@todos) {
        $todo->{total_logged_time} = sum map { $_->time } $todo->logs;
    }

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
    my $site_model = $c->model('Site');
    my $sites = Comserv::Util::SiteHelper::get_sites($c, $site_model);

    $c->stash(
        projects => $project_model->get_projects($c->model('DBEncy'), $c->session->{SiteName}),
        project => $project,
        sites => $sites,
        current_site => $c->session->{SiteName},
        template => 'todo/editproject.tt'
    );

    $c->forward($c->view('TT'));
}


sub update_project :Local :Args(0)  {
    my ( $self, $c ) = @_;
    my $form_data = $c->request->body_parameters;
    my $project_id = $form_data->{project_id};
    my $schema = $c->model('DBEncy');
    my $project_resultset = $schema->resultset('Project');
    my $project = $project_resultset->find($project_id);

    if ($project) {
        # Update the project, setting parent_id to undef if "None" is selected
        my $parent_id = $form_data->{parent_id} eq '' ? undef : $form_data->{parent_id};

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
            parent_id => $parent_id, # Correctly handle parent_id
        });

        $c->flash->{success_message} = 'Project updated successfully';
        $c->res->redirect($c->uri_for($self->action_for('details'), { project_id => $project_id }));
    } else {
        $c->flash->{error_message} = 'Project not found';
        $c->res->redirect($c->uri_for($self->action_for('index')));
    }
}

__PACKAGE__->meta->make_immutable;
1;
