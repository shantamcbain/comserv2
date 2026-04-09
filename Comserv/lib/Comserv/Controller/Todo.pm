package Comserv::Controller::Todo;
use Moose;
use namespace::autoclean;
use DateTime::Format::ISO8601;
use Data::Dumper;
use Comserv::Util::Logging; # Import the logging utility
BEGIN { extends 'Catalyst::Controller'; }

# Helper method to get status name from code
sub get_status_name {
    my ($self, $status_code) = @_;
    my %status_map = (
        1 => 'NEW',
        2 => 'IN PROGRESS',
        3 => 'DONE'
    );
    return $status_map{$status_code} // "Unknown ($status_code)";
}

# Helper method to get priority name from code (1-10 scale)
sub get_priority_name {
    my ($self, $priority_code) = @_;
    my %priority_map = (
        1  => 'Critical',
        2  => 'When we have time', 
        3  => 'Urgent',
        4  => 'High',
        5  => 'Medium',
        6  => 'Medium-Low', 
        7  => 'Low',
        8  => 'Very Low',
        9  => 'Minimal',
        10 => 'Optional'
    );
    return $priority_map{$priority_code} // "Priority $priority_code";
}

# Helper method to convert numeric status to string for database storage
sub convert_status_to_string {
    my ($self, $status_code) = @_;
    my %status_map = (
        1 => 'NEW',
        2 => 'IN PROGRESS', 
        3 => 'DONE'
    );
    return $status_map{$status_code} // $status_code;
}

