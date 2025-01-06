package Comserv::Controller::Todo;
use Moose;
use namespace::autoclean;
use DateTime::Format::ISO8601;
use Data::Dumper;
use Comserv::Util::Logging; # Import the logging utility
BEGIN { extends 'Catalyst::Controller'; }
has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);
sub index :Path(/todo) :Args(0) {
    my ( $self, $c ) = @_;

    # Retrieve all of the todo records as todo model objects and store in the stash
    $c->stash(todos => [$c->model('DB::Todo')->all]);

    # Set the TT template to use.
    $c->stash(template => 'todo/todo.tt');
    $self->logging->log_with_details($c, __FILE__, __LINE__, 'index', 'Fetched todos for the todo page');
    $c->forward($c->view('TT'));
}
sub todo :Path('/todo') :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details($c, __FILE__, __LINE__, 'todo', 'Fetching todos for the todo page');
    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object
    my $rs = $schema->resultset('Todo');

    # Fetch todos for the site, ordered by start_date
    my @todos = $rs->search(
        {
            sitename => $c->session->{SiteName},  # filter by site
            status => { '!=' => 3 }  # status not equal to 3
        },
{ order_by => { -asc => ['priority', 'start_date'] } } # order by start_date
    );

    # Add the todos to the stash
   $c->stash(
        todos => \@todos,
        sitename => $c->session->{SiteName},
        template => 'todo/todo.tt',

    );

    $c->forward($c->view('TT'));
}
 sub details :Path('/todo/details') :Args {
    my ( $self, $c ) = @_;

    # Get the record_id from the request parameters
    my $record_id = $c->request->parameters->{record_id};

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object
    my $rs = $schema->resultset('Todo');

    # Fetch the todo with the given record_id
    my $todo = $rs->find($record_id);

    # Check if the todo was found
    if (defined $todo) {
        # Calculate accumulative_time using the Log model
        my $log_model = $c->model('Log');
        my $accumulative_time_in_seconds = $log_model->calculate_accumulative_time($c, $record_id);

        # Convert accumulative_time from seconds to hours and minutes
        my $hours = int($accumulative_time_in_seconds / 3600);
        my $minutes = int(($accumulative_time_in_seconds % 3600) / 60);

        # Format the total time as 'HH:MM'
        my $accumulative_time = sprintf("%02d:%02d", $hours, $minutes);

        # Add the todo and accumulative_time to the stash
        $c->stash(record => $todo, accumulative_time => $accumulative_time);

        # Set the template to 'todo/details.tt'
        $c->stash(template => 'todo/details.tt');
    } else {
        # Handle the case where the todo is not found
        $c->response->body('Todo not found');
    }
}


sub addtodo :Path('/todo/addtodo') :Args(0) {
    my ( $self, $c ) = @_;

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get the SiteName from the session
    my $SiteName = $c->session->{SiteName};

    # Fetch projects and their sub-projects
    my $project_rs = $schema->resultset('Project')->search(
        { 'me.sitename' => $SiteName }, # Filter by site name
        {
            prefetch => 'sub_projects', # Prefetch sub-projects
            order_by => ['me.name'] # Order by project name
        }
    );

    # Convert the resultset to an array of hashrefs for use in the template
    my @projects = map {
        {
            id => $_->id,
            name => $_->name,
            sub_projects => [ map { { id => $_->id, name => $_->name } } $_->sub_projects->all ]
        }
    } $project_rs->all;

    # Fetch all users to populate the user_id dropdown
    my @users = $schema->resultset('User')->all;

    # Log the list of user_ids
    my @user_ids = map { $_->id } @users;
    $self->logging->log_with_details($c, __FILE__, __LINE__, 'addtodo', 'User IDs: ' . join(', ', @user_ids));

    # Add the projects, sitename, and user_id to the stash
    $c->stash(
        projects => \@projects,
        sitename => $SiteName,
        users => \@users, # Pass users to the stash
        user_id => $c->session->{user_id}, # Pass user_id to the stash
        template => 'todo/addtodo.tt',
    );

    $c->forward($c->view('TT'));
}




