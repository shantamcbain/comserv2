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
        $c->res->redirect($c->uri_for('/user/login'));
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

# Main todo action with filtering capabilities
sub todo :Path('/todo') :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'todo', 'Fetching todos for the todo page');

    # Get filter parameters from query string
    my $filter_type = $c->request->query_parameters->{filter} || 'all';
    my $search_term = $c->request->query_parameters->{search} || '';
    my $project_id = $c->request->query_parameters->{project_id} || '';
    my $status_filter = $c->request->query_parameters->{status} || '';

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object
    my $rs = $schema->resultset('Todo');

    # Build the search conditions
    my $search_conditions = {
        'me.sitename' => $c->session->{SiteName},  # filter by site (specify table alias)
    };

    # Only show non-completed todos by default (unless explicitly filtering for completed)
    if ($status_filter eq 'completed') {
        $search_conditions->{'me.status'} = 3;  # completed status
    } elsif ($status_filter eq 'in_progress') {
        $search_conditions->{'me.status'} = 2;  # in progress status
    } elsif ($status_filter eq 'new') {
        $search_conditions->{'me.status'} = 1;  # new status
    } elsif ($status_filter ne 'all') {
        $search_conditions->{'me.status'} = { '!=' => 3 };  # exclude completed todos
    }

    # Add project filter if specified
    if ($project_id) {
        $search_conditions->{'me.project_id'} = $project_id;
    }

    # Add search term filter if specified
    if ($search_term) {
        $search_conditions->{'-or'} = [
            { 'me.subject' => { 'like', "%$search_term%" } },
            { 'me.description' => { 'like', "%$search_term%" } },
            { 'me.comments' => { 'like', "%$search_term%" } }
        ];
    }

    # Apply date filters
    my $now = DateTime->now;
    my $today = $now->ymd;

    if ($filter_type eq 'day' || $filter_type eq 'today') {
        # Today's todos: show todos that are due today, start today, or are active and overdue
        $search_conditions->{'-or'} = [
            { 'me.due_date' => $today },                    # Due today
            { 'me.start_date' => $today },                  # Starting today
            { '-and' => [                              # Overdue but not completed
                { 'me.due_date' => { '<' => $today } },
                { 'me.status' => { '!=' => 3 } }
            ]}
        ];
    } elsif ($filter_type eq 'week') {
        # This week's todos
        my $start_of_week = $now->clone->subtract(days => $now->day_of_week - 1)->ymd;
        my $end_of_week = $now->clone->add(days => 7 - $now->day_of_week)->ymd;

        $search_conditions->{'-and'} = [
            { 'me.start_date' => { '<=' => $end_of_week } },
            { '-or' => [
                { 'me.due_date' => { '>=' => $start_of_week } },
                { 'me.status' => { '!=' => 3 } }  # Not completed
            ]}
        ];
    } elsif ($filter_type eq 'month') {
        # This month's todos
        my $start_of_month = $now->clone->set_day(1)->ymd;
        my $end_of_month = $now->clone->set_day($now->month_length)->ymd;

        $search_conditions->{'-and'} = [
            { 'me.start_date' => { '<=' => $end_of_month } },
            { '-or' => [
                { 'me.due_date' => { '>=' => $start_of_month } },
                { 'me.status' => { '!=' => 3 } }  # Not completed
            ]}
        ];
    }

    # Fetch todos with the applied filters
    my @todos = $rs->search(
        $search_conditions,
        { 
            order_by => { -asc => ['me.priority', 'me.start_date'] },
            prefetch => 'project'  # Include project data for better integration
        }
    );

    # Fetch all projects for the filter dropdown
    my $projects = [];
    eval {
        my $project_controller = $c->controller('Project');
        if ($project_controller) {
            $projects = $project_controller->fetch_projects_with_subprojects($c) || [];
        }
    };

    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'todo',
            "Error fetching projects: $@");
    }

    # Get overdue todos for dashboard
    my $overdue_todos = $self->get_overdue_todos($c);

    # Add the todos and filter info to the stash
    $c->stash(
        todos => \@todos,
        sitename => $c->session->{SiteName},
        filter_type => $filter_type,
        search_term => $search_term,
        project_id => $project_id,
        status_filter => $status_filter,
        projects => $projects,
        overdue_todos => $overdue_todos,
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

    # Add the projects, sitename, and users to the stash
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

sub edit :Path('/todo/edit') :Args(1) {
    my ($self, $c, $record_id) = @_;

    # Log the entry into the edit action
    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'edit',
        "Entered edit action for record_id: " . ($record_id || 'undefined')
    );

    # Error handling for record_id
    unless ($record_id) {
        $self->logging->log_with_details(
            $c, 'error', __FILE__, __LINE__, 'edit.record_id',
            'Record ID is missing in the URL.'
        );
        $c->stash(
            error_msg => 'Record ID is required but was not provided.',
            template  => 'todo/todo.tt',
        );
        return;
    }

    # Initialize the schema to fetch data
    my $schema = $c->model('DBEncy');

    # Fetch the todo item with the given record_id
    my $todo = $schema->resultset('Todo')->find($record_id);

    if (!$todo) {
        $self->logging->log_with_details(
            $c, 'error', __FILE__, __LINE__, 'edit.record_not_found',
            "Todo item not found for record ID: $record_id."
        );
        $c->stash(
            error_msg => "No todo item found for record ID: $record_id.",
            template  => 'todo/todo.tt',
        );
        return;
    }

    # Fetch project data from the Project Controller
    my $project_controller = $c->controller('Project');
    my $projects = $project_controller->fetch_projects_with_subprojects($c);

    # Fetch all users to populate the user drop-down
    my @users = $schema->resultset('User')->search({}, { order_by => 'id' });

    # Calculate accumulative_time using the Log model
    my $log_model = $c->model('Log');
    my $accumulative_time_in_seconds = $log_model->calculate_accumulative_time($c, $record_id);

    # Convert accumulative_time from seconds to hours and minutes
    my $hours = int($accumulative_time_in_seconds / 3600);
    my $minutes = int(($accumulative_time_in_seconds % 3600) / 60);

    # Format the total time as 'HH:MM'
    my $accumulative_time = sprintf("%02d:%02d", $hours, $minutes);

    # Add the todo, projects, and users to the stash
    $c->stash(
        record           => $todo,
        projects         => $projects,
        users            => \@users,
        accumulative_time => $accumulative_time,
        template         => 'todo/edit.tt'
    );

    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'edit',
        "Successfully loaded edit form for record ID: $record_id"
    );
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
            project_id           => $form_data->{project_id} || $todo->project_id,
            date_time_posted     => $form_data->{date_time_posted},
        });
    };
    if ($@) {
        my $error_msg = $@;
        my $user_friendly_msg = "An error occurred while updating the record.";
        
        # Provide more specific error messages for common issues
        if ($error_msg =~ /Incorrect integer value.*for column.*project_id/) {
            $user_friendly_msg = "Invalid project selection. Please choose a valid project or leave it blank.";
        } elsif ($error_msg =~ /Incorrect integer value.*for column.*user_id/) {
            $user_friendly_msg = "Invalid user selection. Please choose a valid user.";
        } elsif ($error_msg =~ /Data too long for column/) {
            $user_friendly_msg = "One or more fields contain too much text. Please shorten your input.";
        } elsif ($error_msg =~ /cannot be null/) {
            $user_friendly_msg = "Required fields are missing. Please fill in all required information.";
        }
        
        $self->logging->log_with_details(
            $c,
            'error',
            __FILE__,
            __LINE__,
            'modify.update_failure',
            "Failed to update todo item for record ID: $record_id. Error: $error_msg"
        );
        
        # Send email notification to admin for database errors
        $self->_notify_admin_of_error($c, $record_id, $error_msg, $form_data);
        
        $c->stash(
            error_msg => $user_friendly_msg,
            technical_error => $error_msg,      # For debugging if needed
            form_data => $form_data,            # Preserve form values
            record    => $todo,                 # Pass the current todo item
            template  => 'todo/details.tt',     # Re-render the form
        );
        return; # Early exit on database error
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

    # Filter todos for the given day: due today or starting today only
    my @filtered_todos = grep { 
        ($_->due_date && $_->due_date eq $date) ||           # Due today
        ($_->start_date && $_->start_date eq $date)          # Starting today  
    } @$todos;
    
    # Debug logging
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'day', 
        "Filtering for date: $date, Total todos: " . scalar(@$todos) . ", Filtered todos: " . scalar(@filtered_todos));
    
    if ($c->session->{debug_mode}) {
        foreach my $todo (@$todos) {
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'day', 
                "Todo: " . $todo->subject . ", Start: " . ($todo->start_date || 'NULL') . 
                ", Due: " . ($todo->due_date || 'NULL') . ", Status: " . $todo->status);
        }
    }

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
    
    # Calculate start of week (Sunday)
    my $start_dt = $dt->clone;
    if ($start_dt->day_of_week != 7) { # If not Sunday
        $start_dt = $start_dt->subtract(days => $start_dt->day_of_week);
    }
    
    my $start_of_week = $start_dt->strftime('%Y-%m-%d');
    my $end_of_week = $start_dt->clone->add(days => 6)->strftime('%Y-%m-%d');

    # Calculate previous and next week dates
    my $prev_week_date = $start_dt->clone->subtract(days => 7)->strftime('%Y-%m-%d');
    my $next_week_date = $start_dt->clone->add(days => 7)->strftime('%Y-%m-%d');
    
    # Create week calendar structure with all 7 days
    my @week_days = ();
    for my $day_offset (0..6) {
        my $current_date = $start_dt->clone->add(days => $day_offset);
        push @week_days, {
            date => $current_date->strftime('%Y-%m-%d'),
            day_name => $current_date->day_name,
            day_number => $current_date->day,
            month_name => $current_date->month_name,
            is_today => ($current_date->ymd eq DateTime->now->ymd) ? 1 : 0
        };
    }

    # Fetch todos for the site within the week, ordered by start_date
    my $todos = $todo_model->get_top_todos($c, $c->session->{SiteName});

    # Filter todos for the given week: starting this week, due this week, or overdue but not completed
    my @filtered_todos = grep { 
        ($_->start_date && $_->start_date ge $start_of_week && $_->start_date le $end_of_week) ||  # Starting this week
        ($_->due_date && $_->due_date ge $start_of_week && $_->due_date le $end_of_week) ||      # Due this week
        ($_->due_date && $_->due_date lt $start_of_week && $_->status ne '3')                   # Overdue but not completed
    } @$todos;

    # Add the todos to the stash
    $c->stash(
        todos => \@filtered_todos,
        week_days => \@week_days,
        sitename => $c->session->{SiteName},
        start_of_week => $start_of_week,
        end_of_week => $end_of_week,
        prev_week_date => $prev_week_date,
        next_week_date => $next_week_date,
        template => 'todo/week.tt',
    );

    $c->forward($c->view('TT'));
}

