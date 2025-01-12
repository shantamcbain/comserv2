package Comserv::Model::Log;
use Moose;
use namespace::autoclean;
use Data::Dumper; # Import Data::Dumper for debugging
use Comserv::Util::Logging;
has 'record_id' => (is => 'rw', isa => 'Str');
has 'priority' => (is => 'rw', isa => 'HashRef');
has 'status' => (is => 'rw', isa => 'HashRef');
BEGIN { extends 'Catalyst::Controller'; }
has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);
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
    my $search_criteria = {
        sitename => $c->session->{SiteName}
    };

    # Add status to search criteria
    if ($status eq 'open') {
        $search_criteria->{status} = { '!=' => 3 }; # Exclude DONE logs
    } elsif ($status eq 'all') {
        # No additional status filter needed for 'all'
    } else {
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
    my ($self, $c, $log_id, $new_values) = @_;

    # Fetch the log object using the log_id
    # Ensure we are using the correct model and method to find the log record
    my $log_record = $c->model('DBEncy')->resultset('Log')->find($log_id);

    # Log the input parameters for debugging
    $self->logging->log_with_details($c, __FILE__, __LINE__, 'modify', 'Input log record: ' . Dumper($log_record));
    $self->logging->log_with_details($c, __FILE__, __LINE__, 'modify', 'New values: ' . Dumper($new_values));

    # Ensure $log_record is a blessed object
    unless (blessed($log_record) && $log_record->can('update')) {
        $self->logging->log_with_details($c, __FILE__, __LINE__, 'modify', 'Error: $log_record is not a valid object');
        die "Error: \$log_record is not a valid object";
    }

    # Iterate over each key-value pair in the new values hash
    while (my ($key, $value) = each %$new_values) {
        # Update the corresponding field in the log record
        $log_record->$key($value);
    }

    # Log the updated log record for debugging
    $self->logging->log_with_details($c, __FILE__, __LINE__, 'modify', 'Updated log record: ' . Dumper($log_record));

    # Save the updated log record
    $log_record->update;

    return $log_record;
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
