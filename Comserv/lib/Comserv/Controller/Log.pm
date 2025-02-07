package Comserv::Controller::Log;
use Moose;
use namespace::autoclean;
use DateTime;
use DateTime::TimeZone;
use DateTime::Format::Strptime;
use Data::Dumper;
use Comserv::Util::Logging;
BEGIN { extends 'Catalyst::Controller'; }

has 'record_id' => (is => 'rw', isa => 'Str');
has 'priority' => (is => 'rw', isa => 'HashRef');
has 'status' => (is => 'rw', isa => 'HashRef');

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);
sub _build_logging {
    return Comserv::Util::Logging->instance;
}

sub BUILD {
    my $self = shift;
    $self->priority({ map { $_ => $_ } (1..10) });
    $self->status({
        1 => 'NEW',
        2 => 'IN PROGRESS',
        3 => 'COMPLETED',
    });
}

sub index :Path('/log') :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Accessed log index");
    $c->stash->{debug_errors} //= [];
    $c->stash(debug_errors => []);
    # Retrieve the status from the query parameters, default to 'open'
    my $status = $c->request->params->{status} // 'open';

    # Create a new instance of the Log model
    my $log_model = Comserv::Model::Log->new();

    # Fetch logs based on the status
    my $rs;
    if ($status eq 'all') {
        $rs = $log_model->get_logs($c, 'all');  # Fetch all logs without status filter
    } elsif ($status eq 'open') {
        $rs = $log_model->get_logs($c, 'open');  # Fetch open logs (status not equal to 3)
    } else {
        $rs = $log_model->get_logs($c, $status);  # Fetch logs with specific status
    }

    # Debug: Print all logs
    #$self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Fetched logs: " . Dumper([$rs->all]));

    $c->stash->{debug_errors} //= [];  # Ensure debug_errors is initialized
    # Pass the logs and status to the template
    $c->stash(
        logs => [$rs->all],
        status => $status,  # Pass the current status to the template
        template => 'log/index.tt'
    );
}

sub details :Path('/log/details') :Args(0) {
    my ($self, $c) = @_;

    # Retrieve the record_id from the request parameters
    my $record_id = $c->request->body_parameters->{record_id};

    # Fetch the log entry from the database
    my $log = $c->model('DBEncy')->resultset('Log')->find($record_id);

    if ($log) {
        # Get the current local time
        my $current_time = DateTime->now(time_zone => 'local')->strftime('%H:%M');

        # Pass the log entry and dropdown data to the template
        $c->stash(
            log => $log,
            build_priority => $self->priority,
            build_status   => $self->status,
            end_time       => $current_time,  # Use $current_time here
            template       => 'log/details.tt'
        );
    } else {
        $c->response->body('Log entry not found.');
    }
}

sub update :Path('/log/update') :Args(0) {
    my ( $self, $c ) = @_;

    # Get the record_id from the form data
    my $record_id = $c->request->body_parameters->{record_id};

    # Fetch the log record
    my $schema = $c->model('DBEncy');
    my $log = $schema->resultset('Log')->find($record_id);

    # Check if the log entry exists
    if (!$log) {
        $c->response->body('Log entry not found.');
        return;
    }

    # Get the start_time and end_time from the form data
    my $start_time_str = $c->request->body_parameters->{start_time};
    my $end_time_str = $c->request->body_parameters->{end_time};

    # Get the status from the form data
    my $status = $c->request->body_parameters->{status};

    # Create a DateTime::Format::Strptime object for parsing the time strings
    my $strp = DateTime::Format::Strptime->new(
        pattern   => '%H:%M',
        time_zone => 'local',
    );

    # Convert the start_time string to a DateTime object
    my $start_time = $strp->parse_datetime($start_time_str);
    my $end_time;
    my $time;

    # Calculate the elapsed time only if the status is set to 'COMPLETED' (3)
    if ($status == 3) {
        # Set the end_time to the current time
        $end_time = DateTime->now(time_zone => 'local');

        # Calculate the difference between the end time and the start time
        my $duration = $end_time->subtract_datetime($start_time);

        # Convert the duration to the format 'HH:MM'
        $time = sprintf("%02d:%02d", $duration->hours, $duration->minutes);

        # Update the end_time_str to the current time for COMPLETED status
        $end_time_str = $end_time->strftime('%H:%M');
    } else {
        # If not 'COMPLETED', use the provided end_time_str and do not calculate time
        $end_time = $strp->parse_datetime($end_time_str);
        $time = $c->request->body_parameters->{time}; # Use existing time value
    }

    # Get the new values from the form data
    my $new_values = {
        sitename => $c->request->body_parameters->{sitename},
        start_date => $c->request->body_parameters->{start_date},
        project_code => $c->request->body_parameters->{project_code},
        due_date => $c->request->body_parameters->{due_date},
        abstract => $c->request->body_parameters->{abstract},
        details => $c->request->body_parameters->{details},
        start_time => $start_time_str,
        end_time => $end_time_str,
        time => $time,
        group_of_poster => $c->session->{roles},
        status => $status,
        priority => $c->request->body_parameters->{priority},
        comments => $c->request->body_parameters->{comments},
    };

    # Validate the new values
    # This is a placeholder for your validation logic
    # You should replace this with your actual validation logic
    if (0) { # replace with your validation condition
        $c->response->body('Invalid data.');
        return;
    }

    # Create a new instance of the Log model
    my $log_model = Comserv::Model::Log->new();

    # Call the modify method on the Log model instance
    $log_model->modify($log, $new_values);

    # Redirect to the log details page after successful update
    $c->response->redirect($c->uri_for("/log", { record_id => $record_id }));
}

