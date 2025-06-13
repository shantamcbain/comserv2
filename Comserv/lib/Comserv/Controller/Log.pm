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
    is      => 'ro',
    default => sub {Comserv::Util::Logging->instance}
);
sub _build_logging {
    return Comserv::Util::Logging->instance;
}

# Set content type negotiation
sub begin :Private {
    my ($self, $c) = @_;
    $c->response->content_type('text/html');
}

sub BUILD {
    my $self = shift;
    $self->priority({ map {$_ => $_} (1 .. 10) });
    $self->status({
        1 => 'NEW',
        2 => 'IN PROGRESS',
        3 => 'DONE',
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

    $c->stash->{debug_errors} //= []; # Ensure debug_errors is initialized
    # Pass the logs and status to the template
    $c->stash(
        logs     => [ $rs->all ],
        status   => $status, # Pass the current status to the template
        template => 'log/index.tt'
    );
}

sub details :Path('/log/details') :Args(0) {
    my ($self, $c) = @_;

    my $record_id = $c->request->body_parameters->{record_id};
    my $log = $c->model('DBEncy')->resultset('Log')->find($record_id);

    if ($log) {
        # Get the current local time
        my $current_time = DateTime->now(time_zone => 'local')->strftime('%H:%M');

        # Pass the log entry and dropdown data to the template
        $c->stash(
            log            => $log,
            build_priority => $self->priority,
            build_status   => $self->status,
            end_time       => $current_time, # Use $current_time here
            template       => 'log/details.tt'
        );
    } else {
        $c->response->body('Log entry not found.');
    }
    $c->forward($c->view('TT'));
}
sub update :Path('/log/update') :Args(0) {
    my ($self, $c) = @_;

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

    # Calculate the elapsed time only if the status is set to 'DONE' (3)
    if ($status == 3) {
        # Set the end_time to the current time
        $end_time = DateTime->now(time_zone => 'local');

        # Calculate the difference between the end time and the start time
        my $duration = $end_time->subtract_datetime($start_time);

        # Convert the duration to the format 'HH:MM'
        $time = sprintf("%02d:%02d", $duration->hours, $duration->minutes);

        # Update the end_time_str to the current time
        $end_time_str = $end_time->strftime('%H:%M');
    }
    else {
        # If not 'DONE', use the provided end_time_str and do not calculate time
        $end_time = $strp->parse_datetime($end_time_str);
        $time = $c->request->body_parameters->{time}; # Use existing time value
    }

    # Convert roles array to string if it's an array reference
    my $group_of_poster = 'default';
    if (defined $c->session->{roles}) {
        if (ref $c->session->{roles} eq 'ARRAY') {
            $group_of_poster = join(',', @{$c->session->{roles}});
        } else {
            $group_of_poster = $c->session->{roles};
        }
    }

    # Log the group_of_poster value for debugging
    $self->logging->log_with_details(
        $c, 'debug', __FILE__, __LINE__, 'update',
        "Setting group_of_poster to: $group_of_poster"
    );

    # Get the new values from the form data
    my $new_values = {
        sitename        => $c->request->body_parameters->{sitename},
        start_date      => $c->request->body_parameters->{start_date},
        project_code    => $c->request->body_parameters->{project_code},
        due_date        => $c->request->body_parameters->{due_date},
        abstract        => $c->request->body_parameters->{abstract},
        details         => $c->request->body_parameters->{details},
        start_time      => $start_time_str,
        end_time        => $end_time_str,
        time            => $time,
        group_of_poster => $group_of_poster, # Use the converted string value
        status          => $status,
        priority        => $c->request->body_parameters->{priority},
        comments        => $c->request->body_parameters->{comments},
    };

    # Validate the new values
    # This is a placeholder for your validation logic
    # You should replace this with your actual validation logic
    if (0) {
        # replace with your validation condition
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
sub log_form :Path('/log/log_form') :Args() {
    my ($self, $c) = @_;
    my $schema = $c->model('DBEncy');

    my $todo_record_id = $c->request->parameters->{todo_record_id} || '';

    # Ensure record_id is never undefined
    my $log = Comserv::Model::Log->new(record_id => $todo_record_id || '');
    my $todo = Comserv::Model::Todo->new();
    my $todo_record = $todo_record_id ? $todo->fetch_todo_record($c, $todo_record_id) : undef;

    # Get the current time
    my $current_time = DateTime->now->strftime('%H:%M:%S');

    # We'll use the current time for both start_time and end_time by default
    my $current_time_short = DateTime->now->strftime('%H:%M');

    # Fetch project data from the Project Controller
    my $project_controller = $c->controller('Project');
    my $projects = $project_controller->fetch_projects_with_subprojects($c);

    # Fetch available sites from the Site Controller
    my $site_controller = $c->controller('Site');
    my $sites = $site_controller->fetch_available_sites($c);

    # Create form_data for project_list.tt and site_list.tt
    my $form_data = {};

    # Set parent_id in form_data if todo_record has a project_id
    if ($todo_record && $todo_record->project_id) {
        $form_data->{parent_id} = $todo_record->project_id;
        $self->logging->log_with_details(
            $c, 'info', __FILE__, __LINE__, 'log_form',
            "Located project ID for form_data: " . $todo_record->project_id
        );
    }

    # Add the priority, status, and record_id to the stash
    $c->stash(
        build_priority => $self->priority,
        build_status   => $self->status,
        priority       => $todo_record ? $todo_record->priority : '',
        status         => $todo_record ? $todo_record->status : '',
        project_id     => $todo_record ? $todo_record->project_id : '',
        todo_record_id => $todo_record ? $todo_record->record_id : $todo_record_id,
        start_date     => $todo_record ? $todo_record->start_date : '',
        site_name      => $todo_record ? $todo_record->sitename : $c->session->{SiteName},
        due_date       => $todo_record ? $todo_record->due_date : '',
        abstract       => $todo_record ? $todo_record->subject : '',
        details        => $todo_record ? $todo_record->description : '',
        comments       => $todo_record ? $todo_record->comments : '',
        start_time     => $current_time_short, # Set start_time to current time
        end_time       => $current_time_short, # Set end_time to current time
        projects       => $projects,     # Add projects for selection
        sites          => $sites,        # Add sites for selection
        form_data      => $form_data,    # Add form_data for project_list.tt and site_list.tt
    );

    # Render the form
    $c->stash->{template} = 'log/log_form.tt';
}

sub create_log :Path('/log/create_log') :Args() {
    my ($self, $c) = @_;

    # Create new log entry
    my $schema = $c->model('DBEncy');
    my $rs = $schema->resultset('Log');

    # Retrieve start_date from form data
    my $start_date = $c->request->body_parameters->{start_date};
    # Set owner to 'none' if it's not provided
    my $owner = $c->request->body_parameters->{owner} || 'none';

    # Check if start_date is empty
    if ($start_date eq '') {
        $start_date = undef; # Set start_date to NULL if it's empty
    }

    # Retrieve subject from form data
    my $subject = $c->request->body_parameters->{abstract};

    # Check if subject is empty or undefined
    if (!defined $subject || $subject eq '') {
        # Set an error message
        $c->stash(error_msg => 'abstract cannot be empty');

        # Fetch project data from the Project Controller
        my $project_controller = $c->controller('Project');
        my $projects = $project_controller->fetch_projects_with_subprojects($c);

        # Fetch available sites from the Site Controller
        my $site_controller = $c->controller('Site');
        my $sites = $site_controller->fetch_available_sites($c);

        # Get the parent_id from the form (used by project_list.tt)
        my $parent_id = $c->request->body_parameters->{parent_id};

        # Create form_data for project_list.tt and site_list.tt
        my $form_data = {
            parent_id => $parent_id,
            sitename => $c->request->body_parameters->{sitename}
        };

        # Stash the form data
        $c->stash(
            todo_record_id => $c->request->body_parameters->{todo_record_id},
            owner          => $c->request->body_parameters->{owner} || 'none',
            sitename       => $c->session->{SiteName},
            start_date     => $start_date,
            due_date       => $c->request->body_parameters->{due_date},
            abstract       => $subject,
            details        => $c->request->body_parameters->{details},
            comments       => $c->request->body_parameters->{comments},
            projects       => $projects,
            sites          => $sites,
            form_data      => $form_data, # Add form_data for project_list.tt and site_list.tt
            build_priority => $self->priority,
            build_status   => $self->status,
            priority       => $c->request->body_parameters->{priority},
            status         => $c->request->body_parameters->{status},
        );

        # Render the form again
        $c->stash->{template} = 'log/log_form.tt';
        return;
    }

    # Retrieve start_time and end_time from form data
    my $start_time = $c->request->body_parameters->{start_time};
    my $end_time = $c->request->body_parameters->{end_time};

    # Set default values if they're empty strings or undefined
    $start_time = '00:00:00' if !defined $start_time || $start_time eq '';
    $end_time = '00:00:00' if !defined $end_time || $end_time eq '';

    # Calculate time difference
    my ($start_hour, $start_min, $start_sec) = split(':', $start_time);
    my ($end_hour, $end_min, $end_sec) = split(':', $end_time);

    # Ensure we have valid numeric values
    $start_hour = int($start_hour // 0);
    $start_min = int($start_min // 0);
    $end_hour = int($end_hour // 0);
    $end_min = int($end_min // 0);

    my $time_diff_in_minutes = ($end_hour - $start_hour) * 60 + ($end_min - $start_min);

    # Convert time difference in minutes to 'HH:MM:SS' format
    my $hours = int($time_diff_in_minutes / 60);
    my $minutes = $time_diff_in_minutes % 60;
    my $seconds = 0; # Assuming there are no seconds in the time difference
    my $time_diff = sprintf("%02d:%02d:%02d", $hours, $minutes, $seconds);

    my $current_date = DateTime->now->ymd;

    # Get the project_id from the form
    my $project_id = $c->request->body_parameters->{project_id} || '0'; # Default to '0' if not provided

    # Get the site name from the form
    my $sitename;
    my $site_id = $c->request->body_parameters->{sitename};
    if ($site_id) {
        # If a site ID is provided, fetch the site name
        eval {
            # Explicitly select only the columns we need
            my $site = $c->model('DBEncy')->resultset('Site')->find(
                { id => $site_id },
                { columns => ['id', 'name'] }
            );
            $sitename = $site ? $site->name : $c->session->{SiteName};
        };

        # If there's an error, log and use session site name
        if ($@) {
            $self->logging->log_with_details ($c, 'error', __FILE__, __LINE__, 'create_log', "Error fetching site: $@");
            $c->log->error("Error fetching site: $@");
            $sitename = $c->session->{SiteName};
        }
    } else {
        # If no site ID is provided, use the session site name
        $sitename = $c->session->{SiteName};
    }

    # Convert roles array to string if it's an array reference
    my $group_of_poster = 'default';
    if (defined $c->session->{roles}) {
        if (ref $c->session->{roles} eq 'ARRAY') {
            $group_of_poster = join(',', @{$c->session->{roles}});
        } else {
            $group_of_poster = $c->session->{roles};
        }
    }

    # Log the group_of_poster value for debugging
    $self->logging->log_with_details(
        $c, 'debug', __FILE__, __LINE__, 'create_log',
        "Setting group_of_poster to: $group_of_poster"
    );

    # Log the values for debugging
    $self->logging->log_with_details(
        $c, 'debug', __FILE__, __LINE__, 'create_log',
        "Creating log entry with start_time: '$start_time', end_time: '$end_time'"
    );

    my $logEntry = $rs->create({
        todo_record_id  => $c->request->body_parameters->{todo_record_id},
        owner           => $owner,
        sitename        => $sitename,
        start_date      => $start_date || $current_date,
        project_code    => $project_id, # Use project_id from project_list.tt
        due_date        => $c->request->body_parameters->{due_date},
        abstract        => $subject,
        details         => $c->request->body_parameters->{details},
        start_time      => $start_time, # Now has a default value if empty
        end_time        => $end_time,   # Now has a default value if empty
        time            => $time_diff,
        group_of_poster => $group_of_poster, # Use the converted string value
        status          => $c->request->body_parameters->{status},
        priority        => $c->request->body_parameters->{priority},
        last_mod_by     => $c->session->{username},
        last_mod_date   => DateTime->now->ymd,
        comments        => $c->request->body_parameters->{comments}
    });

    # Log the success event
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_log', "Log entry created successfully: ID " . $logEntry->id);

    # Redirect to the referring page and retain necessary parameters
    my $referer = $c->request->referer || '/';
    my $redirect_url = $referer;
    $redirect_url .= "?record_id=" . $logEntry->id if $logEntry->id;
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_log', "Redirecting to: $redirect_url");
    $c->flash->{success_msg} = 'Log entry created successfully';

    # Redirect back to the todo details page
    $c->response->redirect($c->uri_for('/todo/details', { record_id => $logEntry->todo_record_id }));
}

__PACKAGE__->meta->make_immutable;

1;
