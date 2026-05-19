package Comserv::Controller::Todo;
use Moose;
use namespace::autoclean;
use DateTime;
use DateTime::Format::ISO8601;
use Data::Dumper;
use JSON::MaybeXS;
use Comserv::Util::Logging;
use Comserv::Util::ApiTokenValidator;
use Comserv::Util::PointSystem;
use Comserv::Util::Priority ();
use Comserv::Util::TodoTypes qw(recurring_matches_date);
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
sub priority_options {
    return Comserv::Util::Priority::priority_options();
}

sub get_priority_name {
    my ($self, $priority_code) = @_;
    my $map = $self->priority_options;
    return $map->{$priority_code} // "Priority $priority_code";
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

sub normalize_status {
    my ($self, $val) = @_;
    return 1 unless defined $val;
    return $val + 0 if $val =~ /^\d+$/;
    my $lc = lc($val);
    $lc =~ s/[-_ ]+//g;
    return 1 if $lc eq 'new';
    return 2 if $lc =~ /^in?progress$|^inprog$|^inprocess$/;
    return 3 if $lc =~ /^done$|^completed$|^complete$/;
    return 4 if $lc =~ /^cancel/;
    return 1;
}

# Helper method to filter todos by date range
sub filter_todos_by_date_range {
    my ($self, $c, $todos, $start_date, $end_date, $include_overdue) = @_;
    
    $include_overdue //= 1;

    my @done_vals = (3, 4, 'DONE', 'Completed', 'completed', 'Closed', 'closed', 'Done');
    my %done_set  = map { $_ => 1 } @done_vals;

    my $today = DateTime->now->ymd;
    my @filtered_todos = grep {
        my $todo = $_;
        my $include_todo = 0;
        my $sd_raw = $todo->start_date // '';
        my $dd_raw = $todo->due_date   // '';
        $sd_raw = ref($sd_raw) ? $sd_raw->ymd : "$sd_raw";
        $dd_raw = ref($dd_raw) ? $dd_raw->ymd : "$dd_raw";
        my $sd = length($sd_raw) >= 10 ? substr($sd_raw, 0, 10) : '';
        my $dd = length($dd_raw) >= 10 ? substr($dd_raw, 0, 10) : '';
        my $is_done = exists $done_set{ $todo->status // '' };

        # Primary anchor: start_date. Include if within range.
        if ($sd && $sd ge $start_date && $sd le $end_date) {
            $include_todo = 1;
        }

        # due_date within range always qualifies — regardless of whether start_date is set.
        # A todo due today belongs on today's calendar even if it started (on paper) in the past.
        if ($dd && $dd ge $start_date && $dd le $end_date) {
            $include_todo = 1;
        }

        # Overdue: only when BOTH anchor dates are before the range start
        if ($include_overdue && !$is_done) {
            my $sd_before = $sd && $sd lt $start_date;
            my $dd_before = $dd && $dd lt $start_date;
            my $sd_in     = $sd && $sd ge $start_date && $sd le $end_date;
            my $dd_in     = $dd && $dd ge $start_date && $dd le $end_date;
            if (!$sd_in && !$dd_in && ($sd_before || $dd_before)) {
                $include_todo = 1;
            }
        }

        # Undated open todos — show only in today's single-day view
        if (!$sd && !$dd && !$is_done && $start_date eq $end_date && $start_date eq $today) {
            $include_todo = 1;
        }

        # Recurring events: inject into any single-day view where recurrence rule matches.
        # DB flag is authoritative; keyword is fallback for un-migrated rows.
        # Use start_date as lower bound; fall back to today so new recurring todos
        # don't appear in the past when start_date is not set.
        if (!$is_done && $start_date eq $end_date
            && ($todo->can('is_recurring') ? $todo->is_recurring : _is_recurring($todo->subject // ''))) {
            my $effective_start = $sd || $today;
            if ($effective_start le $start_date) {
                if (recurring_matches_date($todo, $start_date)) {
                    $include_todo = 1;
                }
            }
        }

        $include_todo;
    } @$todos;
    
    return \@filtered_todos;
}
has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub _get_user_accessible_sites {
    my ($self, $c) = @_;
    my $is_csc = (uc($c->session->{SiteName} || '') eq 'CSC') ? 1 : 0;
    my @sites;
    eval {
        if ($is_csc) {
            my $site_model = $c->model('Site');
            my $all = $site_model->get_all_sites($c) || [];
            @sites = map { $_->name } @$all;
        } else {
            my $user_id = $c->session->{user_id};
            if ($user_id) {
                my @rows = $c->model('DBEncy')->resultset('UserSiteRole')->search(
                    { user_id => $user_id, site_id => { '!=' => undef }, is_active => 1 }
                )->all;
                my %seen;
                for my $r (@rows) {
                    eval {
                        my $site = $c->model('DBEncy')->resultset('Site')->find($r->site_id);
                        if ($site && $site->name && !$seen{$site->name}++) {
                            push @sites, $site->name;
                        }
                    };
                }
            }
        }
    };
    push @sites, $c->session->{SiteName} unless grep { $_ eq ($c->session->{SiteName} || '') } @sites;
    return @sites ? \@sites : [$c->session->{SiteName}];
}

# Apply restrictions to the entire controller
sub begin :Private {
    my ($self, $c) = @_;

    # Log the path the user is accessing
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'begin', "User accessing path: " . $c->req->uri);

    # API paths handle their own auth — skip session-based checks
    return 1 if $c->req->path =~ m{^api/};

    # AJAX update endpoints require only a valid session, not admin/developer
    if ($c->req->path =~ m{^todo/(?:update_time|update_time_and_date|update_priority|update_status|update_display_date|mark_done|reschedule_single|quick_close|quick_priority|reschedule|day_drop|update_recurring_time|open_log|close_log)\b}) {
        unless ($c->session->{user_id}) {
            $c->stash(json => { success => 0, error => 'Not authenticated' });
            $c->forward('View::JSON');
            $c->detach;
        }
        return 1;
    }

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

        # Fetch rescheduling / interval history for this todo
        my @intervals;
        eval {
            @intervals = $schema->resultset('TodoInterval')->search(
                { todo_record_id => $record_id },
                { order_by => { -desc => 'record_id' } }
            )->all;
        };
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'details',
            "Interval fetch error: $@") if $@;

        # Fetch AI conversations linked to this task
        my @ai_conversations;
        eval {
            @ai_conversations = $schema->resultset('AiConversation')->search(
                { task_id => $record_id },
                { order_by => { -desc => 'updated_at' }, rows => 10 }
            );
        };
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'details',
            "AI conv fetch error: $@") if $@;

        my $current_status   = $self->normalize_status($todo->get_column('status'));
        my $current_priority = $todo->get_column('priority') // 5;

        # Add the todo, accumulative_time, projects, and interval history to the stash
        $c->stash(
            record            => $todo,
            current_status    => $current_status,
            current_priority  => $current_priority,
            build_priority    => $self->priority_options,
            accumulative_time => $accumulative_time,
            projects          => $projects,
            todo_intervals    => \@intervals,
            ai_conversations  => \@ai_conversations,
            return_to         => $c->request->params->{return_to} || $c->request->headers->referer || $c->uri_for($self->action_for('todo')),
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

    my %status_options = (
        1 => 'NEW',
        2 => 'IN PROGRESS',
        3 => 'DONE'
    );

    # Add the projects, sitename, and users to the stash
    my $add_is_csc = (uc($c->session->{SiteName} || '') eq 'CSC') ? 1 : 0;
    my $add_sites  = [];
    eval {
        if ($add_is_csc) {
            my @site_rows = $c->model('DBEncy')->resultset('Site')->search(
                {}, { order_by => 'name' }
            )->all;
            $add_sites = \@site_rows;
        } else {
            my $user_id = $c->session->{user_id};
            if ($user_id) {
                my @rows = $c->model('DBEncy')->resultset('UserSiteRole')->search(
                    { user_id => $user_id, site_id => { '!=' => undef }, is_active => 1 }
                )->all;
                my %seen;
                for my $r (@rows) {
                    eval {
                        my $site = $c->model('DBEncy')->resultset('Site')->find($r->site_id);
                        if ($site && $site->name && !$seen{$site->name}++) {
                            push @$add_sites, $site;
                        }
                    };
                }
            }
            push @$add_sites, $c->model('DBEncy')->resultset('Site')->search(
                { name => $c->session->{SiteName} }
            )->first
                unless grep { $_->name eq ($c->session->{SiteName} || '') } @$add_sites;
        }
    };

    $c->stash(
        projects        => $projects,
        current_project => $current_project,
        users           => \@users,
        build_priority  => $self->priority_options,
        build_status    => \%status_options,
        return_to       => $return_to,
        start_date      => $c->request->params->{start_date} || DateTime->now->ymd,
        time_of_day     => $c->request->params->{time_of_day},
        sites           => $add_sites,
        is_csc          => $add_is_csc,
        template        => 'todo/addtodo.tt'
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

    my %status_options = (
        1 => 'NEW',
        2 => 'IN PROGRESS',
        3 => 'DONE'
    );

    # Add the todo, projects, and users to the stash
    my $current_status   = $self->normalize_status($todo->get_column('status'));
    my $current_priority = $todo->get_column('priority') // 5;

    my $edit_is_csc = (uc($c->session->{SiteName} || '') eq 'CSC') ? 1 : 0;
    my $edit_sites = [];
    eval {
        if ($edit_is_csc) {
            my @site_rows = $c->model('DBEncy')->resultset('Site')->search(
                {}, { order_by => 'name' }
            )->all;
            $edit_sites = \@site_rows;
        } else {
            my $uid = $c->session->{user_id};
            if ($uid) {
                my @rows = $c->model('DBEncy')->resultset('UserSiteRole')->search(
                    { user_id => $uid, site_id => { '!=' => undef }, is_active => 1 }
                )->all;
                my %seen;
                for my $r (@rows) {
                    eval {
                        my $site = $c->model('DBEncy')->resultset('Site')->find($r->site_id);
                        if ($site && $site->name && !$seen{$site->name}++) {
                            push @$edit_sites, $site;
                        }
                    };
                }
            }
            unless (grep { $_->name eq ($c->session->{SiteName} || '') } @$edit_sites) {
                my $cur = $c->model('DBEncy')->resultset('Site')->search(
                    { name => $c->session->{SiteName} }
                )->first;
                push @$edit_sites, $cur if $cur;
            }
        }
    };

    my $todo_sitename = eval { $todo->get_column('sitename') } // '';

    $c->stash(
        record           => $todo,
        current_status   => $current_status,
        current_priority => $current_priority,
        projects         => $projects,
        users            => \@users,
        accumulative_time => $accumulative_time,
        build_priority   => $self->priority_options,
        build_status     => \%status_options,
        return_to        => $return_to,
        sites            => $edit_sites,
        is_csc           => $edit_is_csc,
        todo_sitename    => $todo_sitename,
        form_data        => { sitename => $todo_sitename },
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

    # Capture old values before update
    my $old_due_date   = $todo->due_date   // '';
    my $old_start_date = $todo->start_date // '';
    my $old_status     = $todo->status     // '';
    my $new_due_date   = $form_data->{due_date} || DateTime->now->add(days => 7)->ymd;
    my $today          = DateTime->now->ymd;
    my $current_user   = $c->session->{username} || 'system';

    # Attempt to update the todo record
    eval {
        $todo->update({
            sitename             => $form_data->{sitename},
            start_date           => $form_data->{start_date}      || $todo->get_column('start_date'),
            parent_todo          => $parent_todo,
            due_date             => $new_due_date,
            subject              => $form_data->{subject},
            description          => $form_data->{description},
            estimated_man_hours  => $form_data->{estimated_man_hours} // $todo->get_column('estimated_man_hours'),
            comments             => defined($form_data->{comments}) ? $form_data->{comments} : $todo->get_column('comments'),
            accumulative_time    => $accumulative_time || $todo->get_column('accumulative_time'),
            reporter             => defined($form_data->{reporter}) && $form_data->{reporter} ne '' ? $form_data->{reporter} : $todo->get_column('reporter'),
            company_code         => defined($form_data->{company_code}) && $form_data->{company_code} ne '' ? $form_data->{company_code} : $todo->get_column('company_code'),
            owner                => defined($form_data->{owner}) && $form_data->{owner} ne '' ? $form_data->{owner} : $todo->get_column('owner'),
            developer            => defined($form_data->{developer}) && $form_data->{developer} ne '' ? $form_data->{developer} : $todo->get_column('developer'),
            username_of_poster   => $c->session->{username},
            status               => $self->normalize_status($form_data->{status}),
            priority             => ($form_data->{priority} && $form_data->{priority} =~ /^\d+$/) ? $form_data->{priority} : $todo->get_column('priority'),
            time_of_day          => ($form_data->{time_of_day} && $form_data->{time_of_day} ne '') ? $form_data->{time_of_day} : $todo->get_column('time_of_day'),
            share                => $form_data->{share} // $todo->get_column('share') // 0,
            last_mod_by          => $current_user,
            last_mod_date        => $today,
            user_id              => $todo->get_column('user_id'),
            project_id           => ($form_data->{project_id} && $form_data->{project_id} ne '') ? $form_data->{project_id} : $todo->get_column('project_id'),
            date_time_posted     => $form_data->{date_time_posted} || $todo->get_column('date_time_posted') || $today . ' 00:00:00',
            todo_type        => $form_data->{todo_type}        || $todo->get_column('todo_type')        || 'task',
            is_recurring     => defined($form_data->{is_recurring}) ? ($form_data->{is_recurring} ? 1 : 0) : $todo->get_column('is_recurring'),
            recurrence_rule  => $form_data->{recurrence_rule}  || $todo->get_column('recurrence_rule')  || undef,
            creator_timezone => $form_data->{creator_timezone} || $todo->get_column('creator_timezone') || undef,
            is_fixed         => defined($form_data->{is_fixed})
                ? ($form_data->{is_fixed} ? 1 : 0)
                : ($todo->get_column('is_fixed') // (($form_data->{todo_type} // $todo->get_column('todo_type') // 'task') =~ /^(appointment|meeting)$/ ? 1 : 0)),
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

    # --- Rescheduling interval log ---
    # If the due_date changed, create a TodoInterval record to track the move.
    # This builds an audit trail showing how many times and how far a task was deferred.
    if ($old_due_date && $new_due_date && $old_due_date ne $new_due_date) {
        eval {
            $schema->resultset('TodoInterval')->create({
                todo_record_id => $record_id,
                start_date     => $old_start_date || $today,
                end_date       => $today,
                interval_type  => 'rescheduled',
                status         => "from:$old_due_date to:$new_due_date",
                last_mod_by    => $current_user,
                last_mod_date  => $today,
            });
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'modify.reschedule',
                "Logged reschedule for todo $record_id: $old_due_date -> $new_due_date by $current_user");
        };
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'modify.reschedule',
                "Could not write TodoInterval for todo $record_id: $@");
        }
    }

    # --- Award completion points ---
    my $new_status = $form_data->{status} // '';
    my $was_done   = ($old_status eq '3' || $old_status eq 'DONE');
    my $is_done    = ($new_status eq '3' || $new_status eq 'DONE');
    if ($is_done && !$was_done) {
        $todo->discard_changes;
        my $rate    = $todo->point_rate;
        my $billed  = $todo->billable // 1;
        if ($rate && $rate > 0 && $billed) {
            my $minutes = $todo->accumulative_time || ($todo->estimated_man_hours ? $todo->estimated_man_hours * 60 : 0);
            my $hours   = $minutes / 60;
            my $points  = sprintf('%.4f', $hours * $rate);
            if ($points > 0) {
                my $dev_username = $todo->developer || $current_user;
                my $dev_user = eval { $schema->resultset('User')->find({ username => $dev_username }) };
                if ($dev_user) {
                    eval {
                        my $ps = Comserv::Util::PointSystem->new(c => $c);
                        $ps->credit(
                            user_id          => $dev_user->id,
                            amount           => $points,
                            transaction_type => 'todo_completion',
                            description      => sprintf('Todo #%d completed: %s (%.2f hrs @ %.4f/hr)',
                                $record_id, ($todo->subject // ''), $hours, $rate),
                            reference_type   => 'todo',
                            reference_id     => $record_id,
                        );
                        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'modify.points',
                            "Awarded $points pts to $dev_username for todo #$record_id completion");
                    };
                    if ($@) {
                        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'modify.points',
                            "Failed to award completion points for todo $record_id: $@");
                    }
                }
            }
        }
    }

    # Handle successful update
    $c->flash->{success_msg} = "Todo item with ID $record_id has been successfully updated.";

    if ($form_data->{return_to}) {
        $c->response->redirect($form_data->{return_to});
        $c->detach();
    }

    $c->response->redirect($c->uri_for('/todo/details', { record_id => $record_id }));
    $c->detach();
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
                    { name => 'Default' },
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
        time_of_day => ($params->{time_of_day} && $params->{time_of_day} ne '') ? $params->{time_of_day} : undef,
        share => $params->{share} ? 1 : 0,
        last_mod_by => $current_user,
        last_mod_date => $current_date,
        user_id => $user_id,
        group_of_poster => (ref $c->session->{roles} eq 'ARRAY' && @{$c->session->{roles}}) 
                          ? $c->session->{roles}->[0] 
                          : 'user',
        project_id => $selected_project_id,
        date_time_posted => $params->{date_time_posted} || $current_date,
        billable   => defined($params->{billable})   ? ($params->{billable}   ? 1 : 0) : 1,
        point_rate => ($params->{point_rate} && $params->{point_rate} =~ /^\d+(\.\d+)?$/) ? $params->{point_rate} : undef,
        todo_type        => $params->{todo_type}        || 'task',
        is_recurring     => $params->{is_recurring}     ? 1 : 0,
        recurrence_rule  => $params->{recurrence_rule}  || undef,
        creator_timezone => $params->{creator_timezone} || undef,
        is_fixed         => defined($params->{is_fixed})
            ? ($params->{is_fixed} ? 1 : 0)
            : (($params->{todo_type} // 'task') =~ /^(appointment|meeting)$/ ? 1 : 0),
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

=head2 update_recurring_time

POST /todo/update_recurring_time - Move a recurring event to a new time slot.
mode=today  : Creates a non-recurring exception clone for exception_date/time_of_day;
              shifts original's start_date to the day after exception_date so the
              original no longer appears on that date.
mode=all    : Updates time_of_day (and optionally start_date) on the original record.

=cut

sub update_recurring_time :Path('/todo/update_recurring_time') :Args(0) {
    my ($self, $c) = @_;

    my $record_id      = $c->request->params->{record_id};
    my $time_of_day    = $c->request->params->{time_of_day};
    my $mode           = $c->request->params->{mode} // 'all';
    my $exception_date = $c->request->params->{exception_date};

    unless ($record_id && $time_of_day) {
        $c->stash(json => { success => 0, error => 'Missing record_id or time_of_day' });
        $c->forward('View::JSON');
        return;
    }

    my $schema = $c->model('DBEncy');
    my $todo = $schema->resultset('Todo')->find($record_id);
    unless ($todo) {
        $c->stash(json => { success => 0, error => "Todo not found: $record_id" });
        $c->forward('View::JSON');
        return;
    }

    my $today = DateTime->now->ymd;
    my $target_date = $exception_date || $today;

    if ($mode eq 'today') {
        eval {
            $schema->txn_do(sub {
                my $next_day_dt = DateTime->new(
                    year  => substr($target_date, 0, 4),
                    month => substr($target_date, 5, 2),
                    day   => substr($target_date, 8, 2),
                )->add(days => 1);
                my $next_day = $next_day_dt->ymd;

                $schema->resultset('Todo')->create({
                    sitename            => $todo->sitename,
                    subject             => $todo->subject,
                    description         => $todo->description // '',
                    status              => $todo->status,
                    priority            => $todo->priority // 5,
                    start_date          => $target_date,
                    time_of_day         => $time_of_day,
                    due_date            => $todo->due_date,
                    estimated_man_hours => $todo->estimated_man_hours // 0,
                    project_id          => $todo->project_id,
                    project_code        => $todo->project_code // '',
                    developer           => $todo->developer // '',
                    owner               => $todo->owner // '',
                    reporter            => $todo->reporter // '',
                    username_of_poster  => $todo->username_of_poster // '',
                    user_id             => $todo->user_id,
                    group_of_poster     => $todo->group_of_poster // 'user',
                    accumulative_time   => 0,
                    billable            => $todo->billable // 1,
                    is_blocking         => 0,
                    todo_type           => $todo->todo_type // 'appointment',
                    is_recurring        => 0,
                    recurrence_rule     => undef,
                    creator_timezone    => $todo->creator_timezone,
                    last_mod_by         => 'recurring_exception',
                    last_mod_date       => $today,
                    date_time_posted    => $today,
                    company_code        => $todo->company_code // 'default',
                    share               => $todo->share // 0,
                    parent_todo         => $todo->record_id,
                    comments            => 'Exception from recurring event ' . $record_id,
                });

                $todo->update({ start_date => $next_day, last_mod_date => $today });
            });
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                'update_recurring_time', "today-mode error: $@");
            $c->stash(json => { success => 0, error => "$@" });
            $c->forward('View::JSON');
            return;
        }
    } else {
        my %upd = (time_of_day => $time_of_day, last_mod_date => $today);
        $upd{start_date} = $target_date if $exception_date;
        eval { $todo->update(\%upd) };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                'update_recurring_time', "all-mode error: $@");
            $c->stash(json => { success => 0, error => "$@" });
            $c->forward('View::JSON');
            return;
        }
    }

    $c->stash(json => { success => 1, mode => $mode, todo_id => $record_id });
    $c->forward('View::JSON');
}

=head2 update_priority

POST /todo/update_priority - Update priority for a todo item (AJAX endpoint for inline priority select)

=cut

sub update_status :Path('/todo/update_status') :Args(0) {
    my ($self, $c) = @_;

    my $record_id = $c->request->params->{record_id};
    my $status    = $c->request->params->{status};

    unless ($record_id && defined $status) {
        $c->stash(json => { success => 0, error => 'Missing record_id or status' });
        $c->forward('View::JSON');
        return;
    }

    my $todo = $c->model('DBEncy')->resultset('Todo')->find($record_id);
    unless ($todo) {
        $c->stash(json => { success => 0, error => "Todo not found: $record_id" });
        $c->forward('View::JSON');
        return;
    }

    my $today   = DateTime->now->ymd;
    my $now_hms = DateTime->now->strftime('%H:%M:%S');

    eval { $todo->update({ status => $status, last_mod_date => $today }) };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_status',
            "Failed to update status for todo $record_id: $@");
        $c->stash(json => { success => 0, error => "Failed to update: $@" });
        $c->forward('View::JSON');
        return;
    }

    my $log_id;
    if ($status == 3 || $status eq 'DONE' || $status eq 'Done' || $status eq 'done') {
        eval {
            my $username  = $c->session->{username}  || 'system';
            my $sitename  = $c->session->{SiteName}  || $todo->sitename || 'CSC';
            my $group     = $c->session->{group}     || $c->session->{roles}[0] || 'user';

            my $start_date = $today;
            if ($todo->start_date) {
                my $sd = ref($todo->start_date) ? $todo->start_date->ymd : "${\$todo->start_date}";
                $start_date = substr($sd, 0, 10) if length($sd) >= 10;
            }

            my $schema = $c->model('DBEncy');

            # 1. Look for an existing open log (end_time = midnight sentinel, not closed)
            my $open_log = $schema->resultset('Log')->search({
                todo_record_id => $record_id,
                end_time       => '00:00:00',
                status         => { '!=' => 3 },
            }, { order_by => { -desc => 'record_id' } })->first;

            my ($start_hms, $dur_mins, $log_entry);

            if ($open_log) {
                # Close the open log and derive actual duration from it
                my $raw_start = $open_log->start_time // '09:00:00';
                $raw_start = ref($raw_start)
                    ? sprintf('%02d:%02d:%02d', $raw_start->hours//0, $raw_start->minutes//0, 0)
                    : "$raw_start";
                $start_hms = ($raw_start =~ /^\d{2}:\d{2}/) ? substr($raw_start, 0, 8) : '09:00:00';

                my ($sh, $sm) = ($start_hms =~ /^(\d{2}):(\d{2})/);
                my ($eh, $em) = ($now_hms   =~ /^(\d{2}):(\d{2})/);
                $dur_mins = ($eh * 60 + $em) - ($sh * 60 + $sm);
                $dur_mins = 1 if $dur_mins <= 0;
                my $dur_hms = sprintf('%02d:%02d:00', int($dur_mins / 60), $dur_mins % 60);

                $open_log->update({
                    end_time      => $now_hms,
                    time          => $dur_hms,
                    status        => 3,
                    last_mod_by   => $username,
                    last_mod_date => $today,
                    details       => 'Auto-closed when todo marked done',
                });
                $log_id = $open_log->record_id;

                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_status',
                    "Closed open log " . $open_log->record_id . " for todo $record_id: $dur_mins min");
            } else {
                # No open log — estimate duration intelligently
                $dur_mins = undef;

                # 2a. Average duration from past closed logs for this exact todo
                my @same_logs = $schema->resultset('Log')->search({
                    todo_record_id => $record_id,
                    status         => 3,
                    time           => { '!=' => '00:00:00' },
                })->all;
                if (@same_logs) {
                    my $total = 0; my $count = 0;
                    for my $lg (@same_logs) {
                        my $t = $lg->time // '00:00:00';
                        $t = ref($t) ? sprintf('%02d:%02d:00', $t->hours//0, $t->minutes//0) : "$t";
                        if ($t =~ /^(\d+):(\d+)/) {
                            $total += $1 * 60 + $2;
                            $count++;
                        }
                    }
                    $dur_mins = int($total / $count) if $count > 0;
                }

                # 2b. Average from logs with similar abstract (first 40 chars of subject)
                if (!$dur_mins && $todo->subject) {
                    my $kw = substr($todo->subject, 0, 40);
                    $kw =~ s/[%_]//g;
                    my @kw_logs = $schema->resultset('Log')->search({
                        abstract => { 'like' => "%$kw%" },
                        status   => 3,
                        time     => { '!=' => '00:00:00' },
                    }, { rows => 50 })->all;
                    if (@kw_logs) {
                        my $total = 0; my $count = 0;
                        for my $lg (@kw_logs) {
                            my $t = $lg->time // '00:00:00';
                            $t = ref($t) ? sprintf('%02d:%02d:00', $t->hours//0, $t->minutes//0) : "$t";
                            if ($t =~ /^(\d+):(\d+)/) {
                                $total += $1 * 60 + $2;
                                $count++;
                            }
                        }
                        $dur_mins = int($total / $count) if $count > 0;
                    }
                }

                # 2c. Use estimated_man_hours (stored in minutes) from the todo record
                if (!$dur_mins && $todo->estimated_man_hours && $todo->estimated_man_hours > 0) {
                    $dur_mins = $todo->estimated_man_hours;
                }

                # 2d. Industry-standard defaults by todo_type
                if (!$dur_mins) {
                    my $ttype = lc($todo->todo_type // 'task');
                    my %type_defaults = (
                        task        => 30,
                        appointment => 60,
                        meeting     => 60,
                        event       => 120,
                        reminder    => 5,
                    );
                    $dur_mins = $type_defaults{$ttype} // 30;
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_status',
                        "Using industry default $dur_mins min for type '$ttype' on todo $record_id");
                }

                # Derive start from scheduled time_of_day; end = now
                my $start_raw = $todo->time_of_day // '';
                $start_raw = ref($start_raw)
                    ? sprintf('%02d:%02d:%02d', $start_raw->hours//0, $start_raw->minutes//0, 0)
                    : "$start_raw";
                $start_hms = ($start_raw =~ /^\d{2}:\d{2}/) ? substr($start_raw, 0, 8) : '09:00:00';

                my $dur_hms = sprintf('%02d:%02d:00', int($dur_mins / 60), $dur_mins % 60);

                $log_entry = $schema->resultset('Log')->create({
                    todo_record_id  => $record_id,
                    username        => $username,
                    sitename        => $sitename,
                    start_date      => $start_date,
                    project_code    => $todo->project_id || 0,
                    due_date        => $today,
                    abstract        => ($todo->subject // 'Completed todo'),
                    details         => "Auto-log: estimated $dur_mins min (no open log found)",
                    start_time      => $start_hms,
                    end_time        => $now_hms,
                    time            => $dur_hms,
                    group_of_poster => $group,
                    status          => 3,
                    priority        => $todo->priority || 5,
                    last_mod_by     => $username,
                    last_mod_date   => $today,
                    comments        => '',
                    points_processed => 0,
                });
                $log_id = $log_entry->record_id;
            }
        };
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'update_status',
            "Auto-log error for todo $record_id: $@") if $@;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_status',
        "Updated status for todo $record_id to $status");
    $c->stash(json => { success => 1, todo_id => $record_id, new_status => $status, log_id => $log_id });
    $c->forward('View::JSON');
}

sub update_priority :Path('/todo/update_priority') :Args(0) {
    my ($self, $c) = @_;

    my $record_id = $c->request->params->{record_id};
    my $priority  = $c->request->params->{priority};

    unless ($record_id && defined $priority && $priority =~ /^\d+$/) {
        $c->stash(json => { success => 0, error => 'Missing or invalid record_id/priority' });
        $c->forward('View::JSON');
        return;
    }

    my $todo = $c->model('DBEncy')->resultset('Todo')->find($record_id);
    unless ($todo) {
        $c->stash(json => { success => 0, error => "Todo not found: $record_id" });
        $c->forward('View::JSON');
        return;
    }

    eval { $todo->update({ priority => $priority }) };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_priority',
            "Failed to update priority for todo $record_id: $@");
        $c->stash(json => { success => 0, error => "Failed to update: $@" });
        $c->forward('View::JSON');
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_priority',
        "Updated priority for todo $record_id to $priority");
    $c->stash(json => { success => 1, todo_id => $record_id, new_priority => $priority });
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

    # Validate the date_arg if it's defined — always produce a plain YYYY-MM-DD string
    my $date;
    if (defined $date_arg) {
        my $iso8601 = DateTime::Format::ISO8601->new;
        my $dt_parsed;
        eval { $dt_parsed = $iso8601->parse_datetime($date_arg) };
        $date = $dt_parsed ? $dt_parsed->ymd : DateTime->now->ymd;
    } else {
        $date = DateTime->now->ymd;
    }

    # Calculate the previous and next dates
    my $dt = DateTime::Format::ISO8601->parse_datetime($date);
    my $previous_date = $dt->clone->subtract(days => 1)->strftime('%Y-%m-%d');
    my $next_date = $dt->clone->add(days => 1)->strftime('%Y-%m-%d');

    # Get the Todo model
    my $todo_model = $c->model('Todo');

    my $calendar_sites = $self->_get_user_accessible_sites($c);
    my $todos = $todo_model->get_all_todos_for_calendar($c, $calendar_sites);

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'day',
        "Fetched " . scalar(@$todos) . " total todos for sites " . join(',', @$calendar_sites));

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

    # Separate overdue and today's todos.
    # Use start_date as the calendar anchor (set by reschedule).
    # Fall back to due_date only when start_date is absent.
    my @overdue_todos;
    my @today_todos;

    my %_done_set = map { $_ => 1 } (3, 4, 'DONE', 'Completed', 'completed', 'Closed', 'closed', 'Done');
    foreach my $todo (@sorted_todos) {
        my $is_done  = exists $_done_set{ $todo->status // '' };
        my $sd_raw   = $todo->start_date // '';
        my $dd_raw   = $todo->due_date   // '';
        $sd_raw = ref($sd_raw) ? $sd_raw->ymd : "$sd_raw";
        $dd_raw = ref($dd_raw) ? $dd_raw->ymd : "$dd_raw";
        my $sd = length($sd_raw) >= 10 ? substr($sd_raw, 0, 10) : '';
        my $dd = length($dd_raw) >= 10 ? substr($dd_raw, 0, 10) : '';
        my $anchor = $sd || $dd || '';
        my $is_rec = $todo->can('is_recurring') ? $todo->is_recurring : _is_recurring($todo->subject // '');
        if (!$is_done && $anchor && $anchor lt $date && !$is_rec) {
            push @overdue_todos, $todo;
            push @today_todos, $todo;
        } else {
            push @today_todos, $todo;
        }
    }

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'day',
        "Separated into " . scalar(@overdue_todos) . " overdue and " . scalar(@today_todos) . " today todos");

    my %proj_name_map;
    eval {
        my @prows = $c->model('DBEncy')->resultset('Project')->search(
            {}, { columns => [qw(id name)] }
        )->all;
        %proj_name_map = map { $_->id => $_->name } @prows;
    };

    # Fetch AI conversations active on this date (admin/developer/editor only)
    my @ai_daily_conversations;
    my $user_roles_day = $c->session->{roles} || [];
    $user_roles_day = [split(/\s*,\s*/, $user_roles_day)] if !ref($user_roles_day) && $user_roles_day;
    my $can_see_ai_day = ref($user_roles_day) eq 'ARRAY'
        ? (grep { $_ =~ /^(admin|developer|editor)$/i } @$user_roles_day) ? 1 : 0
        : 0;
    if ($can_see_ai_day) {
        eval {
            my $day_start = $date . ' 00:00:00';
            my $day_end   = $date . ' 23:59:59';
            @ai_daily_conversations = $c->model('DBEncy')->resultset('AiConversation')->search(
                { updated_at => { '>=' => $day_start, '<=' => $day_end } },
                { order_by => { -desc => 'updated_at' }, prefetch => 'project' }
            );
        };
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'day',
            "AI daily conv fetch error: $@") if $@;
    }

    if ($c->req->param('embed')) {
        $c->stash(no_wrapper => 1);
    }

    my $day_is_csc = (uc($c->session->{SiteName} || '') eq 'CSC') ? 1 : 0;
    my @day_all_sitenames = sort @{ $calendar_sites };

    my @day_all_usernames;
    eval {
        if ($day_is_csc) {
            my @urows = $c->model('DBEncy')->resultset('Users')->search(
                { roles => { -like => '%admin%' } },
                { columns => ['username'], order_by => 'username' }
            )->all;
            my %seen;
            for my $r (@urows) {
                my $u = eval { $r->username } // '';
                push @day_all_usernames, $u if $u && !$seen{$u}++;
            }
            unless (@day_all_usernames) {
                my @all_urows = $c->model('DBEncy')->resultset('Users')->search(
                    {},
                    { columns => ['username'], order_by => 'username', rows => 200 }
                )->all;
                %seen = ();
                for my $r (@all_urows) {
                    my $u = eval { $r->username } // '';
                    push @day_all_usernames, $u if $u && !$seen{$u}++;
                }
            }
        } else {
            my %seen;
            for my $t (@today_todos, @overdue_todos) {
                my $u = eval { $t->developer || $t->username_of_poster || '' };
                push @day_all_usernames, $u if $u && !$seen{$u}++;
            }
            @day_all_usernames = sort @day_all_usernames;
        }
    };

    $c->stash(
        todos                  => \@today_todos,
        overdue_todos          => \@overdue_todos,
        sitename               => $c->session->{SiteName},
        date                   => $date,
        previous_date          => $previous_date,
        next_date              => $next_date,
        proj_name_map          => \%proj_name_map,
        ai_daily_conversations => \@ai_daily_conversations,
        is_csc                 => $day_is_csc,
        ap_all_sitenames       => \@day_all_sitenames,
        ap_all_usernames       => \@day_all_usernames,
        template               => 'todo/day.tt',
    );

    $c->forward($c->view('TT'));
}
sub week :Path('/todo/week') :Args {
    my ($self, $c, $date) = @_;

    # Get the Todo model
    my $todo_model = $c->model('Todo');

    # Always produce a plain YYYY-MM-DD string (URL may contain T00:00:00)
    {
        my $iso8601 = DateTime::Format::ISO8601->new;
        my $dt_parsed;
        eval { $dt_parsed = $iso8601->parse_datetime($date) } if defined $date;
        $date = $dt_parsed ? $dt_parsed->ymd : DateTime->now->ymd;
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
    my $today_str = DateTime->now->ymd;
    for my $day_offset (0..6) {
        my $current_date = $start_dt->clone->add(days => $day_offset);
        my $d_str = $current_date->strftime('%Y-%m-%d');
        push @week_dates, {
            date_str => $d_str,
            day_num  => $current_date->day,
            day_name => $current_date->strftime('%A'),
            is_today => ($d_str eq $today_str),
            prev_date => $current_date->clone->subtract(days => 1)->ymd,
            next_date => $current_date->clone->add(days => 1)->ymd,
        };
    }

    my $calendar_sites_w = $self->_get_user_accessible_sites($c);
    my $todos = $todo_model->get_all_todos_for_calendar($c, $calendar_sites_w);

    # Filter todos for the given week using the shared method
    my $filtered_todos = $self->filter_todos_by_date_range($c, $todos, $start_of_week, $end_of_week, 1);

    # Sort todos by time_of_day, then priority, then start_date
    my @sorted_todos = sort { 
        ($a->time_of_day // '00:00:00') cmp ($b->time_of_day // '00:00:00') ||
        ($a->priority // 10) <=> ($b->priority // 10) ||
        ($a->start_date // '') cmp ($b->start_date // '')
    } @$filtered_todos;

    my %week_proj_map;
    eval {
        my @prows = $c->model('DBEncy')->resultset('Project')->search(
            {}, { columns => [qw(id name)] }
        )->all;
        %week_proj_map = map { $_->id => $_->name } @prows;
    };

    # Pre-build todos_by_date and overdue list in Perl so recurrence rules are applied correctly.
    # TT2 cannot compute day-of-week, so weekly/biweekly injection must happen here.
    my %week_todos_by_date;
    my @week_overdue_todos;
    my $first_day = $week_dates[0]{date_str};
    my @done_vals = (3, 4, 'DONE', 'Completed', 'completed', 'Closed', 'closed', 'Done');
    my %done_set  = map { $_ => 1 } @done_vals;

    for my $todo (@sorted_todos) {
        my $sd_raw = $todo->start_date // '';
        my $dd_raw = $todo->due_date   // '';
        $sd_raw = ref($sd_raw) ? $sd_raw->ymd : "$sd_raw";
        $dd_raw = ref($dd_raw) ? $dd_raw->ymd : "$dd_raw";
        my $sd = length($sd_raw) >= 10 ? substr($sd_raw, 0, 10) : '';
        my $dd = length($dd_raw) >= 10 ? substr($dd_raw, 0, 10) : '';

        my $is_done = exists $done_set{ $todo->status // '' };
        my $is_rec  = ($todo->can('is_recurring') ? $todo->is_recurring : 0)
                      || ($todo->subject // '') =~ /\b(lunch|break|standup|morning.break|afternoon.break)\b/i;

        if ($is_rec && !$is_done) {
            my $effective_start = $sd || DateTime->now->ymd;
            for my $day_info (@week_dates) {
                my $d_str = $day_info->{date_str};
                next if $effective_start gt $d_str;
                next unless recurring_matches_date($todo, $d_str);
                my $already = grep { $_->record_id == $todo->record_id }
                              @{ $week_todos_by_date{$d_str} // [] };
                push @{ $week_todos_by_date{$d_str} }, $todo unless $already;
            }
        } else {
            my $anchor = $sd || $dd;
            next unless $anchor;
            if ($anchor lt $first_day) {
                push @week_overdue_todos, $todo unless $is_done;
            } else {
                my $already = grep { $_->record_id == $todo->record_id }
                              @{ $week_todos_by_date{$anchor} // [] };
                push @{ $week_todos_by_date{$anchor} }, $todo unless $already;
            }
        }
    }

    # Add the todos to the stash
    $c->stash(
        todos => \@sorted_todos,
        week_todos_by_date => \%week_todos_by_date,
        week_overdue_todos => \@week_overdue_todos,
        sitename => $c->session->{SiteName},
        start_of_week => $start_of_week,
        end_of_week => $end_of_week,
        prev_week_date => $prev_week_date,
        next_week_date => $next_week_date,
        week_dates => \@week_dates,
        proj_name_map => \%week_proj_map,
        template => 'todo/week.tt',
    );

    $c->forward($c->view('TT'));
}

sub month :Path('/todo/month') :Args {
    my ($self, $c, $date) = @_;

    # Get the Todo model
    my $todo_model = $c->model('Todo');

    # Always produce a plain YYYY-MM-DD string (URL may contain T00:00:00)
    {
        my $iso8601 = DateTime::Format::ISO8601->new;
        my $dt_parsed;
        eval { $dt_parsed = $iso8601->parse_datetime($date) } if defined $date;
        $date = $dt_parsed ? $dt_parsed->ymd : DateTime->now->ymd;
    }

    # Parse the date
    my $dt = DateTime::Format::ISO8601->parse_datetime($date);

    # Calculate the start and end of the month
    my $start_of_month = $dt->clone->set_day(1)->strftime('%Y-%m-%d');
    my $end_of_month = $dt->clone->set_day($dt->month_length)->strftime('%Y-%m-%d');

    # Calculate previous and next month dates
    my $prev_month_date = $dt->clone->subtract(months => 1)->set_day(1)->strftime('%Y-%m-%d');
    my $next_month_date = $dt->clone->add(months => 1)->set_day(1)->strftime('%Y-%m-%d');

    my $calendar_sites_m = $self->_get_user_accessible_sites($c);
    my $todos = $todo_model->get_all_todos_for_calendar($c, $calendar_sites_m);

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

    my $address  = $c->req->address;
    my $is_local = ($address eq '127.0.0.1' || $address eq '::1'
        || $address =~ /^192\.168\./
        || $address =~ /^172\.(1[6-9]|2[0-9]|3[01])\./
        || $address =~ /^10\./);

    unless ($is_local) {
        $self->_api_validate_token($c);
    }

    my $params;
    eval {
        my $body = $c->request->body;
        if ($body) {
            if (ref($body) && $body->can('seek')) {
                seek($body, 0, 0);
                my $raw = do { local $/; <$body> };
                $params = decode_json($raw) if $raw && $raw =~ /\S/;
            } else {
                $params = decode_json($body);
            }
        }
        $params ||= {};
    };
    if ($@) {
        $self->_api_error($c, "Invalid JSON: $@", 'json_parse_error', 400);
    }

    my $schema = $c->model('DBEncy');
    my $todo   = $schema->resultset('Todo')->find($todo_id);

    unless ($todo) {
        $self->_api_error($c, "Todo not found: $todo_id", 'not_found', 404);
    }

    my %allowed = map { $_ => 1 } qw(status priority description developer comments);
    my %update;
    for my $field (keys %$params) {
        $update{$field} = $params->{$field} if $allowed{$field};
    }

    if (%update) {
        $update{last_mod_by}   = 'system';
        $update{last_mod_date} = DateTime->now->ymd;
        $todo->update(\%update);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_todo_update',
            "Todo updated via API: record_id=$todo_id, Fields=" . join(',', keys %update));
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
        id                => $todo->id,
        subject           => $todo->subject,
        description       => $todo->description,
        project_id        => $todo->project_id,
        start_date        => $todo->start_date  ? "${\$todo->start_date}" : undef,
        due_date          => $todo->due_date    ? "${\$todo->due_date}"   : undef,
        priority          => $todo->priority,
        status            => $todo->status,
        developer         => $todo->developer,
        sitename          => $todo->sitename,
        date_time_posted  => $todo->date_time_posted || undef,
        username_of_poster => $todo->username_of_poster,
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

sub quick_close :Path('quick_close') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');

    my $username = $c->session->{username} // '';
    my $roles    = $c->session->{roles} || [];
    my @rl       = ref($roles) eq 'ARRAY' ? @$roles : ($roles);
    unless ($username && $username ne 'anonymous' && grep { /^(admin|developer|editor|devops)$/i } @rl) {
        $c->response->status(403);
        $c->response->body('{"ok":0,"error":"Admin role required"}');
        return;
    }

    my $body_fh = $c->req->body;
    my $body = $body_fh ? do { local $/; <$body_fh> } : '';
    my $data;
    eval { require JSON; $data = JSON::decode_json($body) if $body; };
    my $record_id = $data->{record_id} if $data;
    unless ($record_id) {
        $c->response->status(400);
        $c->response->body('{"ok":0,"error":"Missing record_id"}');
        return;
    }

    my $today = DateTime->now->ymd;
    eval {
        my $todo = $c->model('DBEncy')->resultset('Todo')->find($record_id);
        die "Todo not found\n" unless $todo;

        my $close_time = do { my @t = localtime; sprintf('%02d:%02d:%02d', $t[2], $t[1], $t[0]) };
        $todo->update({
            status        => 3,
            last_mod_by   => $username,
            last_mod_date => $today,
            time_of_day   => $close_time,
        });

        my $proj_code = '';
        if ($todo->project_id) {
            my $proj = eval { $c->model('DBEncy')->resultset('Project')->find($todo->project_id) };
            $proj_code = $proj ? ($proj->project_code || '') : '';
        }
        $c->model('DBEncy')->resultset('Log')->create({
            todo_record_id  => $record_id,
            username        => $username,
            sitename        => $todo->sitename || $c->session->{SiteName},
            project_code    => $proj_code,
            abstract        => 'Quick-closed from Active Priorities panel',
            details         => 'Marked done via quick-close button on DailyPlan by ' . $username,
            start_date      => $today,
            due_date        => $today,
            start_time      => '00:00:00',
            end_time        => '00:00:00',
            time            => '00:00:00',
            status          => 3,
            priority        => $todo->priority || 5,
            last_mod_by     => $username,
            last_mod_date   => $today,
            group_of_poster  => $c->session->{group} || '',
            comments         => '',
            points_processed => 0,
        });
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'quick_close',
            "Failed quick_close for todo $record_id: $@");
        $c->response->body('{"ok":0,"error":' . (JSON::encode_json("$@")) . '}');
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'quick_close',
        "Todo $record_id quick-closed by $username");
    $c->response->body('{"ok":1}');
}

sub quick_priority :Path('quick_priority') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');
    my $username = $c->session->{username} // '';
    unless ($username && $username ne 'anonymous') {
        $c->response->status(403);
        $c->response->body('{"ok":0,"error":"Login required"}');
        return;
    }
    my $body_fh = $c->req->body;
    my $body = $body_fh ? do { local $/; <$body_fh> } : '';
    my $data;
    eval { require JSON; $data = JSON::decode_json($body) if $body; };
    my $record_id = $data->{record_id} if $data;
    my $priority  = $data->{priority}  if $data;
    unless ($record_id && defined $priority && $priority =~ /^\d+$/) {
        $c->response->status(400);
        $c->response->body('{"ok":0,"error":"Missing record_id or priority"}');
        return;
    }
    $priority = int($priority);
    $priority = 1 if $priority < 1;
    $priority = 10 if $priority > 10;
    eval {
        my $todo = $c->model('DBEncy')->resultset('Todo')->find($record_id);
        die "Todo not found\n" unless $todo;
        $todo->update({ priority => $priority, last_mod_by => $username });
    };
    if ($@) {
        $c->response->body('{"ok":0,"error":' . (JSON::encode_json("$@")) . '}');
        return;
    }
    $c->response->body('{"ok":1}');
}

sub triage_stale :Path('triage_stale') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');

    my $username = $c->session->{username} // '';
    my $roles    = $c->session->{roles} || [];
    my @rl       = ref($roles) eq 'ARRAY' ? @$roles : ($roles);
    unless ($username && $username ne 'anonymous' && grep { /^(admin)$/i } @rl) {
        $c->response->status(403);
        $c->response->body('{"ok":0,"error":"Admin role required"}');
        return;
    }

    require POSIX;
    my $now_epoch = time();
    my $count     = 0;

    eval {
        my @done_statuses = (3, 4, 'DONE', 'Completed', 'completed', 'Closed', 'closed', 'Done');
        my @rows = $c->model('DBEncy')->resultset('Todo')->search(
            { status => { -not_in => \@done_statuses } },
            { columns => [qw(record_id priority last_mod_date date_time_posted)] }
        )->all;

        for my $row (@rows) {
            my $activity_str = $row->last_mod_date || $row->date_time_posted || '';
            next unless $activity_str =~ /^(\d{4})-(\d{2})-(\d{2})/;
            my $act_epoch = POSIX::mktime(0, 0, 0, $3, $2 - 1, $1 - 1900);
            my $days_stale = int(($now_epoch - $act_epoch) / 86400);
            next unless $days_stale > 180;
            my $new_priority = ($row->priority || 5) + 2;
            $new_priority = 10 if $new_priority > 10;
            $row->update({ priority => $new_priority });
            $count++;
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'triage_stale', "Error: $@");
        $c->response->body('{"ok":0,"error":' . (JSON::encode_json("$@")) . '}');
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'triage_stale',
        "Triaged $count stale todos by $username");
    $c->response->body('{"ok":1,"count":' . $count . '}');
}

sub _is_recurring {
    my ($subject) = @_;
    return ($subject // '') =~ /\b(lunch|break|standup|daily.standup|morning.break|afternoon.break|morning break|afternoon break)\b/i;
}

sub _estimate_mins_heuristic {
    my ($subject) = @_;
    my $s = lc($subject // '');
    return 15  if $s =~ /morning.break|afternoon.break|\bbreak\b/;
    return 60  if $s =~ /\blunch\b/;
    return 15  if $s =~ /audit|morning audit|check|verify|review|standup|daily standup/;
    return 30  if $s =~ /meeting|call|discuss|triage/;
    return 60  if $s =~ /fix|debug|investigate|diagnose|resolve|test|patch/;
    return 120 if $s =~ /design|plan|spec|document|write|research|analyse|analyze/;
    return 240 if $s =~ /implement|build|create|develop|integrate|refactor|migration/;
    return 30;
}

sub reschedule :Path('reschedule') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');

    my $username = $c->session->{username} // '';
    my $sitename = $c->session->{SiteName} // '';
    my $user_id  = $c->session->{user_id}  // 0;
    my $roles    = $c->session->{roles} || [];
    my @rl       = ref($roles) eq 'ARRAY' ? @$roles : ($roles);
    my $is_admin = grep { /^(admin)$/i } @rl;
    my $is_csc   = ($sitename eq 'CSC' && $is_admin) || $username eq 'Shanta';

    unless ($username && $username ne 'anonymous' && $is_admin) {
        $c->response->status(403);
        $c->response->body('{"ok":0,"error":"Admin role required"}');
        return;
    }

    require POSIX;
    my $now_epoch  = time();
    my $today_dt   = DateTime->now(time_zone => 'local');
    my $today      = $today_dt->ymd;
    my $count      = 0;
    my @errors;

    eval {
        my @done_statuses = (3, 4, 'DONE', 'Completed', 'completed', 'Closed', 'closed', 'Done');

        # Determine accessible sites (same logic as _get_user_accessible_sites)
        my @allowed_sites = ($sitename);
        eval {
            my $uid = $c->session->{user_id};
            if ($uid) {
                my @sr = $c->model('DBEncy')->resultset('UserSiteRole')->search(
                    { user_id => $uid, site_id => { '!=' => undef }, is_active => 1 }
                )->all;
                my %seen = ($sitename => 1);
                for my $r (@sr) {
                    eval {
                        my $s = $c->model('DBEncy')->resultset('Site')->find($r->site_id);
                        push @allowed_sites, $s->name
                            if $s && $s->name && !$seen{$s->name}++;
                    };
                }
            }
        };

        # Fetch open todos for accessible sites (also include todos assigned to user)
        my @user_or_conds = (
            { 'me.sitename' => { -in => \@allowed_sites } },
        );
        push @user_or_conds, { 'me.developer'          => $username } if $username;
        push @user_or_conds, { 'me.username_of_poster' => $username } if $username;

        my @rows = $c->model('DBEncy')->resultset('Todo')->search(
            {
                'me.status' => { -not_in => \@done_statuses },
                -or => \@user_or_conds,
            },
            {
                columns => [qw(record_id priority status is_blocking
                               due_date start_date last_mod_date
                               date_time_posted estimated_man_hours
                               blocked_by_todo_id sitename developer
                               username_of_poster project_id subject
                               time_of_day is_recurring todo_type
                               recurrence_rule is_fixed)],
            }
        )->all;

        # Load ALL fixed events (recurring + appointments/meetings) so we can
        # block their time slots during scheduling.  Fetched separately so that
        # the skip logic in the main loop can still use @rows for non-fixed todos.
        my @fixed_events;
        eval {
            @fixed_events = $c->model('DBEncy')->resultset('Todo')->search(
                {
                    sitename => { -in => \@allowed_sites },
                    -or => [
                        { is_recurring => 1 },
                        { todo_type    => 'appointment' },
                        { todo_type    => 'meeting' },
                        { is_fixed     => 1 },
                    ],
                },
                {
                    columns => [qw(record_id start_date time_of_day
                                   estimated_man_hours is_recurring
                                   todo_type recurrence_rule subject)],
                }
            )->all;
        };
        my %blocked_cache;  # date_str => sorted [[abs_start, abs_end], ...]
        my $get_blocked = sub {
            my ($date_str) = @_;
            return $blocked_cache{$date_str} if exists $blocked_cache{$date_str};
            my @intervals;
            for my $fe (@fixed_events) {
                my $fe_sd_raw = $fe->start_date // '';
                $fe_sd_raw = ref($fe_sd_raw) ? $fe_sd_raw->ymd : "$fe_sd_raw";
                my $fe_sd = length($fe_sd_raw) >= 10 ? substr($fe_sd_raw, 0, 10) : '';
                my $effective_start = $fe_sd || $today;
                next if $effective_start gt $date_str;

                my $is_rec = $fe->is_recurring // 0;
                my $matches;
                if ($is_rec) {
                    $matches = recurring_matches_date($fe, $date_str);
                } elsif ($fe_sd eq $date_str) {
                    $matches = 1;
                }
                next unless $matches;

                my $tod = $fe->time_of_day // '';
                next unless $tod =~ /^(\d+):(\d+)/;
                my $abs_start = $1 * 60 + $2;
                my $dur = ($fe->estimated_man_hours // 0);
                $dur = 30 unless $dur > 0;
                push @intervals, [$abs_start, $abs_start + $dur];
            }
            $blocked_cache{$date_str} = [sort { $a->[0] <=> $b->[0] } @intervals];
            return $blocked_cache{$date_str};
        };

        # Build project sort_order lookup (separate query — avoids INNER JOIN exclusion)
        my %proj_sort;
        {
            my @pids = grep { defined $_ && $_ > 0 }
                       map  { $_->project_id } @rows;
            if (@pids) {
                my @projs = $c->model('DBEncy')->resultset('Project')->search(
                    { id => { -in => \@pids } },
                    { columns => [qw(id sort_order)] }
                )->all;
                %proj_sort = map { $_->id => ($_->sort_order // 9999) } @projs;
            }
        }

        # Sort: blocking first, then project sort_order ASC (lower=higher prio),
        #       then todo priority ASC (1=highest), then due_date ASC (soonest first)
        @rows = sort {
            ($b->is_blocking || 0) <=> ($a->is_blocking || 0)
            || ($proj_sort{ $a->project_id || 0 } // 9999) <=> ($proj_sort{ $b->project_id || 0 } // 9999)
            || (($a->priority || 9) <=> ($b->priority || 9))
            || (($a->due_date || '9999-12-31') cmp ($b->due_date || '9999-12-31'))
        } @rows;

        # Pre-fetch log durations in MINUTES per todo_record_id
        my %log_duration_mins;
        {
            my @todo_ids = map { $_->record_id } @rows;
            if (@todo_ids) {
                eval {
                    my @log_rows = $c->model('DBEncy')->resultset('Log')->search(
                        { todo_record_id => { -in => \@todo_ids } },
                        { columns => [qw(todo_record_id start_time end_time)] }
                    )->all;
                    my %durations;
                    for my $lr (@log_rows) {
                        my $st = $lr->start_time // '';
                        my $et = $lr->end_time   // '';
                        next unless $st && $et;
                        next unless $st =~ /^(\d+):(\d+)/ && $et =~ /^(\d+):(\d+)/;
                        my ($sh, $sm) = ($st =~ /^(\d+):(\d+)/);
                        my ($eh, $em) = ($et =~ /^(\d+):(\d+)/);
                        my $dur_mins = $eh * 60 + $em - $sh * 60 - $sm;
                        push @{ $durations{ $lr->todo_record_id } }, $dur_mins if $dur_mins > 0;
                    }
                    for my $tid (keys %durations) {
                        my @d = @{ $durations{$tid} };
                        my $sum = 0; $sum += $_ for @d;
                        my $avg = $sum / scalar(@d);
                        $log_duration_mins{$tid} = $avg if $avg >= 5;
                    }
                };
            }
        }

        # Distribute todos from today forward using start_date and time_of_day
        # Work window: 09:00 – 17:00
        # Today: start from current time (min 09:00); future days: start from 09:00
        my $WORK_START_MIN      = 9 * 60;   # 540 – earliest allowed start
        my $WORK_END_MIN        = 17 * 60;  # 1020 – end of work day
        my $NEXT_DAY_START_MIN  = 9 * 60;   # 540 – start of work day for future days

        my $cur_dt      = $today_dt->clone;
        my $now_abs_min = $today_dt->hour * 60 + $today_dt->minute;

        # Start from current time; snap to 09:00 if before 9 AM;
        # if already past work end, roll to tomorrow at 09:00
        my $cur_abs_min;
        if ($now_abs_min >= $WORK_END_MIN) {
            $cur_dt->add(days => 1);
            $cur_abs_min = $NEXT_DAY_START_MIN;
        } elsif ($now_abs_min < $WORK_START_MIN) {
            $cur_abs_min = $WORK_START_MIN;
        } else {
            $cur_abs_min = $now_abs_min;
        }

        for my $todo (@rows) {
            # Skip recurring events, appointments, and is_fixed todos — fixed in time, never rescheduled.
            my $skip_rec   = $todo->can('is_recurring') ? $todo->is_recurring : _is_recurring($todo->subject // '');
            my $skip_appt  = $todo->can('todo_type') && ($todo->todo_type // 'task') eq 'appointment';
            my $skip_fixed = $todo->can('is_fixed') ? ($todo->is_fixed // 0) : 0;
            next if $skip_rec || $skip_appt || $skip_fixed;

            # estimated_man_hours is stored as MINUTES (integer).
            my $stored_mins    = $todo->estimated_man_hours // 0;
            my $heuristic_mins;
            if (exists $log_duration_mins{ $todo->record_id }) {
                $heuristic_mins = int($log_duration_mins{ $todo->record_id } + 0.5);
            } else {
                $heuristic_mins = _estimate_mins_heuristic($todo->subject // '');
            }
            my $est_mins = ($stored_mins > ($heuristic_mins // 0)) ? $stored_mins : ($heuristic_mins // 0);
            $est_mins = 5 if $est_mins < 5;

            # Roll to next work day if we are at or past work end
            while ($cur_abs_min >= $WORK_END_MIN) {
                $cur_dt->add(days => 1);
                $cur_abs_min = $NEXT_DAY_START_MIN;
            }

            my $new_start = $cur_dt->ymd;

            # Advance $cur_abs_min past any fixed-event conflicts for this day.
            # All intervals in $get_blocked are absolute minutes from midnight.
            # Loop until the window [$cur_abs_min, $cur_abs_min+$est_mins) is clear.
            {
                my $safe_iters = 0;
                my $changed    = 1;
                while ($changed && $safe_iters++ < 50) {
                    $changed = 0;
                    my $blocked = $get_blocked->($new_start);
                    for my $b (@$blocked) {
                        my ($bs, $be) = @$b;
                        if ($cur_abs_min < $be && $cur_abs_min + $est_mins > $bs) {
                            $cur_abs_min = $be;
                            $changed     = 1;
                        }
                    }
                    # If a conflict pushed us past work end, roll to next day and retry
                    if ($cur_abs_min >= $WORK_END_MIN) {
                        $cur_dt->add(days => 1);
                        $cur_abs_min = $NEXT_DAY_START_MIN;
                        $new_start   = $cur_dt->ymd;
                        $changed     = 1;
                    }
                }
            }

            my $slot_abs_min = $cur_abs_min;
            my $new_time_str = sprintf('%02d:%02d:00',
                                   int($slot_abs_min / 60),
                                   $slot_abs_min % 60);

            $cur_abs_min += $est_mins;

            # Recalculate priority based on staleness + due date + blocking
            my $orig_priority = $todo->priority || 5;
            my $new_priority  = $orig_priority;

            my $activity_str = $todo->last_mod_date || $todo->date_time_posted || '';
            my $days_stale = 0;
            if ($activity_str =~ /^(\d{4})-(\d{2})-(\d{2})/) {
                my $act_epoch = POSIX::mktime(0, 0, 0, $3, $2 - 1, $1 - 1900);
                $days_stale   = int(($now_epoch - $act_epoch) / 86400);
                $new_priority = ($new_priority + 2 <= 10) ? $new_priority + 2 : 10
                    if $days_stale > 180;
            }

            my $new_due_date;
            if ($todo->due_date && $todo->due_date =~ /^(\d{4})-(\d{2})-(\d{2})/) {
                my $due_epoch      = POSIX::mktime(0, 0, 0, $3, $2 - 1, $1 - 1900);
                my $days_until_due = int(($due_epoch - $now_epoch) / 86400);
                if ($days_until_due < 0) {
                    $new_priority = ($new_priority - 2 >= 1) ? $new_priority - 2 : 1;
                    $new_due_date = $today;
                } elsif ($days_until_due <= 7) {
                    $new_priority = ($new_priority - 1 >= 1) ? $new_priority - 1 : 1;
                }
            }

            if ($todo->is_blocking) {
                $new_priority = ($new_priority - 1 >= 1) ? $new_priority - 1 : 1;
            }

            my $end_abs_min   = $slot_abs_min + $est_mins;
            # Cap end at 23:59:59 to prevent invalid datetime values (DATETIME column rejects >23:xx)
            my $end_h = int($end_abs_min / 60);
            my $end_m = $end_abs_min % 60;
            if ($end_h >= 24) { $end_h = 23; $end_m = 59; }
            my $end_time_str  = sprintf('%02d:%02d:00', $end_h, $end_m);
            my $sched_start_str = $new_start . ' ' . $new_time_str;
            my $sched_end_str   = $new_start . ' ' . $end_time_str;

            my %update = (
                start_date       => $new_start,
                time_of_day      => $new_time_str,
                scheduled_start  => $sched_start_str,
                scheduled_end    => $sched_end_str,
                estimated_man_hours => int($est_mins + 0.5) || 5,
                priority         => $new_priority,
                last_mod_by      => 'reschedule',
                last_mod_date    => $today,
            );
            $update{due_date} = $new_due_date if $new_due_date;

            eval { $todo->update(\%update) };
            if ($@) { push @errors, "todo " . $todo->record_id . ": $@"; }
            else     { $count++; }
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'reschedule', "Error: $@");
        $c->response->body('{"ok":0,"error":' . (JSON::encode_json("$@")) . '}');
        return;
    }

    my $error_count = scalar(@errors);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'reschedule',
        "Reschedule by $username: $count todos scheduled, $error_count errors, from $today forward");
    $c->response->body('{"ok":1,"count":' . $count . ',"error_count":' . $error_count . ',"today":"' . $today . '","errors":' . (JSON::encode_json(\@errors)) . '}');
}

sub open_log :Path('open_log') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');

    my $username = $c->session->{username} // '';
    my $roles    = $c->session->{roles} || [];
    my @rl       = ref($roles) eq 'ARRAY' ? @$roles : ($roles);
    unless ($username && $username ne 'anonymous' && grep { /^(admin|developer|editor|devops)$/i } @rl) {
        $c->response->status(403);
        $c->response->body('{"ok":0,"error":"Admin role required"}');
        return;
    }

    my $body_fh = $c->req->body;
    my $body    = $body_fh ? do { local $/; <$body_fh> } : '';
    my $data;
    eval { require JSON; $data = JSON::decode_json($body) if $body; };
    my $record_id = $data->{record_id} if $data;
    unless ($record_id) {
        $c->response->status(400);
        $c->response->body('{"ok":0,"error":"Missing record_id"}');
        return;
    }

    my $now   = DateTime->now;
    my $today = $now->ymd;
    my $time  = $now->hms;

    eval {
        my $todo = $c->model('DBEncy')->resultset('Todo')->find($record_id);
        die "Todo not found\n" unless $todo;

        my $existing_open = $c->model('DBEncy')->resultset('Log')->search({
            todo_record_id => $record_id,
            end_time       => '00:00:00',
            status         => { '!=' => 3 },
        })->first;
        die "Log already open for this todo\n" if $existing_open;

        my $proj_code = '';
        if ($todo->project_id) {
            my $proj = eval { $c->model('DBEncy')->resultset('Project')->find($todo->project_id) };
            $proj_code = $proj ? ($proj->project_code || '') : '';
        }

        my $log = $c->model('DBEncy')->resultset('Log')->create({
            todo_record_id  => $record_id,
            username        => $username,
            sitename        => $todo->sitename || $c->session->{SiteName},
            project_code    => $proj_code,
            abstract        => 'Started: ' . $todo->subject,
            details         => 'Work begun on this step by ' . $username,
            start_date      => $today,
            due_date        => $todo->due_date || $today,
            start_time      => $time,
            end_time        => '00:00:00',
            time            => '00:00:00',
            status          => 2,
            priority        => $todo->priority || 5,
            last_mod_by     => $username,
            last_mod_date   => $today,
            group_of_poster => $c->session->{group} || '',
            comments        => $todo->comments || '',
        });

        $todo->update({
            status        => 2,
            last_mod_by   => $username,
            last_mod_date => $today,
        });

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'open_log',
            "Log opened for todo $record_id by $username (log_id=" . $log->record_id . ")");
        $c->response->body('{"ok":1,"log_id":' . $log->record_id . '}');
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'open_log',
            "Failed open_log for todo $record_id: $@");
        $c->response->body('{"ok":0,"error":' . (JSON::encode_json("$@")) . '}');
    }
}

sub next_step :Path('next_step') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');

    my $username = $c->session->{username} // '';
    my $roles    = $c->session->{roles} || [];
    my @rl       = ref($roles) eq 'ARRAY' ? @$roles : ($roles);
    unless ($username && $username ne 'anonymous' && grep { /^(admin|developer|editor|devops)$/i } @rl) {
        $c->response->status(403);
        $c->response->body('{"ok":0,"error":"Admin role required"}');
        return;
    }

    my $body_fh = $c->req->body;
    my $body    = $body_fh ? do { local $/; <$body_fh> } : '';
    my $data;
    eval { require JSON; $data = JSON::decode_json($body) if $body; };
    my $record_id = $data->{record_id} if $data;
    unless ($record_id) {
        $c->response->status(400);
        $c->response->body('{"ok":0,"error":"Missing record_id"}');
        return;
    }

    my $now   = DateTime->now;
    my $today = $now->ymd;
    my $time  = $now->hms;
    my $next_todo_id;

    eval {
        my $schema = $c->model('DBEncy');
        my $todo   = $schema->resultset('Todo')->find($record_id);
        die "Todo not found\n" unless $todo;

        my $open_log = $schema->resultset('Log')->search({
            todo_record_id => $record_id,
            end_time       => '00:00:00',
        }, { order_by => { -desc => 'record_id' } })->first;

        if ($open_log) {
            my $start = $open_log->start_time || '00:00:00';
            my ($sh, $sm, $ss) = split(':', $start);
            $sh = int($sh // 0); $sm = int($sm // 0); $ss = int($ss // 0);
            my ($eh, $em, $es) = split(':', $time);
            $eh = int($eh // 0); $em = int($em // 0); $es = int($es // 0);
            my $elapsed_secs = ($eh * 3600 + $em * 60 + $es) - ($sh * 3600 + $sm * 60 + $ss);
            $elapsed_secs = 0 if $elapsed_secs < 0;
            my $elapsed = sprintf('%02d:%02d:%02d',
                int($elapsed_secs / 3600),
                int(($elapsed_secs % 3600) / 60),
                $elapsed_secs % 60);

            $open_log->update({
                end_time      => $time,
                time          => $elapsed,
                status        => 3,
                last_mod_by   => $username,
                last_mod_date => $today,
                details       => ($open_log->details || '') . "\nCompleted by $username at $today $time.",
            });

            my $existing_accum = $todo->accumulative_time || '00:00:00';
            my ($ah, $am, $as_) = split(':', $existing_accum);
            $ah = int($ah // 0); $am = int($am // 0); $as_ = int($as_ // 0);
            my $total_secs = ($ah * 3600 + $am * 60 + $as_) + $elapsed_secs;
            my $new_accum  = sprintf('%02d:%02d:%02d',
                int($total_secs / 3600),
                int(($total_secs % 3600) / 60),
                $total_secs % 60);
            $todo->update({
                status            => 3,
                accumulative_time => $new_accum,
                last_mod_by       => $username,
                last_mod_date     => $today,
            });
        } else {
            $todo->update({
                status        => 3,
                last_mod_by   => $username,
                last_mod_date => $today,
            });
        }

        if ($todo->parent_id) {
            my $next = $schema->resultset('Todo')->search({
                parent_id  => $todo->parent_id,
                sort_order => { '>' => ($todo->sort_order || 0) },
                status     => { '!=' => 3 },
            }, {
                order_by => { -asc => 'sort_order' },
                rows     => 1,
            })->first;

            if ($next) {
                $next_todo_id = $next->record_id;

                my $proj_code = '';
                if ($next->project_id) {
                    my $proj = eval { $schema->resultset('Project')->find($next->project_id) };
                    $proj_code = $proj ? ($proj->project_code || '') : '';
                }

                $schema->resultset('Log')->create({
                    todo_record_id  => $next->record_id,
                    username        => $username,
                    sitename        => $next->sitename || $c->session->{SiteName},
                    project_code    => $proj_code,
                    abstract        => 'Started: ' . $next->subject,
                    details         => 'Work begun automatically via Next Step by ' . $username,
                    start_date      => $today,
                    due_date        => $next->due_date || $today,
                    start_time      => $time,
                    end_time        => '00:00:00',
                    time            => '00:00:00',
                    status          => 2,
                    priority        => $next->priority || 5,
                    last_mod_by     => $username,
                    last_mod_date   => $today,
                    group_of_poster => $c->session->{group} || '',
                    comments        => $next->comments || '',
                });

                $next->update({
                    status        => 2,
                    last_mod_by   => $username,
                    last_mod_date => $today,
                });
            }
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'next_step',
            "Failed next_step for todo $record_id: $@");
        $c->response->body('{"ok":0,"error":' . (JSON::encode_json("$@")) . '}');
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'next_step',
        "next_step by $username: todo $record_id done" .
        ($next_todo_id ? ", advanced to $next_todo_id" : ", no next step found"));

    my $body_out = '{"ok":1,"closed_todo_id":' . $record_id;
    $body_out .= ',"next_todo_id":' . $next_todo_id if $next_todo_id;
    $body_out .= '}';
    $c->response->body($body_out);
}

1;