# This method will only display the form
sub log_form :Path('/log/log_form') :Args(0) {
    my ($self, $c) = @_;

    # Retrieve the record_id (todo_id) from the POST request parameters
    my $todo_id = $c->request->body_parameters->{record_id};

    # Ensure todo_id is provided
    unless ($todo_id) {
        $c->response->body('Todo ID (record_id) is required.');
        return;
    }

    # Fetch the todo record from the 'todo' table using the correct model
    my $todo = $c->model('DBEncy')->resultset('Todo')->find($todo_id);

    # Ensure the todo record exists
    # Fetch the project_id from the todo record
    my $project_id = $todo ? $todo->project_id : undef;

    # Fetch the current project details if project_id exists
    my $current_project;
    if ($project_id) {
        $current_project = $c->model('DBEncy')->resultset('Project')->find($project_id);
    }

    unless ($todo) {
        $c->response->body('Todo record not found.');
        return;
    }

    # Extract values from the todo record for the form
    my $sitename     = $todo->sitename // '';         # Site name
    my $priority     = $todo->priority // '';         # Priority level
    my $status       = $todo->status // '';           # Status
    my $start_date   = $todo->start_date // '';       # Start date
    my $due_date     = $todo->due_date // '';         # Due date
    my $abstract     = $todo->subject // '';          # Use 'subject' instead of 'abstract'
    my $details      = $todo->description // '';      # Use 'description' instead of 'details'
    my $comments     = $todo->comments // '';         # Comments

    # Get dropdown values for priority and status from Log's BUILD method
    my $build_priority = $self->priority;  # Retrieves priority dropdown from BUILD
    my $build_status   = $self->status;    # Retrieves status dropdown from BUILD

    # Fetch project data from the Project Controller
    my $project_controller = $c->controller('Project');
    my $projects = $project_controller->fetch_projects_with_subprojects($c);

    # Set the values to the stash for rendering the template
    $c->stash(
        template        => 'log/log_form.tt',
        todo_record_id  => $todo_id,        # Pass todo_id for the form
        site_name       => $sitename,       # Matched to [% site_name %] in the template
        projects        => $projects,       # Project list passed to template
        start_date      => $start_date,
        due_date        => $due_date,
        current_project_id => $project_id,  # Pass project_id to template
        current_project    => $current_project,  # Pass current project details
        abstract        => $abstract,       # Use 'subject' for [% abstract %]
        details         => $details,        # Use 'description' for [% details %]
        priority        => $priority,       # Matches [% priority %] in the template
        status          => $status,         # Matches [% status %] in the template
        build_priority  => $build_priority, # Dropdown priority list from BUILD
        build_status    => $build_status,   # Dropdown status list from BUILD
        comments        => $comments,
    );
}

