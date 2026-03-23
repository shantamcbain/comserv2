package Comserv::Controller::Todo;
use Moose;
use namespace::autoclean;
use DateTime;
use DateTime::Format::ISO8601;
use Data::Dumper;
use JSON::MaybeXS;
use Comserv::Util::Logging; # Import the logging utility
use Comserv::Util::ApiTokenValidator;
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
        
        # Include todos without any dates if they're not completed (for day view of today only)
        my $today = DateTime->now->ymd;
        if (!$todo->start_date && !$todo->due_date && $todo->status != 3 && $start_date eq $end_date && $start_date eq $today) {
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

    # Fetch roles: prefer stash (set by Root::auto, includes site-specific admin detection)
    my $roles = $c->stash->{user_roles} || $c->session->{roles} || [];

    # Ensure roles are an array reference
    if (ref $roles ne 'ARRAY') {
        $roles = [];
    }

    # Allow all roles above member: admin, developer, devops, editor, user, normal
    # Also allow if Root::auto set is_admin (catches site-specific admins from UserSiteRole)
    unless ($c->stash->{is_admin} || grep { lc($_) =~ /^(admin|developer|devops|editor|user|normal)$/ } @$roles) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'begin', "Unauthorized access attempt by user: " . ($c->session->{username} || 'Guest'));

        # Redirect unauthorized users to the login page with the return URL
        $c->res->redirect($c->uri_for('/user/login', { return_to => $c->req->uri }));
        $c->detach;
    }

    # If we get here, the user is authorized
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'begin', "User authorized to access Todo: " . ($c->session->{username} || 'Guest'));
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

        # Add the todo, accumulative_time, and projects to the stash
        $c->stash(
            record => $todo, 
            accumulative_time => $accumulative_time,
            projects => $projects,
            return_to => $c->request->params->{return_to} || $c->request->headers->referer || $c->uri_for($self->action_for('todo')),
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

    # Capture return URL from referer or parameter
    my $return_to = $c->request->params->{return_to} || $c->request->headers->referer || $c->uri_for($self->action_for('todo'));
    
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
        return_to       => $return_to,       # URL to return to after action
        start_date      => $c->request->params->{start_date} || DateTime->now->strftime('%Y-%m-%d'),
        time_of_day     => $c->request->params->{time_of_day},
        user_id         => $c->session->{user_id},  # Pre-select logged-in user
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

    # Capture return URL from referer or parameter
    my $return_to = $c->request->params->{return_to} || $c->request->headers->referer || $c->uri_for($self->action_for('todo'));

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
        return_to        => $return_to,         # URL to return to after action
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
            time_of_day          => $form_data->{time_of_day},
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
    $c->flash->{success_msg} = "Todo item with ID $record_id has been successfully updated.";
    
    if ($form_data->{return_to}) {
        $c->response->redirect($form_data->{return_to});
        $c->detach();
    }
    
    $c->stash(
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
        time_of_day => $params->{time_of_day},
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

    # Redirect to the todo list or return_to URL with success message
    $c->flash->{success_msg} = "Successfully created todo: " . $todo->subject;
    my $redirect_url = $params->{return_to} || $c->uri_for($self->action_for('todo'));
    
    # Handle the case where the return_to URL might already have a fragment
    # or ensure it's properly handled if coming from internal referer
    $c->response->redirect($redirect_url);
}

=head2 update_time

POST /todo/update_time - Update the time_of_day for a todo item (AJAX endpoint for drag-and-drop)

=cut

sub update_time :Path('/todo/update_time') :Args(0) {
    my ($self, $c) = @_;
    
    # Get parameters
    my $record_id = $c->request->params->{record_id};
    my $time_of_day = $c->request->params->{time_of_day};
    
    # Validate parameters
    unless ($record_id && $time_of_day) {
        $c->stash(
            json => {
                success => 0,
                error => 'Missing required parameters: record_id and time_of_day'
            }
        );
        $c->forward('View::JSON');
        return;
    }
    
    # Get the todo item
    my $schema = $c->model('DBEncy');
    my $todo = $schema->resultset('Todo')->find($record_id);
    
    unless ($todo) {
        $c->stash(
            json => {
                success => 0,
                error => "Todo not found: $record_id"
            }
        );
        $c->forward('View::JSON');
        return;
    }
    
    # Update the time_of_day
    eval {
        $todo->update({ time_of_day => $time_of_day });
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_time',
            "Updated time_of_day for todo $record_id to $time_of_day");
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_time',
            "Failed to update time_of_day for todo $record_id: $@");
        $c->stash(
            json => {
                success => 0,
                error => "Failed to update todo: $@"
            }
        );
        $c->forward('View::JSON');
        return;
    }
    
    # Return success
    $c->stash(
        json => {
            success => 1,
            message => 'Todo time updated successfully',
            todo_id => $record_id,
            new_time => $time_of_day
        }
    );
    $c->forward('View::JSON');
}