# Helper method to filter todos by date range
sub filter_todos_by_date_range {
    my ($self, $c, $todos, $start_date, $end_date, $include_overdue) = @_;
    
    $include_overdue //= 1; # Default to include overdue todos
    
    my @filtered_todos = grep { 
        my $todo = $_;
        my $include_todo = 0;
        
        # Include if starting within date range
        if ($todo->start_date && $todo->start_date ge $start_date && $todo->start_date le $end_date) {
            $include_todo = 1;
        }
        
        # Include if due within date range
        if ($todo->due_date && $todo->due_date ge $start_date && $todo->due_date le $end_date) {
            $include_todo = 1;
        }
        
        # Include overdue todos if requested (overdue = due before start_date and not completed)
        if ($include_overdue && $todo->due_date && $todo->due_date lt $start_date && $todo->status != 3) {
            $include_todo = 1;
        }
        
        $include_todo;
    } @$todos;
    
    return \@filtered_todos;
}
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

    # Check if the user has the 'admin' or 'developer' role
    unless (grep { $_ eq 'admin' || $_ eq 'developer' } @$roles) {
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

    # Check if the user is logged in and has admin or developer role
    unless (defined $c->session->{username} && grep { $_ eq 'admin' || $_ eq 'developer' } @{$c->session->{roles}}) {
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
    my $sitename_filter = $c->request->query_parameters->{sitename} || '';

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object
    my $rs = $schema->resultset('Todo');

    # Build the search conditions
    my $search_conditions = {};
    
    # Handle sitename filtering
    if ($sitename_filter && $sitename_filter ne 'all') {
        $search_conditions->{sitename} = $sitename_filter;
    } else {
        # Default to user's current site if no specific site filter is applied
        $search_conditions->{sitename} = $c->session->{SiteName};
    }

    # Only show non-completed todos by default (unless explicitly filtering for completed)
    if ($status_filter eq 'completed') {
        $search_conditions->{status} = 3;  # completed status (numeric)
    } elsif ($status_filter eq 'in_progress') {
        $search_conditions->{status} = 2;  # in progress status (numeric)
    } elsif ($status_filter eq 'new') {
        $search_conditions->{status} = 1;  # new status (numeric)
    } elsif ($status_filter ne 'all') {
        $search_conditions->{status} = { '!=' => 3 };  # exclude completed todos (numeric)
    }

    # Add project filter if specified
    if ($project_id) {
        $search_conditions->{project_id} = $project_id;
    }

    # Apply date filters first
    my $now = DateTime->now;
    my $today = $now->ymd;
    my $date_conditions = [];

    if ($filter_type eq 'day' || $filter_type eq 'today') {
        # Today's todos: show todos that are due today, start today, or are active and overdue
        $date_conditions = [
            { due_date => $today },                    # Due today
            { start_date => $today },                  # Starting today
            { '-and' => [                              # Overdue but not completed
                { due_date => { '<' => $today } },
                { status => { '!=' => 3 } }
            ]}
        ];
    } elsif ($filter_type eq 'week') {
        # This week's todos
        my $start_of_week = $now->clone->subtract(days => $now->day_of_week - 1)->ymd;
        my $end_of_week = $now->clone->add(days => 7 - $now->day_of_week)->ymd;

        push @$date_conditions, {
            '-and' => [
                { start_date => { '<=' => $end_of_week } },
                { '-or' => [
                    { due_date => { '>=' => $start_of_week } },
                    { status => { '!=' => 3 } }  # Not completed
                ]}
            ]
        };
    } elsif ($filter_type eq 'month') {
        # This month's todos
        my $start_of_month = $now->clone->set_day(1)->ymd;
        my $end_of_month = $now->clone->set_day($now->month_length)->ymd;

        push @$date_conditions, {
            '-and' => [
                { start_date => { '<=' => $end_of_month } },
                { '-or' => [
                    { due_date => { '>=' => $start_of_month } },
                    { status => { '!=' => 3 } }  # Not completed
                ]}
            ]
        };
    }

    # Combine search and date conditions properly
    if ($search_term && @$date_conditions) {
        # Both search and date filters - combine with AND logic
        $search_conditions->{'-and'} = [
            { '-or' => [
                { subject => { 'like', "%$search_term%" } },
                { description => { 'like', "%$search_term%" } },
                { comments => { 'like', "%$search_term%" } }
            ]},
            { '-or' => $date_conditions }
        ];
    } elsif ($search_term) {
        # Only search term - use OR logic for search fields
        $search_conditions->{'-or'} = [
            { subject => { 'like', "%$search_term%" } },
            { description => { 'like', "%$search_term%" } },
            { comments => { 'like', "%$search_term%" } }
        ];
    } elsif (@$date_conditions) {
        # Only date filter - use OR logic for date conditions
        $search_conditions->{'-or'} = $date_conditions;
    }

    # Fetch todos with the applied filters
    my @todos = $rs->search(
        $search_conditions,
        { order_by => { -asc => ['priority', 'start_date'] } }
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

    # Fetch all sites for the filter dropdown (only for CSC admins)
    my $sites = [];
    my $is_csc_admin = 0;
    my $roles = $c->session->{roles} || [];
    if (grep { $_ eq 'admin' } @$roles) {
        $is_csc_admin = 1;
        eval {
            my $site_model = $c->model('Site');
            if ($site_model) {
                $sites = $site_model->get_all_sites($c) || [];
            }
        };

        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'todo',
                "Error fetching sites: $@");
        }
    }

    # Process todos to add status and priority names
    my @processed_todos;
    foreach my $todo (@todos) {
        my %todo_data = $todo->get_columns;
        $todo_data{status_name} = $self->get_status_name($todo->status);
        $todo_data{priority_name} = $self->get_priority_name($todo->priority);
        push @processed_todos, \%todo_data;
    }

    # Add the todos and filter info to the stash
    $c->stash(
        todos => \@processed_todos,
        sitename => $c->session->{SiteName},
        filter_type => $filter_type,
        search_term => $search_term,
        project_id => $project_id,
        status_filter => $status_filter,
        sitename_filter => $sitename_filter,
        projects => $projects,
        sites => $sites,
        is_csc_admin => $is_csc_admin,
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

        # Fetch project data for the project dropdown
        my $project_controller = $c->controller('Project');
        my $projects = [];
        eval {
            # Ensure we fetch projects for the same site as the todo record
            my $orig_site = $c->session->{SiteName};
            if ($todo && $todo->sitename) {
                $c->session->{SiteName} = $todo->sitename;
            }
            $projects = $project_controller->fetch_projects_with_subprojects($c) || [];
            # Restore original site after fetching
            $c->session->{SiteName} = $orig_site;
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'details',
                "Error fetching projects: $@");
        }

        # Fetch AI conversations linked to this task
        my @ai_conversations;
        eval {
            @ai_conversations = $schema->resultset('AiConversation')->search(
                { task_id => $record_id },
                { order_by => { -desc => 'updated_at' }, rows => 10 }
            );
        };
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'details',
                "Failed to fetch AI conversations for task $record_id: $@");
        }

        # Add the todo, accumulative_time, and projects to the stash
        $c->stash(
            record            => $todo, 
            accumulative_time => $accumulative_time,
            projects          => $projects,
            ai_conversations  => \@ai_conversations,
        );

        # Set the template to 'todo/details.tt'
        $c->stash(template => 'todo/details.tt');
    } else {
        # Handle the case where the todo is not found
        $c->response->body('Todo not found');
    }
}

