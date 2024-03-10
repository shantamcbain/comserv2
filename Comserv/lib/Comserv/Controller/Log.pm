package Comserv::Controller::Log;
use Moose;
use namespace::autoclean;
use DateTime;
use DateTime::Format::Strptime;
BEGIN { extends 'Catalyst::Controller'; }

has 'record_id' => (is => 'rw', isa => 'Str');
has 'priority' => (is => 'rw', isa => 'HashRef');
has 'status' => (is => 'rw', isa => 'HashRef');

sub BUILD {
    my $self = shift;
    $self->priority({ map { $_ => $_ } (1..10) });
    $self->status({
        1 => 'NEW',
        2 => 'IN PROGRESS',
        3 => 'DONE',
    });

}

# Rest of your controller code
sub index :Path('/log') :Args {
    my ( $self, $c, $status ) = @_;

    # Default status to not 3 if not provided
    $status //= { '!=' => 3 };

    # Create a new instance of the Log model
    my $log_model = Comserv::Model::Log->new();

    # Fetch all open logs that match the status
    my $rs = $log_model->get_logs($c, $status);

    # Debug: Print all logs
    while (my $log = $rs->next) {
        $c->log->debug("Record ID: " . $log->record_id);
    }

    # Pass the logs to the template
    $c->stash(logs => [$rs->all]);

    # Set the template
    $c->stash->{template} = 'log/index.tt';
}


sub edit :Path('/log/details'):Args(0) {
    my ( $self, $c, $record_id ) = @_;
    $record_id = $c->request->body_parameters->{record_id};
    # Fetch the log entry
    my $schema = $c->model('DBEncy');
    my $log = $schema->resultset('Log')->find($record_id);

    # Check if the log entry exists
    if (!$log) {
        $c->response->body('Log entry not found.');
        return;
    }
    # Print the status value to the debug log
    warn "Status: " . $log->status;

    # Pass the log entry and the priority, status to the template
    $c->stash(
    build_priority => $self->priority,
    build_status   => $self->status,
    priority => $log->priority,
    status => $log->status,
    log => $log
);

    # Set the template
    $c->stash->{template} = 'log/details.tt';
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

    # Create a DateTime::Format::Strptime object for parsing the time strings
    my $strp = DateTime::Format::Strptime->new(
        pattern   => '%H:%M',
        time_zone => 'local',
    );

    # Convert the start_time and end_time strings to DateTime objects
    my $start_time = $strp->parse_datetime($start_time_str);
    my $end_time = $strp->parse_datetime($end_time_str);

    # Calculate the difference between the end time and the start time
    my $duration = $end_time->subtract_datetime($start_time);

    # Convert the duration to the format 'HH:MM'
    my $time = sprintf("%02d:%02d", $duration->hours, $duration->minutes);

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
        status => $c->request->body_parameters->{status},
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
    );

    # Check if record_id is provided
    if (defined $log->record_id) {
        $c->stash(record_id => $log->record_id);
        $c->stash(todo_record_id => $log->record_id);  # Add this line
    }

    # Render the form
    $c->stash->{template} = 'log/log_form.tt';
}

sub create_log :Path('/log/create_log'):Args() {
    my ( $self, $c) = @_;

    # Create new log entry
    my $schema = $c->model('DBEncy');
    my $rs = $schema->resultset('Log');

    # Retrieve start_date from form data
    my $start_date = $c->request->body_parameters->{start_date};
    # Set owner to 'none' if it's not provided
    my $owner = $c->request->body_parameters->{owner} || 'none';

    # Check if start_date is empty
    if ($start_date eq '') {
        $start_date = undef;  # Set start_date to NULL if it's empty
    }

    # Retrieve subject from form data
    my $subject = $c->request->body_parameters->{abstract};

    # Check if subject is empty or undefined
    if (!defined $subject || $subject eq '') {
        # Set an error message
        $c->stash(error_msg => 'abstract cannot be empty');

        # Stash the form data
        $c->stash(
            todo_record_id => $c->request->body_parameters->{todo_record_id},
            owner => $c->request->body_parameters->{owner}||'none',
            sitename => $c->session->{SiteName},
            start_date => $start_date,
            project_code => $c->request->body_parameters->{project_code},
            due_date => $c->request->body_parameters->{due_date},
            abstract => $subject,
            details => $c->request->body_parameters->{details},
            start_time => $c->request->body_parameters->{start_time},
            end_time => $c->request->body_parameters->{end_time},
            group_of_poster => $c->session->{roles},
            status => $c->request->body_parameters->{status},
            priority => $c->request->body_parameters->{priority},
            comments => $c->request->body_parameters->{comments}
        );

        # Render the form again
        $c->stash->{template} = 'log/log_form.tt';
        return;
    }

    # Retrieve start_time and end_time from form data
    my $start_time = $c->request->body_parameters->{start_time};
    my $end_time = $c->request->body_parameters->{end_time};

 # Calculate time difference
my ($start_hour, $start_min) = split(':', $start_time);
my ($end_hour, $end_min) = split(':', $end_time);
my $time_diff_in_minutes = ($end_hour - $start_hour) * 60 + ($end_min - $start_min);

# Convert time difference in minutes to 'HH:MM:SS' format
my $hours = int($time_diff_in_minutes / 60);
my $minutes = $time_diff_in_minutes % 60;
my $seconds = 0;  # Assuming there are no seconds in the time difference
my $time_diff = sprintf("%02d:%02d:%02d", $hours, $minutes, $seconds);
    my $current_date = DateTime->now->ymd;
    my $logEntry = $rs->create({
        todo_record_id => $c->request->body_parameters->{todo_record_id},
        owner => $owner,
        sitename => $c->session->{SiteName},
        start_date => $start_date||$current_date,
        project_code => $c->request->body_parameters->{project_code},
        due_date => $c->request->body_parameters->{due_date},
        abstract => $subject,
        details => $c->request->body_parameters->{details},
        start_time => $c->request->body_parameters->{start_time},
        end_time => $c->request->body_parameters->{end_time},
        time => $time_diff,
        group_of_poster => $c->session->{roles},
        status => $c->request->body_parameters->{status},
        priority => $c->request->body_parameters->{priority},
        last_mod_by => $c->session->{username},
        last_mod_date => DateTime->now->ymd,
        comments => $c->request->body_parameters->{comments}
    });

    if ($logEntry) {
        $c->response->redirect($c->uri_for('/'));
    } else {
        $c->response->body('Error creating log entry.');
    }
}
__PACKAGE__->meta->make_immutable;

1;