=head2 update_time_and_date

POST /todo/update_time_and_date - Update both time_of_day and start_date for a todo item (AJAX endpoint for week view drag-and-drop)

=cut

sub update_time_and_date :Path('/todo/update_time_and_date') :Args(0) {
    my ($self, $c) = @_;
    
    # Get parameters
    my $record_id = $c->request->params->{record_id};
    my $time_of_day = $c->request->params->{time_of_day};
    my $start_date = $c->request->params->{start_date};
    
    # Validate parameters
    unless ($record_id && $time_of_day && $start_date) {
        $c->stash(
            json => {
                success => 0,
                error => 'Missing required parameters: record_id, time_of_day, and start_date'
            }
        );
        $c->forward('View::JSON');
        return;
    }
    
    # Get the todo item
    my $schema = $c->model('DBEncy');
    my $todo = $schema->resultset('Todo')->find($record_id);
    
    unless ($todo) {
        $c->stash(
            json => {
                success => 0,
                error => "Todo not found: $record_id"
            }
        );
        $c->forward('View::JSON');
        return;
    }
    
    # Update both time_of_day and start_date
    eval {
        $todo->update({ 
            time_of_day => $time_of_day,
            start_date => $start_date
        });
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_time_and_date',
            "Updated time_of_day to $time_of_day and start_date to $start_date for todo $record_id");
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_time_and_date',
            "Failed to update todo $record_id: $@");
        $c->stash(
            json => {
                success => 0,
                error => "Failed to update todo: $@"
            }
        );
        $c->forward('View::JSON');
        return;
    }
    
    # Return success
    $c->stash(
        json => {
            success => 1,
            message => 'Todo time and date updated successfully',
            todo_id => $record_id,
            new_time => $time_of_day,
            new_date => $start_date
        }
    );
    $c->forward('View::JSON');
}

=head2 update_display_date

POST /todo/update_display_date - Update the display date for a todo (for month view drag-and-drop)
Month view displays by due_date if present, otherwise start_date.
This endpoint updates the appropriate field to move the todo to a new date.

=cut