sub month :Path('/todo/month') :Args {
    my ($self, $c, $date) = @_;

    # Get the Todo model
    my $todo_model = $c->model('Todo');

    # If no date is provided, use the current date
    if (!defined $date) {
        $date = DateTime->now->ymd;
    }

    # Parse the date
    my $dt = DateTime::Format::ISO8601->parse_datetime($date);

    # Calculate the start and end of the month
    my $start_of_month = $dt->clone->set_day(1)->strftime('%Y-%m-%d');
    my $end_of_month = $dt->clone->set_day($dt->month_length)->strftime('%Y-%m-%d');

    # Calculate previous and next month dates
    my $prev_month_date = $dt->clone->subtract(months => 1)->set_day(1)->strftime('%Y-%m-%d');
    my $next_month_date = $dt->clone->add(months => 1)->set_day(1)->strftime('%Y-%m-%d');

    # Fetch ALL todos for the site directly from database
    my $schema = $c->model('DBEncy');
    my @all_todos = $schema->resultset('Todo')->search(
        {
            'me.sitename' => $c->session->{SiteName},
        },
        { 
            order_by => { -asc => 'me.start_date' },
            prefetch => 'project'
        }
    );

    # Filter todos for the given month: starting this month, due this month, or overdue but not completed
    my @filtered_todos = grep { 
        ($_->start_date && $_->start_date ge $start_of_month && $_->start_date le $end_of_month) ||  # Starting this month
        ($_->due_date && $_->due_date ge $start_of_month && $_->due_date le $end_of_month) ||      # Due this month
        ($_->due_date && $_->due_date lt $start_of_month && $_->status ne '3')                     # Overdue but not completed
    } @all_todos;

    # Debug logging
    $c->log->info("Month view debug: Found " . scalar(@all_todos) . " total todos, " . scalar(@filtered_todos) . " filtered todos for month $start_of_month to $end_of_month");

    # Organize todos by day of month (use due_date if available, otherwise start_date)
    my %todos_by_day;
    
    foreach my $todo (@filtered_todos) {
        my $display_date = $todo->due_date || $todo->start_date;
        if ($display_date) {
            my $todo_date = DateTime::Format::ISO8601->parse_datetime($display_date);
            # Only add to calendar if the display date is within this month
            if ($todo_date->year == $dt->year && $todo_date->month == $dt->month) {
                my $day = $todo_date->day;
                push @{$todos_by_day{$day}}, $todo;
            }
        }
    }

    # Create a calendar structure
    my @calendar;
    my $first_day = DateTime->new(year => $dt->year, month => $dt->month, day => 1);
    my $day_of_week = $first_day->day_of_week % 7; # 0 for Sunday, 6 for Saturday

    # Add empty cells for days before the first day of the month
    for (my $i = 0; $i < $day_of_week; $i++) {
        push @calendar, { day => '', todos => [] };
    }

    # Add cells for each day of the month
    for (my $day = 1; $day <= $dt->month_length; $day++) {
        push @calendar, {
            day => $day,
            date => sprintf("%04d-%02d-%02d", $dt->year, $dt->month, $day),
            todos => $todos_by_day{$day} || []
        };
    }

    # Add the todos and calendar to the stash
    $c->stash(
        todos => \@filtered_todos,
        calendar => \@calendar,
        sitename => $c->session->{SiteName},
        month_name => $dt->month_name,
        year => $dt->year,
        start_of_month => $start_of_month,
        end_of_month => $end_of_month,
        prev_month_date => $prev_month_date,
        next_month_date => $next_month_date,
        template => 'todo/month.tt',
    );

    $c->forward($c->view('TT'));
}

