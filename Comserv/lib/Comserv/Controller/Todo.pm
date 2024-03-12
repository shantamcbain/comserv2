package Comserv::Controller::Todo;
use Moose;
use namespace::autoclean;
use DateTime::Format::ISO8601;
use Data::Dumper;
BEGIN { extends 'Catalyst::Controller'; }

sub index :Path(/todo) :Args(0) {
    my ( $self, $c ) = @_;

    # Retrieve all of the todo records as todo model objects and store in the stash
    $c->stash(todos => [$c->model('DB::Todo')->all]);

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

    $c->forward($c->view('TT')),
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

    # Retrieve accumulative_time from the database
    my $accumulative_time_in_seconds = $todo->accumulative_time;

    # Convert accumulative_time from seconds to hours and minutes
    my $hours = int($accumulative_time_in_seconds / 3600);
    my $minutes = int(($accumulative_time_in_seconds % 3600) / 60);

    # Round minutes to the nearest minute
    $minutes = int($minutes + 0.5);

    # If minutes is 60, increment hours by 1 and set minutes to 0
    if ($minutes == 60) {
        $hours += 1;
        $minutes = 0;
    }

    # Format the total time as 'HH:MM'
    my $accumulative_time = sprintf("%02d:%02d", $hours, $minutes);

    # Add the todo and accumulative_time to the stash
    $c->stash(record => $todo, accumulative_time => $accumulative_time);

    # Set the template to 'todo/details.tt'
    $c->stash(template => 'todo/details.tt');
}
sub addtodo :Path('/todo/addtodo') :Args(0) {
    my ( $self, $c ) = @_;

    # Get the date from the POST parameters
    my $date = $c->request->body_parameters->{date};

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');
    # Get the SiteName from the session
    my $SiteName = $c->session->{SiteName};

 # Get the Project resultset
my $project_rs = $schema->resultset('Project')->search({sitename => $SiteName});
# Convert the resultset to an array of hashrefs for use in the template
my @projects = map { { id => $_->id, name => $_->name } } $project_rs->all;

    # Print the content of $project_rs
    print "Before adding to stash: ", Dumper($project_rs);

    # Add the active projects, SiteName, and date to the stash
    $c->stash(
        projects => \@projects || [{ id => 0, name => 'No projects' }],
        sitename => $c->session->{SiteName},
        start_date => $date,  # Add the date to the stash
        template => 'todo/addtodo.tt',
        Dumper => \&Dumper,
    );

    # Print the content of the 'projects' array in the stash
    print "After adding to stash: ", Dumper($c->stash->{projects});

    $c->forward($c->view('TT'));
}
sub debug :Local {
    my ($self, $c) = @_;

    # Print the @INC path
    $c->log->debug("INC: " . join(", ", @INC));

    # Check if the DateTime plugin is installed
    my $is_installed = eval {
        require Template::Plugin::DateTime;
        1;
    };
    $c->log->debug("DateTime plugin is " . ($is_installed ? "" : "not ") . "installed");

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

        # Get a DBIx::Class::ResultSet object for the 'Log' table
        my $log_rs = $schema->resultset('Log');

        # Fetch the logs for the todo
        my @logs = $log_rs->search({ todo_record_id => $todo_id });

        # Calculate the total time from the logs
        my $total_time = 0;
        foreach my $log (@logs) {
            $total_time += $log->time;
        }

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
            accumulative_time => $total_time,
            reporter => $form_data->{reporter},
            company_code => $form_data->{company_code},
            owner => $form_data->{owner},
            project_id => $form_data->{project_id},
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
} # Add this line
sub create :Local {
    my ( $self, $c ) = @_;

    # Retrieve the form data from the request
    my $record_id = $c->request->params->{record_id};
    my $sitename = $c->request->params->{sitename};
    my $start_date = $c->request->params->{start_date};
    my $parent_todo = $c->request->params->{parent_todo};
    my $due_date = $c->request->params->{due_date};
    my $subject = $c->request->params->{subject}; my $schema = $c->model('DBEncy');
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
    my $manual_project_id = $c->request->params->{manual_project_id};
    my $date_time_posted = $c->request->params->{date_time_posted};

    # If manual_project_id is not empty, use it as the project ID
    # If manual_project_id is empty, use project_id as the project ID
    my $selected_project_id = $manual_project_id ? $manual_project_id : $project_id;

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
    $schema = $c->model('DBEncy');

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
my $previous_date = $dt->clone->subtract(days => 1)->strftime('%Y-%m-%d');
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

    $c->forward($c->view('TT')),
}
sub week :Path('/todo/week') :Args {
    my ($self, $c, $date) = @_;

    # Get the Todo model
    my $todo_model = $c->model('Todo');

    # If no date is provided, use the current date
    if (!defined $date) {
        my $dt = DateTime->now(time_zone => 'local');
        $date = $dt->ymd;
    }

    # Convert the date string to a DateTime object
    my $dt = DateTime::Format::ISO8601->parse_datetime($date);

    # Calculate the start and end dates of the week
    my $start_date = $dt->clone->subtract(days => $dt->day_of_week % 7);
    my $end_date = $start_date->clone->add(days => 6);

    # Calculate the dates for the previous and next weeks
    my $prev_week_date = $start_date->clone->subtract(days => 7)->ymd;
    my $next_week_date = $start_date->clone->add(days => 7)->ymd;

# Calculate the dates and day names for each day of the week
my @week_days;
for my $day (0..6) {
    my $current_date = $start_date->clone->add(days => $day);
    my $all_todos = $todo_model->get_todos_for_date($c, $current_date->ymd);

    # Filter todos based on the day
    my @day_todos = grep {
        if ($day == 0) {
            # If it's the first day of the week, include todos that have gone beyond their due date
                   # If it's the first day of the week, include todos that have gone beyond their due date and are not closed
            $_->due_date le $current_date->ymd && $_->status ne 'closed'

        } else {
            # For the rest of the days, only include todos that start on or before the current date and the due date is on or after the current date
            $_->start_date le $current_date->ymd && $_->due_date ge $current_date->ymd
        }
    } @$all_todos;

    push @week_days, {
        date => $current_date->ymd,
        day_name => $current_date->day_name,
        todos => \@day_todos,
    };
}    # Format the dates to 'yyyy-mm-dd' before adding them to the stash
    $c->stash(
        date => $dt->ymd,
        week_days => \@week_days,
        start_date => $start_date->ymd,
        end_date => $end_date->ymd,
        prev_week_date => $prev_week_date,
        next_week_date => $next_week_date,
    );

    # Render the week.tt template
    $c->stash->{template} = 'todo/week.tt';

    # Forward to the 'TT' view
    $c->forward($c->view('TT'));
}
__PACKAGE__->meta->make_immutable;

1;