sub create_log :Path('/log/create_log'):Args() {
    my ( $self, $c ) = @_;

    # Create new log entry
    my $schema = $c->model('DBEncy');
    my $rs = $schema->resultset('Log');
    my $referer = $c->request->referer;

    # Log the referring page for debugging
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_log', "Referring page: $referer");

    # Check if record_id is provided and valid
    my $record_id = $c->request->body_parameters->{todo_record_id};

    # Enhanced validation for record_id
    unless ($record_id) {
        $self->logging->log_with_details(
            $c, 
            'error', 
            __FILE__, 
            __LINE__, 
            'create_log', 
            'Todo record ID is missing or invalid.'
        );
        $c->stash(error_msg => 'Invalid Todo Record. Please select a valid Todo.');
        $c->stash(template => 'log/log_form.tt');
        return;
    }

    # Validate that the todo record exists
    my $todo = $schema->resultset('Todo')->find($record_id);
    unless ($todo) {
        $self->logging->log_with_details(
            $c, 
            'error', 
            __FILE__, 
            __LINE__, 
            'create_log', "Todo record with ID $record_id not found."
        );
        $c->stash(error_msg => "Todo record not found. Please select a valid Todo.");
        $c->stash(template => 'log/log_form.tt');
        return;
    }

    # Retrieve input parameters
    my $start_date = $c->request->body_parameters->{start_date} // '';
    my $owner = $c->request->body_parameters->{owner} || 'none';

    # Check if start_date is empty
    if ($start_date eq '') {
        $start_date = undef;  # Set start_date to NULL if it's empty
    }

    # Retrieve subject from form data
    my $subject = $c->request->body_parameters->{abstract};

    # Check if subject is empty or undefined
    if (!defined $subject || $subject =~ /^\s*$/) {
        # Log the validation failure
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_log', "Abstract is missing or empty.");

        # Redirect back to log_form with an error message
        $c->stash(
            todo_record_id => $c->request->body_parameters->{todo_record_id},
            owner => $c->request->body_parameters->{owner}||'none',
            sitename => $c->session->{SiteName},
            start_date => $start_date,
            project_code => $c->request->body_parameters->{project_code},
            due_date => $c->request->body_parameters->{due_date},
            abstract => $subject,
            # Add other necessary fields here
        );

        # Render the form again
        $c->stash->{template} = 'log/log_form.tt';
        return;
    }

    # Retrieve start_time and end_time from form data
    my $start_time = $c->request->body_parameters->{start_time};
    my $end_time = $c->request->body_parameters->{end_time};

    # Set end_time to a default value if it's an empty string or undefined
    $end_time = '00:00:00' if !defined $end_time || $end_time eq '';

    # Calculate time difference
    my ($start_hour, $start_min) = split(':', $start_time);
    my ($end_hour, $end_min) = defined $end_time ? split(':', $end_time) : (0, 0);
    my $time_diff_in_minutes = ($end_hour - $start_hour) * 60 + ($end_min - $start_min);

    # Convert time difference in minutes to 'HH:MM:SS' format
    my $hours = int($time_diff_in_minutes / 60);
    my $minutes = $time_diff_in_minutes % 60;
    my $seconds = 0;  # Assuming there are no seconds in the time difference
    my $time_diff = sprintf("%02d:%02d:%02d", $hours, $minutes, $seconds);

    # Default to current date if no start_date is provided
    my $current_date = DateTime->now(time_zone => 'local')->ymd;
    my $logEntry = $rs->create({
        todo_record_id => $record_id,
        owner => $owner,
        sitename => $c->session->{SiteName},
        start_date => $start_date || $current_date,
        project_code => $c->request->body_parameters->{project_code},
        due_date => $c->request->body_parameters->{due_date},
        abstract => $subject,
        details => $c->request->body_parameters->{details},
        start_time => $start_time,
        end_time => $end_time,  # Use default value if not provided
        time => $time_diff,
        group_of_poster => $c->session->{roles},
        status => $c->request->body_parameters->{status},
        priority => $c->request->body_parameters->{priority},
        last_mod_by => $c->session->{username},
        last_mod_date => DateTime->now->ymd,
        comments => $c->request->body_parameters->{comments} // ''
    });

    # Error handling during log creation
    if ($@ || !$logEntry)
 {
        $self->logging->log_with_details(
            $c, 'error', __FILE__, __LINE__, 'create_log',
            "Failed to create log entry. Error: $@"
        );

        $c->stash(error_msg => 'Error creating log entry, please try again.');
        $c->response->redirect($c->uri_for('/', { record_id =>
 $record_id }));
        return;
    }

    # Log the success event
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_log', "Log entry created successfully: ID " . $logEntry->id);

    # Redirect to the referring page and retain necessary parameters
    my $redirect_url = $referer;
    $redirect_url .= "?record_id=" . $logEntry->id if $logEntry->id;

    # Log the redirection URL
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_log', "Redirecting to: $redirect_url");
$c->flash->{success_msg} = 'Log entry created successfully';
$c->response->redirect($c->uri_for('/todo/details', { record_id => $logEntry->todo_record_id }));
}

__PACKAGE__->meta->make_immutable;

1;
