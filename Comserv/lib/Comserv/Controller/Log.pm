package Comserv::Controller::Log;
use Moose;
use namespace::autoclean;
use DateTime;

BEGIN { extends 'Catalyst::Controller'; }

sub index :Path :Args(0) {
    my ( $self, $c ) = @_;

    $c->response->body('Matched Comserv::Controller::Log in Log.');
}

sub log_form :Path('/log/log_form'):Args() {
    my ( $self, $c) = @_;
   my $record_id = $c->request->params->{id};


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

    # Check if the form has been submitted
    if ($c->request->method eq 'POST') {
        # Create new log entry
        my $logEntry = $c->model('DB::Log')->create({
            todo_record_id => $c->request->parameters->{todo_record_id},
            owner => $c->request->parameters->{owner},
            sitename => $c->session->{sitename},
            start_date => $c->request->parameters->{start_date},
            project_code => $c->request->parameters->{project_code},
            due_date => $c->request->parameters->{due_date},
            abstract => $c->request->parameters->{abstract},
            details => $c->request->parameters->{details},
            start_time => $c->request->parameters->{start_time},
            end_time => $c->request->parameters->{end_time},
            time => $c->request->parameters->{time},
            group_of_poster => $c->session->{roles},
            status => $c->request->parameters->{status},
            priority => $c->request->parameters->{priority},
            last_mod_by => $c->session->{username},
            last_mod_date => DateTime->now->ymd,
            comments => $c->request->parameters->{comments}
        });

        if ($logEntry) {
            $c->response->body('Log entry created successfully.');
        } else {
            $c->response->body('Error creating log entry.');
        }
    } else {
        # Render the form
        $c->stash->{template} = 'log/log_form.tt';
    }
}
__PACKAGE__->meta->make_immutable;

1;
