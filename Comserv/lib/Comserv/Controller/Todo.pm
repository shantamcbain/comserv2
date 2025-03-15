
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
# Apply restrictions to the entire controller
# Apply restrictions to the entire controller
sub begin :Private {
    my ($self, $c) = @_;

    # Log the path the user is accessing
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'begin', "User accessing path: " . $c->req->uri);

    # Fetch the user's roles from the session
    my $roles = $c->session->{roles} || [];

    # Ensure roles are an array reference
    if (ref $roles ne 'ARRAY') {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'begin', "Invalid or undefined roles in session for user: " . ($c->session->{username} || 'Guest'));

        # Stash the current path so it can be used for redirection after login
        $c->stash->{template} = $c->req->uri;

        # Set error message for session problems
        $c->stash->{error_msg} = "Session expired or invalid. Please log in again.";

        # Redirect to login
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'begin', "Redirecting to login page due to missing or invalid roles.");
        $c->res->redirect($c->uri_for('/login'));
        $c->detach;
    }

    # Check if the user has the 'admin' role
    unless (grep { $_ eq 'admin' } @$roles) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'begin', "Unauthorized access attempt by user: " . ($c->session->{username} || 'Guest'));

        # Stash the current path for potential use
        $c->stash->{redirect_to} = $c->req->uri;

        # Redirect unauthorized users to the home page with an error message
        $c->stash->{error_msg} = "Unauthorized access. You do not have permission to view this page.";
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'begin', "Redirecting unauthorized user to the home page.");
        $c->res->redirect($c->uri_for('/'));
        $c->detach;
    }

    # If we get here, the user is authorized
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'begin', "User authorized to access Todo: " . ($c->session->{username} || 'Guest'));
}

sub index :Path(/todo) :Args(0) {
    my ( $self, $c ) = @_;

    # Retrieve all of the todo records as todo model objects and store in the stash
    $c->stash(todos => [$c->model('DB::Todo')->all]);

    # Set the TT template to use.
    $c->stash(template => 'todo/todo.tt');
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 'Fetched todos for the, todo page');
    $c->forward($c->view('TT'));
}
sub auto :Private {
    my ($self, $c) = @_;

    # Check if the user is logged in and is an admin
      unless (defined $c->session->{username} && grep { $_ eq 'admin' } @{$c->session->{roles}}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'auto', "Unauthorized access attempt to Todo controller");
        $c->response->redirect($c->uri_for('/'));
        return 0;
    }

 $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'auto', "User authorized to access Todo controller");
    return 1;
}

# You
sub todo :Path('/todo') :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'todo', 'Fetching todos for the todo page');
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
    my ($self, $c) = @_;

    # Logging the start of the addtodo method
    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'addtodo', 'Initiating addtodo subroutine'
    );

    # Fetch project data from the Project Controller
    my $project_controller = $c->controller('Project');
    my $projects = $project_controller->fetch_projects_with_subprojects($c);

    # Fetch the project_id from query parameters (if any)
    my $project_id = $c->request->query_parameters->{project_id};
    my $current_project;

    # Attempt to locate the current project based on project_id
    if ($project_id) {
        my $schema = $c->model('DBEncy');
        $current_project = $schema->resultset('Project')->find($project_id);
        if ($current_project) {
            $self->logging->log_with_details(
                $c, 'info', __FILE__, __LINE__, 'addtodo',
                "Located current project with ID: $project_id (" . $current_project->name . ")"
            );
        } else {
            $self->logging->log_with_details(
                $c, 'warn', __FILE__, __LINE__, 'addtodo',
                "Invalid project ID passed in query: $project_id"
            );
        }
    }

    # Fetch all users to populate the user drop-down
    my $schema = $c->model('DBEncy');
    my @users = $schema->resultset('User')->search({}, { order_by => 'id' });

    # Log a message confirming users were fetched
    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'addtodo',
        'Fetched users to populate user_id dropdown'
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
    @users = $schema->resultset('User')->all;

    # Log the list of user_ids
    my @user_ids = map { $_->id } @users;
    $self->logging->log_with_details($c, __FILE__, __LINE__, 'addtodo', 'User IDs: ' . join(', ', @user_ids));

    # Add the projects, sitename, and user_id to the stash
    $c->stash(
        projects        => $projects,        # Parent projects with nested sub-projects
        current_project => $current_project, # Selected project for the form (if any)
        users           => \@users,          # List of users to populate dropdown
        template        => 'todo/addtodo.tt' # Template for rendering
    );

    # Log the end of the addtodo subroutine
    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'addtodo', 'Completed addtodo subroutine'
    );
}

