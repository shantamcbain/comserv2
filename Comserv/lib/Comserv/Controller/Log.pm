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

# This method will handle the form submission
sub create_log :Path('/log/create_log'):Args() {
    my ( $self, $c) = @_;

    # Create new log entry
    my $schema = $c->model('DBEncy');
    my $rs = $schema->resultset('Log');
        # Retrieve start_date from form data
    my $start_date = $c->request->parameters->{start_date};
    # Retrieve time from form data
    my $time = $c->request->parameters->{time};

    # Check if time is empty
    if ($time eq '') {
        $time = 1;  # Set time to NULL if it's empty
    }

    # Check if start_date is empty
    if ($start_date eq '') {
        $start_date = undef;  # Set start_date to NULL if it's empty
    }
 my $current_date = DateTime->now->ymd;
    my $logEntry = $rs->create({
        todo_record_id => $c->request->parameters->{todo_record_id},
        owner => $c->request->parameters->{owner},
        sitename => $c->session->{SiteName},
        start_date => $start_date||$current_date,
        project_code => $c->request->parameters->{project_code},
        due_date => $c->request->parameters->{due_date},
        abstract => $c->request->parameters->{abstract},
        details => $c->request->parameters->{details},
        start_time => $c->request->parameters->{start_time},
        end_time => $c->request->parameters->{end_time},
        time => $time,
        group_of_poster => $c->session->{roles},
        status => $c->request->parameters->{status},
        priority => $c->request->parameters->{priority},
        last_mod_by => $c->session->{username},
        last_mod_date => DateTime->now->ymd,
        comments => $c->request->parameters->{comments}
    });

    if ($logEntry) {
        $c->response->redirect($c->uri_for('/'));
    } else {
        $c->response->body('Error creating log entry.');
    }
}

__PACKAGE__->meta->make_immutable;

1;
__PACKAGE__->meta->make_immutable;

1;
