package Comserv::Controller::Todo;
use Moose;
use namespace::autoclean;

use Data::Dumper;
BEGIN { extends 'Catalyst::Controller'; }

sub index :Path(/todo) :Args(0) {
    my ( $self, $c ) = @_;

    # Retrieve all of the todo records as todo model objects and store in the stash
 #   $c->stash(todos => [$c->model('DB::Todo')->all]);

    # Set the TT template to use.
    $c->stash(template => 'todo/todo.tt');
   $c->forward($c->view('TT'));
}
sub todo :Path('/todo') :Args(0) {
    my ( $self, $c ) = @_;

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object
    my $rs = $schema->resultset('Todo');

    # Fetch todos for the site, ordered by start_date
    my @todos = $rs->search(
        { sitename => $c->session->{SiteName} },  # filter by site
        { order_by => 'start_date' }  # order by start_date
    );

    # Add the todos to the stash
   $c->stash(
        todos => \@todos,
        sitename => $c->session->{SiteName},
        template => 'todo/todo.tt',

    );

    $c->forward($c->view('TT')),
}


sub addtodo :Path('/todo/addtodo') :Args(0) {
    my ( $self, $c ) = @_;

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get active projects for the site
    my $active_projects = $schema->get_active_projects($c->session->{SiteName});

    # Print the content of $active_projects
    print "Before adding to stash: ", Dumper($active_projects);

    # Add the active projects and SiteName to the stash
    $c->stash(
        projects => $active_projects || [{ id => 0, name => 'No projects' }],
        sitename => $c->session->{SiteName},
        template => 'todo/addtodo.tt',
        Dumper => \&Dumper,
    );

    # Print the content of the 'projects' array in the stash
    print "After adding to stash: ", Dumper($c->stash->{projects});

    $c->forward($c->view('TT'));
}
sub details :Path('/todo/details') :Args(0) {
    my ( $self, $c ) = @_;

    # Get the record_id from the request parameters
    my $record_id = $c->request->parameters->{record_id};

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object
    my $rs = $schema->resultset('Todo');

    # Fetch the todo with the given record_id
    my $todo = $rs->find($record_id);

    # Add the todo to the stash
    $c->stash(record => $todo);

    # Set the template to 'todo/details.tt'
    $c->stash(template => 'todo/details.tt');
}
sub modify :Local :Args(1) {
    my ($self, $c) = @_;

    # Retrieve the todo ID from the URL
    my $todo_id = $c->request->arguments->[0];

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object
    my $rs = $schema->resultset('Todo');

    # Find the todo in the database
    my $todo = $rs->find($todo_id);

    if ($todo) {
        # The todo was found, so retrieve the form data
        my $form_data = $c->request->body_parameters;

        # Get the current date
        my $current_date = DateTime->now->ymd;

        # Get the username from the session
        my $username = $c->session->{username};

        # Update the todo record with the new data
        $todo->update({
            sitename => $form_data->{sitename},
            start_date => $form_data->{start_date},
            parent_todo => $form_data->{parent_todo},
            due_date => $form_data->{due_date},
            subject => $form_data->{subject},
            description => $form_data->{description},
            estimated_man_hours => $form_data->{estimated_man_hours},
            comments => $form_data->{comments},
            accumulative_time => $form_data->{accumulative_time},
            reporter => $form_data->{reporter},
            company_code => $form_data->{company_code},
            owner => $form_data->{owner},
            project_code => $form_data->{project_code},
            developer => $form_data->{developer},
            username_of_poster => $username,
            status => $form_data->{status},
            priority => $form_data->{priority},
            share => $form_data->{share}||0,
            last_mod_by => $username,
            last_mod_date => $current_date,
            user_id => $form_data->{user_id}||1,
            project_id => $form_data->{project_id},
            date_time_posted => $form_data->{date_time_posted},
        });

        # Redirect the user back to the list of todos
        $c->response->redirect($c->uri_for($self->action_for('list_todos')));
    } else {
        # The todo was not found, so display an error message
        $c->response->body('Todo not found');
    }
}
sub create :Local {
    my ( $self, $c ) = @_;

    # Retrieve the form data from the request
    my $record_id = $c->request->params->{record_id};
    my $sitename = $c->request->params->{sitename};
    my $start_date = $c->request->params->{start_date};
    my $parent_todo = $c->request->params->{parent_todo};
    my $due_date = $c->request->params->{due_date};
    my $subject = $c->request->params->{subject};
    my $description = $c->request->params->{description};
    my $estimated_man_hours = $c->request->params->{estimated_man_hours};
    my $comments = $c->request->params->{comments};
    my $accumulative_time = $c->request->params->{accumulative_time};
    my $reporter = $c->request->params->{reporter};
    my $company_code = $c->request->params->{company_code};
    my $owner = $c->request->params->{owner};
    my $project_code = $c->request->params->{project_code};
    my $developer = $c->request->params->{developer};
    my $username_of_poster = $c->session->{username}||'Shanta';
    my $status = $c->request->params->{status};
    my $priority = $c->request->params->{priority};
    my $share = $c->request->params->{share}||0;
    my $last_mod_by = $c->request->params->{last_mod_by};
    my $last_mod_date = $c->request->params->{last_mod_date};
    my $group_of_poster = $c->session->{roles};
    my $user_id = $c->request->params->{user_id};
    my $project_id = $c->request->params->{project_id};
    my $date_time_posted = $c->request->params->{date_time_posted};

    # Check if accumulative_time is a valid integer
     $accumulative_time = $c->request->params->{accumulative_time};
    if (!defined $accumulative_time || $accumulative_time !~ /^\d+$/) {
        $accumulative_time = 0;  # default value
    }
    # Get the current date
    my $current_date = DateTime->now->ymd;

    # Get the username from the session
    my $username = $c->session->{username};


    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object
    my $rs = $schema->resultset('Todo');

    # Create a new todo record
    my $todo = $rs->create({
        record_id => $record_id,
        sitename => $sitename,
        start_date => $start_date,
        parent_todo => $parent_todo,
        due_date => $due_date,
        subject => $subject,
        description => $description,
        estimated_man_hours => $estimated_man_hours,
        comments => $comments,
        accumulative_time => $accumulative_time,
        reporter => $reporter,
        company_code => $company_code,
        owner => $owner,
        project_code => $project_code,
        developer => $developer,
        username_of_poster => $username_of_poster,
        status => $status,
        priority => $priority,
        share => $share,
        last_mod_by => $username,
        username_of_poster => $username,
        last_mod_date => $current_date,
        user_id => $user_id,
        group_of_poster => $group_of_poster,
        project_id => $project_id,
        date_time_posted => $date_time_posted,
    });

    # Redirect the user to the index action
    $c->response->redirect($c->uri_for($self->action_for('index')));
}
__PACKAGE__->meta->make_immutable;

1;