# Get overdue todos for dashboard display
sub get_overdue_todos :Private {
    my ($self, $c) = @_;
    
    my $schema = $c->model('DBEncy');
    my $sitename = $c->session->{SiteName};
    my $today = DateTime->now->ymd;
    
    my @overdue_todos = $schema->resultset('Todo')->search(
        {
            'me.sitename' => $sitename,
            'me.due_date' => { '<' => $today },
            'me.status' => { '!=' => 3 } # Not completed
        },
        { 
            order_by => { -asc => 'me.due_date' },
            prefetch => 'project'
        }
    );
    
    return \@overdue_todos;
}

# Private method to notify admin of database errors
sub _notify_admin_of_error :Private {
    my ($self, $c, $record_id, $error_msg, $form_data) = @_;
    
    # Log the notification attempt
    $self->logging->log_with_details(
        $c,
        'info',
        __FILE__,
        __LINE__,
        'notify_admin',
        "Attempting to notify admin of database error for record ID: $record_id"
    );
    
    # Prepare error details for admin notification
    my $user = $c->session->{username} || 'Unknown User';
    my $sitename = $c->session->{SiteName} || 'Unknown Site';
    my $timestamp = DateTime->now->strftime('%Y-%m-%d %H:%M:%S');
    my $url = $c->req->uri;
    
    # Create a summary of form data (excluding sensitive information)
    my $form_summary = '';
    if ($form_data && ref $form_data eq 'HASH') {
        for my $key (sort keys %$form_data) {
            next if $key =~ /password|token|session/i; # Skip sensitive fields
            my $value = $form_data->{$key} || '';
            $value = substr($value, 0, 100) . '...' if length($value) > 100; # Truncate long values
            $form_summary .= "  $key: $value\n";
        }
    }
    
    my $error_details = qq{
Database Error in Todo System

Time: $timestamp
User: $user
Site: $sitename
URL: $url
Record ID: $record_id

Error Message:
$error_msg

Form Data Submitted:
$form_summary

This error has been logged and requires administrator attention.
    };
    
    # Try to send email notification if email system is available
    eval {
        if ($c->can('model') && $c->model('Email')) {
            $c->model('Email')->send(
                to      => 'admin@' . ($c->config->{domain} || 'localhost'),
                subject => "Database Error in Todo System - Record ID: $record_id",
                body    => $error_details,
            );
            
            $self->logging->log_with_details(
                $c,
                'info',
                __FILE__,
                __LINE__,
                'notify_admin.email_sent',
                "Admin notification email sent for record ID: $record_id"
            );
        }
    };
    
    if ($@) {
        $self->logging->log_with_details(
            $c,
            'warn',
            __FILE__,
            __LINE__,
            'notify_admin.email_failed',
            "Failed to send admin notification email: $@"
        );
    }
    
    # Always log the full error details for admin review
    $self->logging->log_with_details(
        $c,
        'error',
        __FILE__,
        __LINE__,
        'notify_admin.full_details',
        $error_details
    );
}

1;
