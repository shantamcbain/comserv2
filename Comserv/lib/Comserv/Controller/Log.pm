package Comserv::Controller::Log;
use Moose;
use namespace::autoclean;
use DateTime;

BEGIN { extends 'Catalyst::Controller'; }

sub index :Path :Args(0) {
    my ( $self, $c ) = @_;

    $c->response->body('Matched Comserv::Controller::Log in Log.');
}



# This method will only display the form
sub log_form :Path('/log/log_form'):Args() {
    my ( $self, $c) = @_;
    my $record_id = $c->request->body_parameters->{record_id};
    $c->stash(record_id => $record_id);
    my %priority = map { $_ => $_ } (1..10);

    my %status =
    (
      1 => 'NEW',
      2 => 'IN PROGRESS',
      3 => 'DONE',
    );

    # Add the priority, status, and record_id to the stash
    $c->stash(
        priority => \%priority,
        status   => \%status,
        record_id => $record_id,
    );

    # Check if record_id is provided
    if (defined $record_id) {
        $c->stash(record_id => $record_id);
        $c->stash(todo_record_id => $record_id);  # Add this line
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
            owner => $c->request->body_parameters->{owner},
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
        owner => $c->request->body_parameters->{owner},
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
