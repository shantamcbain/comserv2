package Comserv::Model::Log;
use Moose;
use Data::Dumper; # Import Data::Dumper for debugging

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

sub get_logs {
    my ($self, $c, $status) = @_;
    my $schema = $c->model('DBEncy');

    # Define search criteria with sitename
    my $search_criteria = { sitename => $c->session->{SiteName} };

    # Add status to search criteria
    if ($status eq 'open') {
        $search_criteria->{status} = { '!=' => 3 }; # Exclude DONE logs
    } elsif ($status eq 'all') {
        # No additional status filter needed for 'all'
    } else {
        # Assume $status is a specific numeric value
        $search_criteria->{status} = $status;
    }

    # Log the search criteria for debugging
    $c->log->debug("Search criteria: " . Dumper($search_criteria));

    # Retrieve all log records
    my $logs = $schema->resultset('Log')->search($search_criteria, { order_by => 'start_date' });

    # Log the number of logs found
    $c->log->debug("Number of logs found: " . $logs->count);

    return $logs;
}

sub modify {
    my ($self, $log, $new_values) = @_;

    # Iterate over each key-value pair in the new values hash
    while (my ($key, $value) = each %$new_values) {
        # Update the corresponding field in the log record
        $log->$key($value);
    }

    # Save the updated log record
    $log->update;

    return $log;
}

sub calculate_accumulative_time {
    my ($self, $c, $todo_record_id) = @_;
    my $schema = $c->model('DBEncy');

    # Get the related log entries for this todo
    my $log_rs = $schema->resultset('Log')->search({
        todo_record_id => $todo_record_id,
        status => 'DONE', # Assuming 'DONE' is the status for completed logs
    });

    # Calculate total time from log entries
    my $total_log_time = 0;
    while (my $log = $log_rs->next) {
        my $start_time = $log->start_time;
        my $end_time = $log->end_time || '00:00:00'; # Default to '00:00:00' if end_time is not set

        my ($start_hour, $start_min) = split(':', $start_time);
        my ($end_hour, $end_min) = split(':', $end_time);

        my $time_diff_in_minutes = ($end_hour - $start_hour) * 60 + ($end_min - $start_min);
        $total_log_time += $time_diff_in_minutes * 60; # Convert minutes to seconds
    }

    return $total_log_time;
}

1;