sub update_display_date :Path('/todo/update_display_date') :Args(0) {
    my ($self, $c) = @_;
    
    # Get parameters
    my $record_id = $c->request->params->{record_id};
    my $time_of_day = $c->request->params->{time_of_day};
    my $display_date = $c->request->params->{display_date};
    
    # Validate parameters
    unless ($record_id && $display_date) {
        $c->stash(
            json => {
                success => 0,
                error => 'Missing required parameters: record_id and display_date'
            }
        );
        $c->forward('View::JSON');
        return;
    }
    
    # Get the todo item
    my $schema = $c->model('DBEncy');
    my $todo = $schema->resultset('Todo')->find($record_id);
    
    unless ($todo) {
        $c->stash(
            json => {
                success => 0,
                error => "Todo not found: $record_id"
            }
        );
        $c->forward('View::JSON');
        return;
    }
    
    # Month view displays by due_date if present, otherwise start_date
    # Update the field that's being displayed
    my $update_fields = {};
    
    if ($todo->due_date) {
        # Todo has a due_date, so it's displayed by due_date - update due_date
        $update_fields->{due_date} = $display_date;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_display_date',
            "Updating due_date to $display_date for todo $record_id (displayed by due_date)");
    } else {
        # Todo doesn't have due_date, so it's displayed by start_date - update start_date
        $update_fields->{start_date} = $display_date;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_display_date',
            "Updating start_date to $display_date for todo $record_id (displayed by start_date)");
    }
    
    # Also update time_of_day if provided
    if ($time_of_day) {
        $update_fields->{time_of_day} = $time_of_day;
    }
    
    # Update the todo record
    eval {
        $todo->update($update_fields);
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_display_date',
            "Failed to update todo $record_id: $@");
        $c->stash(
            json => {
                success => 0,
                error => "Failed to update todo: $@"
            }
        );
        $c->forward('View::JSON');
        return;
    }
    
    # Return success
    $c->stash(
        json => {
            success => 1,
            message => 'Todo display date updated successfully',
            todo_id => $record_id,
            display_date => $display_date,
            updated_field => $todo->due_date ? 'due_date' : 'start_date'
        }
    );
    $c->forward('View::JSON');
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

    # Fetch ALL todos for the site for calendar view
    my $todos = $todo_model->get_all_todos_for_calendar($c, $c->session->{SiteName});

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'day',
        "Fetched " . scalar(@$todos) . " total todos for site " . $c->session->{SiteName});

    # Filter todos for the given day using the shared method
    my $filtered_todos = $self->filter_todos_by_date_range($c, $todos, $date, $date, 1);
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'day',
        "After date filtering: " . scalar(@$filtered_todos) . " todos remain for date $date");

    # Sort todos by time_of_day, then priority, then start_date
    my @sorted_todos = sort { 
        ($a->time_of_day // '00:00:00') cmp ($b->time_of_day // '00:00:00') ||
        ($a->priority // 10) <=> ($b->priority // 10) ||
        ($a->start_date // '') cmp ($b->start_date // '')
    } @$filtered_todos;

    # Separate overdue and today's todos
    my @overdue_todos;
    my @today_todos;
    
    foreach my $todo (@sorted_todos) {
        if ($todo->due_date && $todo->due_date lt $date && $todo->status != 3) {
            push @overdue_todos, $todo;
        } else {
            push @today_todos, $todo;
        }
    }

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'day',
        "Separated into " . scalar(@overdue_todos) . " overdue and " . scalar(@today_todos) . " today todos");

    # Add the todos to the stash
    $c->stash(
        todos => \@today_todos,
        overdue_todos => \@overdue_todos,
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

    # Sort todos by time_of_day, then priority, then start_date
    my @sorted_todos = sort { 
        ($a->time_of_day // '00:00:00') cmp ($b->time_of_day // '00:00:00') ||
        ($a->priority // 10) <=> ($b->priority // 10) ||
        ($a->start_date // '') cmp ($b->start_date // '')
    } @$filtered_todos;

    # Add the todos to the stash
    $c->stash(
        todos => \@sorted_todos,
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

    # Sort todos by time_of_day, then priority, then start_date
    my @sorted_todos = sort { 
        ($a->time_of_day // '00:00:00') cmp ($b->time_of_day // '00:00:00') ||
        ($a->priority // 10) <=> ($b->priority // 10) ||
        ($a->start_date // '') cmp ($b->start_date // '')
    } @$filtered_todos;

    # Organize todos by day of month (use due_date if available, otherwise start_date)
    my %todos_by_day;
    foreach my $todo (@sorted_todos) {
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
        todos => \@sorted_todos,
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

# REST API Endpoints (Dev-only: comserv_server.pl, NOT Starman production)
# All API methods return JSON and require admin/developer roles

sub _api_dev_only_check {
    my ($self, $c) = @_;
    
    unless ($ENV{CATALYST_ENV} && $ENV{CATALYST_ENV} eq 'development') {
        $c->res->status(403);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({
            success => 0,
            error => 'API endpoints are development-only (comserv_server.pl). Not available in production.',
            code => 'api_dev_only'
        }));
        $c->detach();
    }
}

sub _api_validate_token {
    my ($self, $c) = @_;
    
    my $result = Comserv::Util::ApiTokenValidator->validate_from_request($c);
    
    unless ($result->{valid}) {
        $self->_api_error($c, $result->{error}, 'invalid_token', $result->{code});
    }
    
    my $schema = $c->model('DBEncy');
    my $api_token = $schema->resultset('ApiToken')->find($result->{api_token_id});
    my $user = $api_token->user if $api_token;
    
    $c->stash->{api_user} = $user;
    $c->stash->{api_user_id} = $result->{user_id};
    $c->stash->{api_token} = $api_token;
    
    return 1;
}

sub _api_error {
    my ($self, $c, $error, $code, $status) = @_;
    $status //= 400;
    
    $c->res->status($status);
    $c->res->content_type('application/json');
    $c->res->body(encode_json({
        success => 0,
        error => $error,
        code => $code
    }));
    $c->detach();
}

sub _api_success {
    my ($self, $c, $message, $data) = @_;
    
    $c->res->status(200);
    $c->res->content_type('application/json');
    my $response = {
        success => 1,
        message => $message,
    };
    $response = { %$response, %$data } if $data;
    $c->res->body(encode_json($response));
    $c->detach();
}

=head2 api_todo_create

POST /api/todo/create - Create a new todo via API

Required JSON fields: subject, start_date, due_date, priority, status
Optional JSON fields: description, project_id, assigned_to

Dev-only: comserv_server.pl only, requires admin/developer role
=cut

sub api_todo_create :Local :Args(0) {
    my ($self, $c) = @_;
    
    $self->_api_dev_only_check($c);
    $self->_api_validate_token($c);
    
    my $params;
    eval {
        my $body = $c->request->body;
        $params = decode_json($body) if $body;
    };
    if ($@) {
        $self->_api_error($c, "Invalid JSON: $@", 'json_parse_error', 400);
    }
    
    my $schema = $c->model('DBEncy');
    my $current_user = $c->stash->{api_user}->username || 'system';
    
    my @required = qw(subject start_date due_date priority status);
    my @missing = grep { !defined $params->{$_} || $params->{$_} eq '' } @required;
    if (@missing) {
        $self->_api_error($c, "Missing required fields: " . join(', ', @missing), 'validation_error');
    }
    
    my $start_date = $params->{start_date};
    my $due_date = $params->{due_date};
    if ($start_date gt $due_date) {
        $self->_api_error($c, "Start date cannot be after due date", 'date_validation_error');
    }
    
    my $project_id = $params->{project_id} || 1;
    eval {
        my $project = $schema->resultset('Project')->find($project_id);
        unless ($project) {
            die "Project $project_id not found";
        }
    };
    if ($@) {
        $self->_api_error($c, "Invalid project_id: $@", 'invalid_project');
    }
    
    my $sitename = $c->session->{SiteName} || 'default';
    
    my $todo = $schema->resultset('Todo')->create({
        subject => $params->{subject},
        description => $params->{description} || '',
        project_id => $project_id,
        start_date => $start_date,
        due_date => $due_date,
        priority => $params->{priority},
        status => $params->{status},
        assigned_to => $params->{assigned_to} || $current_user,
        sitename => $sitename,
        date_time_posted => DateTime->now,
        posted_by => $current_user,
    });
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_todo_create',
        "Todo created via API: ID=$todo->id, Subject=$params->{subject}, Project=$project_id");
    
    $self->_api_success($c, 'Todo created successfully', {
        todo_id => $todo->id,
        todo => $self->_todo_to_hash($todo)
    });
}

=head2 api_todo_read

GET /api/todo/:id - Retrieve a single todo by ID
=cut

sub api_todo_read :Local :Args(1) {
    my ($self, $c, $todo_id) = @_;
    
    $self->_api_dev_only_check($c);
    $self->_api_validate_token($c);
    
    my $schema = $c->model('DBEncy');
    my $todo = $schema->resultset('Todo')->find($todo_id);
    
    unless ($todo) {
        $self->_api_error($c, "Todo not found: $todo_id", 'not_found', 404);
    }
    
    $self->_api_success($c, 'Todo retrieved', {
        todo => $self->_todo_to_hash($todo)
    });
}

=head2 api_todo_update

PUT /api/todo/:id - Update a todo (partial update allowed)
=cut

sub api_todo_update :Path('/api/todo/update') :Args(1) {
    my ($self, $c, $todo_id) = @_;
    
    $self->_api_dev_only_check($c);
    $self->_api_validate_token($c);
    
    my $params;
    eval {
        my $body = $c->request->body;
        $params = decode_json($body) if $body;
    };
    if ($@) {
        $self->_api_error($c, "Invalid JSON: $@", 'json_parse_error', 400);
    }
    
    my $schema = $c->model('DBEncy');
    my $todo = $schema->resultset('Todo')->find($todo_id);
    
    unless ($todo) {
        $self->_api_error($c, "Todo not found: $todo_id", 'not_found', 404);
    }
    
    my $update_data = {};
    my %allowed_fields = map { $_ => 1 } qw(status priority description assigned_to);
    
    foreach my $field (keys %$params) {
        if ($allowed_fields{$field}) {
            $update_data->{$field} = $params->{$field};
        }
    }
    
    if (keys %$update_data) {
        $todo->update($update_data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_todo_update',
            "Todo updated via API: ID=$todo_id, Fields=" . join(',', keys %$update_data));
    }
    
    $self->_api_success($c, 'Todo updated successfully', {
        todo => $self->_todo_to_hash($todo)
    });
}

=head2 api_project_read

GET /api/project/:id - Retrieve a project by ID
=cut

sub api_project_read :Path('/api/project') :Args(1) {
    my ($self, $c, $project_id) = @_;
    
    $self->_api_dev_only_check($c);
    $self->_api_validate_token($c);
    
    my $schema = $c->model('DBEncy');
    my $project = $schema->resultset('Project')->find($project_id);
    
    unless ($project) {
        $self->_api_error($c, "Project not found: $project_id", 'not_found', 404);
    }
    
    $self->_api_success($c, 'Project retrieved', {
        project => $self->_project_to_hash($project)
    });
}

=head2 Helper: _todo_to_hash

Convert Todo DBIx::Class object to hashref for JSON serialization
=cut

sub _todo_to_hash {
    my ($self, $todo) = @_;
    
    return {
        id => $todo->id,
        subject => $todo->subject,
        description => $todo->description,
        project_id => $todo->project_id,
        start_date => $todo->start_date,
        due_date => $todo->due_date,
        priority => $todo->priority,
        status => $todo->status,
        assigned_to => $todo->assigned_to,
        sitename => $todo->sitename,
        date_time_posted => $todo->date_time_posted ? $todo->date_time_posted->iso8601 : undef,
        posted_by => $todo->posted_by,
        accumulative_time => $todo->accumulative_time || 0,
    };
}

=head2 Helper: _project_to_hash

Convert Project DBIx::Class object to hashref for JSON serialization
=cut

sub _project_to_hash {
    my ($self, $project) = @_;
    
    return {
        id => $project->id,
        name => $project->name,
        project_code => $project->project_code,
        description => $project->description,
        sitename => $project->sitename,
        status => $project->status,
    };
}

1;
