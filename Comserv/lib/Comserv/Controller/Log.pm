package Comserv::Controller::Log;
use Moose;
use namespace::autoclean;
use DateTime;
use DateTime::TimeZone;
use DateTime::Format::Strptime;
use Data::Dumper;
use Comserv::Util::Logging;
#use Comserv::Util::Logging; # Import the logging utility
BEGIN { extends 'Catalyst::Controller'; }

has 'record_id' => (is => 'rw', isa => 'Str');
has 'priority' => (is => 'rw', isa => 'HashRef');
has 'status' => (is => 'rw', isa => 'HashRef');
has 'logging' => (is => 'ro', isa => 'Comserv::Util::Logging', lazy => 1, builder => '_build_logging');
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
        3 => 'DONE',
    });
}

sub index :Path('/log') :Args(0) {
    my ( $self, $c ) = @_;

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
    #$self->logging->log_with_details($c, __FILE__, __LINE__, 'index', "Fetched logs: " . Dumper([$rs->all]));

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
            end_time       => $current_time,  # Set end_time to current local time
            template       => 'log/details.tt'
        );
    } else {
        $c->response->body('Log entry not found.');
    }
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
    } else {
        # If not 'DONE', use the provided end_time_str and do not calculate time
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

    # Redirect to the log details page
    $c->response->redirect($c->uri_for("/log", { record_id => $record_id }));
}

# This method will only display the form
sub log_form :Path('/log/log_form'):Args() {
    my ( $self, $c) = @_;
    my $schema = $c->model('DBEncy');

    my $record_id = $c->request->body_parameters->{record_id};

    my $log = Comserv::Model::Log->new(record_id => $record_id);
    my $todo = Comserv::Model::Todo->new();
    my $todo_record = $todo->fetch_todo_record($c, $record_id);

    # Get the current time
    my $current_time = DateTime->now->strftime('%H:%M:%S');

    # Add the priority, status, and record_id to the stash
    $c->stash(
        build_priority => $self->priority,
        build_status   => $self->status,
        priority => $todo_record->priority,
        status   => $todo_record->status,
        project_code   => $todo_record->project_id,
        todo_record => $todo_record->record_id,
        start_date  => $todo_record->start_date,
        site_name   => $todo_record->sitename,
        due_date    => $todo_record->due_date,
        abstract    => $todo_record->subject,
        details     => $todo_record->description,
        comments    => $todo_record->comments,
        end_time    => $current_time,  # Set end_time to current time
    );

    # Check if record_id is provided
    if (defined $log->record_id) {
        $c->stash(record_id => $log->record_id);
        $c->stash(todo_record_id => $log->record_id);  # Add this line
    }

    # Render the form
    $c->stash->{template} = 'log/log_form.tt';
}


sub create_log :Path('/log/create_log') :Args() {
    my ($self, $c) = @_;

    # Create new log entry
    my $schema = $c->model('DBEncy');
    my $rs = $schema->resultset('Log');

    # Retrieve start_time and end_time from form data
    my $start_time = $c->request->body_parameters->{start_time};
    my $end_time = $c->request->body_parameters->{end_time} || '00:00:00';  # Set a default end time if not provided

    # Calculate the time difference
    my $time_diff;
    if ($start_time && $end_time) {
        my ($start_hour, $start_min) = split(':', $start_time);
        my ($end_hour, $end_min) = split(':', $end_time);

        # Adjust for midnight crossover
        if ($end_hour < $start_hour || ($end_hour == $start_hour && $end_min < $start_min)) {
            $end_hour += 24;
        }

        my $time_diff_in_minutes = ($end_hour - $start_hour) * 60 + ($end_min - $start_min);
        $time_diff = sprintf("%02d:%02d", int($time_diff_in_minutes / 60), $time_diff_in_minutes % 60);
    } else {
        $time_diff = '00:00';  # Default time if calculation is not possible
    }

    my $logEntry = $rs->create({
        todo_record_id => $c->request->body_parameters->{todo_record_id},
        owner => $c->request->body_parameters->{owner} || 'none',
        sitename => $c->session->{SiteName},
        start_date => $c->request->body_parameters->{start_date} || DateTime->now->ymd,
        project_code => $c->request->body_parameters->{project_code},
        due_date => $c->request->body_parameters->{due_date},
        abstract => $c->request->body_parameters->{abstract},
        details => $c->request->body_parameters->{details},
        start_time => $start_time,
        end_time => $end_time,  # Ensure end_time is not null
        time => $time_diff,     # Ensure time is not null
        group_of_poster => $c->session->{roles},
        status => 2,            # Set status to 'IN PROGRESS'
        priority => $c->request->body_parameters->{priority},
        last_mod_by => $c->session->{username},
        last_mod_date => DateTime->now->ymd,
        comments => $c->request->body_parameters->{comments}
    });

    if ($logEntry) {
        $self->logging->log_with_details($c, __FILE__, __LINE__, 'create_log', "Created new log entry: " . Dumper($logEntry));
        $c->response->redirect($c->uri_for('/'));
    } else {
        $c->response->body('Error creating log entry.');
    }
}

__PACKAGE__->meta->make_immutable;

1;