sub debug :Local {
    my ($self, $c) = @_;

    # Print the @INC path
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'debug', "INC: " . join(", ", @INC));

    # Check if the DateTime plugin is installed
    my $is_installed = eval {
        require Template::Plugin::DateTime;
        1;
    };
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'debug', "DateTime plugin is " . ($is_installed ? "" : "not ") . "installed");

    $c->response->body("Debugging information has been logged");
}
sub modify :Path('/todo/modify') :Args(1) {
    my ( $self, $c, $record_id ) = @_;

    # Log the entry into the modify action
    $self->logging->log_with_details(
        $c,
        'info',
        __FILE__,
        __LINE__,
        'modify',
        "Entered modify action for record_id: " . ( $record_id || 'undefined' )
    );

    # Error handling for record_id
    unless ($record_id) {
        $self->logging->log_with_details(
            $c,
            'error',
            __FILE__,
            __LINE__,
            'modify.record_id',
            'Record ID is missing in the URL.'
        );
        $c->stash(
            error_msg => 'Record ID is required but was not provided.',
            form_data => $c->request->params, # Preserve form values
            template  => 'todo/details.tt',    # Re-render the form
        );
        return; # Return to allow the user to fix the error
    }

    # Initialize the schema to fetch data
    my $schema = $c->model('DBEncy');

    # Fetch the todo item with the given record_id
    my $todo = $schema->resultset('Todo')->find($record_id);

    if (!$todo) {
        $self->logging->log_with_details(
            $c,
            'error',
            __FILE__,
            __LINE__,
            'modify.record_not_found',
            "Todo item not found for record ID: $record_id."
        );
        $c->stash(
            error_msg => "No todo item found for record ID: $record_id.",
            form_data => $c->request->params, # Preserve form values
            template  => 'todo/details.tt',    # Re-render the form
        );
        return;
    }

    # Retrieve form data from the user's request
    my $form_data = $c->request->params;

    # Log form data for debugging
    $self->logging->log_with_details(
        $c,
        'debug',
        __FILE__,
        __LINE__,
        'modify.form_data',
        "Form data received: " . join(", ", map { "$_: $form_data->{$_}" } keys %$form_data)
    );

    # Validate mandatory fields (example: "sitename" is required)
    unless ($form_data->{sitename}) {
        $self->logging->log_with_details(
            $c,
            'warn',
            __FILE__,
            __LINE__,
            'modify.validation',
            'Sitename is required but missing in the form data.'
        );
        $c->stash(
            error_msg => 'Sitename is required. Please provide it.',
            form_data => $form_data,          # Preserve form values
            record    => $todo,              # Pass the current todo item
            template  => 'todo/details.tt',   # Re-render the form
        );
        return; # Early exit to allow the user to fix the error
    }

    # Declare and initialize variables with form data or defaults
    my $parent_todo = $form_data->{parent_todo} || $todo->parent_todo || '';
    my $accumulative_time = $form_data->{accumulative_time} || 0;

    # Log the start of the update process
    $self->logging->log_with_details(
        $c,
        'info',
        __FILE__,
        __LINE__,
        'modify.update',
        "Updating todo item with record ID: $record_id."
    );

    # Attempt to update the todo record
    eval {
        $todo->update({
            sitename             => $form_data->{sitename},
            start_date           => $form_data->{start_date},
            parent_todo          => $parent_todo,
            due_date             => $form_data->{due_date} || DateTime->now->add(days => 7)->ymd,
            subject              => $form_data->{subject},
            description          => $form_data->{description},
            estimated_man_hours  => $form_data->{estimated_man_hours},
            comments             => $form_data->{comments},
            accumulative_time    => $accumulative_time,
            reporter             => $form_data->{reporter},
            company_code         => $form_data->{company_code},
            owner                => $form_data->{owner},
            developer            => $form_data->{developer},
            username_of_poster   => $c->session->{username},
            status               => $form_data->{status},
            priority             => $form_data->{priority},
            share                => $form_data->{share} || 0,
            last_mod_by          => $c->session->{username} || 'system',
            last_mod_date        => DateTime->now->ymd,
            user_id              => $form_data->{user_id} || 1,
            project_id           => $form_data->{project_id},
            date_time_posted     => $form_data->{date_time_posted},
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
    };
    if ($@) {
        $self->logging->log_with_details(
            $c,
            'error',
            __FILE__,
            __LINE__,
            'modify.update_failure',
            "Failed to update todo item for record ID: $record_id. Error: $@"
        );
        $c->stash(
            error_msg => "An error occurred while updating the record: $@",
            form_data => $form_data,          # Preserve form values
            record    => $todo,              # Pass the current todo item
            template  => 'todo/details.tt',   # Re-render the form
        );
        return; # Early exit on database error
    }

        # Redirect the user back to the page they came from
        my $referer = $c->request->referer || $c->uri_for($self->action_for('list_todos'));
        $c->response->redirect($referer);
    } else {
        # The todo was not found, so display an error message
        $c->response->body('Todo not found');
    }
    # Log the successful update
    $self->logging->log_with_details(
        $c,
        'info',
        __FILE__,
        __LINE__,
        'modify.success',
        "Todo item successfully updated for record ID: $record_id."
    );

    # Handle successful update
    $c->stash(
        success_msg => "Todo item with ID $record_id has been successfully updated.",
        record      => $todo,             # Provide updated data
        template    => 'todo/details.tt',  # Redirect back to the form for review
    );
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
    my $last_mod_by = $c->session->{username} || 'default_user';
    my $last_mod_date = $c->request->params->{last_mod_date};
    my $group_of_poster = $c->session->{roles} || 'default_group';
    my $project_id = $c->request->params->{project_id};
    my $manual_project_id = $c->request->params->{manual_project_id};
    my $date_time_posted = $c->request->params->{date_time_posted};

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
        due_date => $due_date,
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