sub add_project :Path('/todo/add_project') :Args(0) {
    my ($self, $c) = @_;
    
    # Log the action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_project', 
        'Redirecting to add_project form from todo context');
    
    # Forward to the Project controller's add_project action
    $c->forward('/project/addproject');
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

    # Build priority and status mappings for dropdowns
    my %priority_options = (
        1  => 'Critical',
        2  => 'When we have time', 
        3  => 'Urgent',
        4  => 'High',
        5  => 'Medium',
        6  => 'Medium-Low', 
        7  => 'Low',
        8  => 'Very Low',
        9  => 'Minimal',
        10 => 'Optional'
    );
    
    my %status_options = (
        1 => 'NEW',
        2 => 'IN PROGRESS',
        3 => 'DONE'
    );

    # Add the projects, sitename, and users to the stash
    $c->stash(
        projects        => $projects,        # Parent projects with nested sub-projects
        current_project => $current_project, # Selected project for the form (if any)
        users           => \@users,          # List of users to populate dropdown
        build_priority  => \%priority_options, # Priority options for dropdown
        build_status    => \%status_options,   # Status options for dropdown
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

    # Build priority and status mappings for dropdowns
    my %priority_options = (
        1  => 'Critical',
        2  => 'When we have time', 
        3  => 'Urgent',
        4  => 'High',
        5  => 'Medium',
        6  => 'Medium-Low', 
        7  => 'Low',
        8  => 'Very Low',
        9  => 'Minimal',
        10 => 'Optional'
    );
    
    my %status_options = (
        1 => 'NEW',
        2 => 'IN PROGRESS',
        3 => 'DONE'
    );

    # Add the todo, projects, and users to the stash
    $c->stash(
        record           => $todo,
        projects         => $projects,
        users            => \@users,
        accumulative_time => $accumulative_time,
        build_priority   => \%priority_options, # Priority options for dropdown
        build_status     => \%status_options,   # Status options for dropdown
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
            project_id           => $form_data->{project_id},
            date_time_posted     => $form_data->{date_time_posted},
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
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create', 'Creating new todo item');

    # Retrieve and validate required fields
    my @required_fields = ('subject', 'start_date', 'due_date', 'priority', 'status');
    my $params = $c->request->params;
    
    # Log all received parameters for debugging
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create', 
        "Received parameters: " . join(', ', map { "$_=" . ($params->{$_} // 'undef') } keys %$params));
    
    # Validate required fields
    my @missing_fields = grep { !defined $params->{$_} || $params->{$_} eq '' } @required_fields;
    if (@missing_fields) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create', 
            "Missing required fields: " . join(', ', @missing_fields));
        $c->stash->{error_msg} = "Missing required fields: " . join(', ', @missing_fields);
        $c->stash->{template} = 'todo/addtodo.tt';
        $c->detach();
    }

    # Set default values
    my $schema = $c->model('DBEncy');
    my $current_user = $c->session->{username} || 'system';
    my $current_date = DateTime->now->ymd;
    
    # Process project information
    my $selected_project_id = $params->{manual_project_id} || $params->{project_id};
    my $project_code = 'default_code';
    
    # If no project ID provided, get a default project or create one
    if (!$selected_project_id || $selected_project_id eq '') {
        eval {
            # Try to find a default project
            my $default_project = $schema->resultset('Project')->search({
                -or => [
                    { project_name => 'Default' },
                    { project_code => 'default_code' }
                ]
            })->first;
            
            if ($default_project) {
                $selected_project_id = $default_project->id;
                $project_code = $default_project->project_code;
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create', 
                    "Using default project ID: $selected_project_id, code: $project_code");
            } else {
                # Set to 1 as fallback (assume project ID 1 exists)
                $selected_project_id = 1;
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create', 
                    "No project specified, using fallback project ID: $selected_project_id");
            }
        };
        if ($@) {
            $selected_project_id = 1; # Final fallback
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create', 
                "Error finding default project, using fallback: $@");
        }
    } else {
        eval {
            my $project = $schema->resultset('Project')->find($selected_project_id);
            $project_code = $project->project_code if $project;
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create', 
                "Using project ID: $selected_project_id, code: $project_code");
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create', 
                "Error fetching project: $@");
        }
    }

    # Validate and format dates
    my ($start_date, $due_date);
    eval {
        # HTML date inputs come in YYYY-MM-DD format, no need to parse as ISO8601
        if ($params->{start_date} && $params->{start_date} =~ /^\d{4}-\d{2}-\d{2}$/) {
            $start_date = $params->{start_date};
        }
        if ($params->{due_date} && $params->{due_date} =~ /^\d{4}-\d{2}-\d{2}$/) {
            $due_date = $params->{due_date};
        }
        
        if ($start_date && $due_date && $start_date gt $due_date) {
            die "Start date cannot be after due date";
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create', 
            "Date validation failed: $@");
        $c->stash->{error_msg} = "Invalid date: $@";
        $c->stash->{template} = 'todo/addtodo.tt';
        $c->detach();
    }

    # Process accumulative time
    my $accumulative_time = 0;
    if (defined $params->{accumulative_time} && $params->{accumulative_time} =~ /^\d+$/) {
        $accumulative_time = $params->{accumulative_time};
    }

    # Get user info
    my $user_id = $c->session->{user_id};
    unless ($user_id) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create', 
            'User ID not found in session');
        $c->stash->{error_msg} = 'User not authenticated';
        $c->stash->{template} = 'user/login.tt';
        $c->detach();
    }

    # Create a new todo record with error handling
    my $todo;
    
    # Log the data being inserted for debugging
    my $insert_data = {
        sitename => $c->session->{SiteName} || 'default_site',
        start_date => $start_date,
        parent_todo => $params->{parent_todo} || '',
        due_date => $due_date,
        subject => $params->{subject},
        description => $params->{description} || '',
        estimated_man_hours => $params->{estimated_man_hours} || 0,
        comments => $params->{comments} || '',
        accumulative_time => $accumulative_time,
        reporter => $params->{reporter} || $current_user,
        company_code => $params->{company_code} || 'default',
        owner => $params->{owner} || $current_user,
        project_code => $project_code,
        developer => $params->{developer} || $current_user,
        username_of_poster => $current_user,
        status => $self->convert_status_to_string($params->{status}) || 'NEW',
        priority => $params->{priority} || 3, # Medium priority by default
        share => $params->{share} ? 1 : 0,
        last_mod_by => $current_user,
        last_mod_date => $current_date,
        user_id => $user_id,
        group_of_poster => (ref $c->session->{roles} eq 'ARRAY' && @{$c->session->{roles}}) 
                          ? $c->session->{roles}->[0] 
                          : 'user',
        project_id => $selected_project_id,
        date_time_posted => $params->{date_time_posted} || $current_date,
    };
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create', 
        "About to create todo with data: " . Dumper($insert_data));
    
    eval {
        $todo = $schema->resultset('Todo')->create($insert_data);
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create', 
            "Successfully created todo with ID: " . $todo->id);
            
    };
    
    # Check for errors from eval
    if ($@) {
        my $error = $@;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create', 
            "Failed to create todo: $error");
        $c->stash->{error_msg} = "Failed to create todo: $error";
        $c->stash->{template} = 'todo/addtodo.tt';
        $c->detach();
    }

    # Redirect to the todo list with success message
    $c->flash->{success_msg} = "Successfully created todo: " . $todo->subject;
    $c->response->redirect($c->uri_for($self->action_for('todo')));
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
    my $schema = $c->model('DBEncy');

    # Fetch ALL todos for the site for calendar view
    my $todos = $todo_model->get_all_todos_for_calendar($c, $c->session->{SiteName});

    # Filter todos for the given day using the shared method
    my $filtered_todos = $self->filter_todos_by_date_range($c, $todos, $date, $date, 1);
    
    # Debug logging
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'day', 
        "Filtering for date: $date, Total todos: " . scalar(@$todos) . ", Filtered todos: " . scalar(@$filtered_todos));
    
    if ($c->session->{debug_mode}) {
        foreach my $todo (@$todos) {
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'day', 
                "Todo: " . $todo->subject . ", Start: " . ($todo->start_date || 'NULL') . 
                ", Due: " . ($todo->due_date || 'NULL') . ", Status: " . $todo->status);
        }
    }

    # Fetch AI conversations active on this date for privileged users
    my @ai_daily_conversations;
    my $user_roles_day = $c->session->{roles} || [];
    if (!ref($user_roles_day)) {
        $user_roles_day = [split(/\s*,\s*/, $user_roles_day)] if $user_roles_day;
    }
    my $can_see_ai_day = ref($user_roles_day) eq 'ARRAY'
        ? grep { $_ =~ /^(admin|developer|editor)$/i } @$user_roles_day
        : 0;

    if ($can_see_ai_day) {
        eval {
            my $day_start = $date . ' 00:00:00';
            my $day_end   = $date . ' 23:59:59';
            @ai_daily_conversations = $schema->resultset('AiConversation')->search(
                {
                    updated_at => {
                        '>=' => $day_start,
                        '<=' => $day_end,
                    }
                },
                {
                    order_by => { -desc => 'updated_at' },
                    prefetch => 'project',
                }
            );
        };
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'day',
                "Failed to fetch AI conversations for date $date: $@");
        }
    }

    # Add the todos to the stash
    $c->stash(
        todos                  => $filtered_todos,
        sitename               => $c->session->{SiteName},
        date                   => $date,
        previous_date          => $previous_date,
        next_date              => $next_date,
        ai_daily_conversations => \@ai_daily_conversations,
        template               => 'todo/day.tt',
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

    # Calculate previous and next week dates
    my $prev_week_date = $dt->clone->subtract(days => 7)->strftime('%Y-%m-%d');
    my $next_week_date = $dt->clone->add(days => 7)->strftime('%Y-%m-%d');
    
    # Create the week start DateTime object adjusted to Sunday for template use
    # start_of_week is Monday-based, so we need to go back to the Sunday before
    my $start_dt = DateTime::Format::ISO8601->parse_datetime($start_of_week);
    # Go back to Sunday (day_of_week 7, but we want to go back 1 day from Monday)
    $start_dt = $start_dt->subtract(days => 1);
    
    # Generate array of dates for the week (7 days starting from Sunday)
    my @week_dates = ();
    for my $day_offset (0..6) {
        my $current_date = $start_dt->clone->add(days => $day_offset);
        push @week_dates, {
            date_str => $current_date->strftime('%Y-%m-%d'),
            day_num => $current_date->day,
            is_today => ($current_date->strftime('%Y-%m-%d') eq DateTime->now->strftime('%Y-%m-%d')),
        };
    }

    # Fetch ALL todos for the site for calendar view
    my $todos = $todo_model->get_all_todos_for_calendar($c, $c->session->{SiteName});

    # Filter todos for the given week using the shared method
    my $filtered_todos = $self->filter_todos_by_date_range($c, $todos, $start_of_week, $end_of_week, 1);

    # Add the todos to the stash
    $c->stash(
        todos => $filtered_todos,
        sitename => $c->session->{SiteName},
        start_of_week => $start_of_week,
        end_of_week => $end_of_week,
        prev_week_date => $prev_week_date,
        next_week_date => $next_week_date,
        week_dates => \@week_dates,
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

    # Fetch ALL todos for the site for calendar view
    my $todos = $todo_model->get_all_todos_for_calendar($c, $c->session->{SiteName});

    # Filter todos for the given month using the shared method
    my $filtered_todos = $self->filter_todos_by_date_range($c, $todos, $start_of_month, $end_of_month, 1);

    # Organize todos by day of month (use due_date if available, otherwise start_date)
    my %todos_by_day;
    foreach my $todo (@$filtered_todos) {
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

    # Get today's date for highlighting
    my $today = DateTime->now->ymd;

    # Add the todos and calendar to the stash
    $c->stash(
        todos => $filtered_todos,
        calendar => \@calendar,
        sitename => $c->session->{SiteName},
        month_name => $dt->month_name,
        year => $dt->year,
        start_of_month => $start_of_month,
        end_of_month => $end_of_month,
        prev_month_date => $prev_month_date,
        next_month_date => $next_month_date,
        today => $today,
        template => 'todo/month.tt',
    );

    $c->forward($c->view('TT'));
}
1;