sub debug :Local {
    my ( $self, $c ) = @_;

    # Print the @INC path
    $self->logging->log_with_details($c, __FILE__, __LINE__, 'debug', "INC: " . join(", ", @INC));

    # Check if the DateTime plugin is installed
    my $is_installed = eval {
        require Template::Plugin::DateTime;
        1;
    };
    $self->logging->log_with_details($c, __FILE__, __LINE__, 'debug', "DateTime plugin is " . ($is_installed ? "" : "not ") . "installed");

    $c->response->body("Debugging information has been logged");
}
sub modify :Local :Args(1) {
    my ($self, $c) = @_;

    # Retrieve the todo ID from the URL
    my $todo_id = $c->request->arguments->[0];

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object for the 'Todo' table
    my $todo_rs = $schema->resultset('Todo');

    # Find the todo in the database
    my $todo = $todo_rs->find($todo_id);

    if ($todo) {
        # The todo was found, so retrieve the form data
        my $form_data = $c->request->body_parameters;

        # Ensure parent_todo is set to a valid value
        my $parent_todo = $form_data->{parent_todo};
        if (!defined $parent_todo || $parent_todo eq '') {
            $parent_todo = 0; # Set a default value if parent_todo is not provided
        }

        # Fetch log entries associated with the todo
        my $log_rs = $schema->resultset('Log')->search({ todo_record_id => $todo_id });

        # Calculate total time from log entries
        my $total_log_time = 0;
        while (my $log = $log_rs->next) {
            # Calculate time spent using start_time and end_time
            my $start_time = $log->start_time;
            my $end_time = $log->end_time || '00:00:00'; # Default to '00:00:00' if end_time is not set

            my ($start_hour, $start_min) = split(':', $start_time);
            my ($end_hour, $end_min) = split(':', $end_time);

            my $time_diff_in_minutes = ($end_hour - $start_hour) * 60 + ($end_min - $start_min);
            $total_log_time += $time_diff_in_minutes * 60; # Convert minutes to seconds
        }

        # Define a default time (e.g., 1 hour in seconds)
        my $default_time = 3600;

        # Calculate accumulative time
        my $accumulative_time = $total_log_time || $default_time;

        # Update the todo record with the new data
        $todo->update({
            sitename => $form_data->{sitename},
            start_date => $form_data->{start_date},
            parent_todo => $parent_todo, # Ensure this is set
            due_date => $form_data->{due_date} || DateTime->now->add(days => 7)->ymd, # Set default value if not provided
            subject => $form_data->{subject},
            description => $form_data->{description},
            estimated_man_hours => $form_data->{estimated_man_hours},
            comments => $form_data->{comments},
            accumulative_time => $accumulative_time, # Update accumulative_time
            reporter => $form_data->{reporter},
            company_code => $form_data->{company_code},
            owner => $form_data->{owner},
            developer => $form_data->{developer},
            username_of_poster => $c->session->{username},
            status => $form_data->{status},
            priority => $form_data->{priority},
            share => $form_data->{share} || 0,
            last_mod_by => $c->session->{username} || 'system', # Set default value if not provided
            last_mod_date => DateTime->now->ymd,
            user_id => $form_data->{user_id} || 1,
            project_id => $form_data->{project_id},
            date_time_posted => $form_data->{date_time_posted},
        });

        # Redirect the user back to the page they came from
        my $referer = $c->request->referer || $c->uri_for($self->action_for('list_todos'));
        $c->response->redirect($referer);
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
    my $parent_todo = $c->request->params->{parent_todo} || 0;
    my $due_date = $c->request->params->{due_date} || DateTime->now->add(days => 7)->ymd; # Set default value if not provided
    my $subject = $c->request->params->{subject};
    my $schema = $c->model('DBEncy');
    my $description = $c->request->params->{description};
    my $estimated_man_hours = $c->request->params->{estimated_man_hours};
    my $comments = $c->request->params->{comments};
    my $accumulative_time = $c->request->params->{accumulative_time};
    my $reporter = $c->request->params->{reporter};
    my $company_code = $c->request->params->{company_code};
    my $owner = $c->request->params->{owner};
    my $developer = $c->request->params->{developer};
    my $username_of_poster = $c->session->{username} || 'Shanta';
    my $status = $c->request->params->{status};
    my $priority = $c->request->params->{priority};
    my $share = $c->request->params->{share} || 0;
    my $last_mod_by = $c->session->{username} || 'system'; # Set default value if not provided
    my $last_mod_date = DateTime->now->ymd;
    my $date_time_posted = DateTime->now->strftime('%Y-%m-%d %H:%M:%S');
    my $group_of_poster = $c->session->{roles} || 'default_group';
    my $manual_project_id = $c->request->params->{manual_project_id};
    my $project_id = $c->request->params->{project_id};

    # If manual_project_id is not empty, use it as the project ID
    my $selected_project_id = $manual_project_id ? $manual_project_id : $project_id;

    # Fetch the project_code using the selected_project_id
    my $project_code;
    if ($selected_project_id) {
        my $project = $schema->resultset('Project')->find($selected_project_id);
        $project_code = $project ? $project->project_code : 'default_code'; # Set a default code if not found
    } else {
        $project_code = 'default_code'; # Set a default code if no project ID is provided
    }

    # Check if accumulative_time is a valid integer
    $accumulative_time = $c->request->params->{accumulative_time};
    if (!defined $accumulative_time || $accumulative_time !~ /^\d+$/) {
        $accumulative_time = 0;
    }

    # Get the current date
    my $current_date = DateTime->now->ymd;

    # Retrieve user_id from session or another reliable source
    my $user_id = $c->session->{user_id};
    unless (defined $user_id) {
        # Handle the case where user_id is not found
        $c->response->body('User ID not found in session');
        return;
    }

    # Create a new todo record
    my $todo = $schema->resultset('Todo')->create({
        record_id => $record_id,
        sitename => $sitename,
        start_date => $start_date,
        parent_todo => $parent_todo,
        due_date => $due_date, # Now using default value if not provided
        subject => $subject,
        description => $description,
        estimated_man_hours => $estimated_man_hours,
        comments => $comments,
        accumulative_time => $accumulative_time,
        reporter => $reporter,
        company_code => $company_code,
        owner => $owner,
        project_code => $project_code, # Ensure this is set
        developer => $developer,
        username_of_poster => $username_of_poster,
        status => $status,
        priority => $priority,
        share => $share,
        last_mod_by => $last_mod_by,
        last_mod_date => $current_date,
        user_id => $user_id, # Ensure this is set
        group_of_poster => $group_of_poster,
        project_id => $selected_project_id,
        date_time_posted => $date_time_posted,
    });

    # Redirect the user to the index action
    $c->response->redirect($c->uri_for($self->action_for('index')));
}






sub day :Path('/todo/day') :Args {
    my ( $self, $c, $date_arg ) = @_;

    # Validate the date_arg if it's defined
    my $date;
    if (defined $date_arg) {
        my $iso8601 = DateTime::Format::ISO8601->new;
        eval { $date = $iso8601->parse_datetime($date_arg) };
        $date = DateTime->now->ymd unless $date;  # Use today's date if $date_arg is not valid
    } else {
        $date = DateTime->now->ymd;  # Use today's date if $date_arg is not defined
    }
# Calculate the previous and next dates
my $dt = DateTime::Format::ISO8601->parse_datetime($date);
my $previous_date = $dt->clone->subtract(days =>
 1)->strftime('%Y-%m-%d');
my $next_date = $dt->clone->add(days => 1)->strftime('%Y-%m-%d');

    # Get the Todo model
    my $todo_model = $c->model('Todo');

    # Fetch todos for the site, ordered by start_date
    my $todos = $todo_model->get_top_todos($c, $c->session->{SiteName});

    # Filter todos for the given day and status not equal to 3
    my @filtered_todos = grep { $_->start_date le $date && $_->status ne '3' } @$todos;

    # Add the todos to the stash
    $c->stash(
        todos => \@filtered_todos,
        sitename => $c->session->{SiteName},
        date => $date,
        previous_date => $previous_date,
        next_date => $next_date,
        template => 'todo/day.tt',
    );

    $c->forward($c->view('TT'));
}
sub week :Path('/todo/week') :Args {
    my ($self, $c, $date) = @_;

    # Get the Todo model
    my $todo_model = $c->model('Todo');

    # If no date is provided, use the current date
    if (!defined $date) {
        $date = DateTime->now->ymd;
    }

    # Calculate the start and end of the week
    my $dt = DateTime::Format::ISO8601->parse_datetime($date);
    my $start_of_week = $dt->clone->subtract(days => $dt->day_of_week - 1)->strftime('%Y-%m-%d');
    my $end_of_week = $dt->clone->add(days => 7 - $dt->day_of_week)->strftime('%Y-%m-%d');

    # Fetch todos for the site within the week, ordered by start_date
    my $todos = $todo_model->get_top_todos($c, $c->session->{SiteName});

    # Filter todos for the given week and status not equal to 3
    my @filtered_todos = grep { $_->start_date ge $start_of_week && $_->start_date le $end_of_week && $_->status ne '3' } @$todos;

    # Add the todos to the stash
    $c->stash(
        todos => \@filtered_todos,
        sitename => $c->session->{SiteName},
        start_of_week => $start_of_week,
        end_of_week => $end_of_week,
        template => 'todo/week.tt',
    );

    $c->forward($c->view('TT'));
}
1;
