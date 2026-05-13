package Comserv::Model::Log;
use Moose;
use namespace::autoclean;
use Data::Dumper; # Import Data::Dumper for debugging
use Scalar::Util 'blessed';
use Comserv::Util::Logging;
has 'record_id' => (is => 'rw', isa => 'Str');
has 'priority' => (is => 'rw', isa => 'HashRef');
has 'status' => (is => 'rw', isa => 'HashRef');
BEGIN { extends 'Catalyst::Model'; }
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
    my ($self, $c, $status, $site_filter, $allowed_sites) = @_;
    my $schema = $c->model('DBEncy');

    my $sitename = $c->session->{SiteName} || '';
    my $roles    = $c->session->{roles}    || [];
    my $has_admin = ref($roles) eq 'ARRAY'
        ? (grep { $_ eq 'admin' } @$roles) > 0
        : ($roles && $roles =~ /\badmin\b/i);
    my $is_csc_admin = ($sitename eq 'CSC' && $has_admin)
        || (($c->session->{username} || '') eq 'Shanta');

    my $search_criteria = {};
    if ($site_filter) {
        $search_criteria->{sitename} = $site_filter;
    } elsif ($is_csc_admin) {
        if ($allowed_sites && @$allowed_sites) {
            $search_criteria->{sitename} = { -in => $allowed_sites };
        }
    } else {
        if ($allowed_sites && @$allowed_sites > 1) {
            $search_criteria->{sitename} = { -in => $allowed_sites };
        } else {
            $search_criteria->{sitename} = $sitename;
        }
    }

    if ($status eq 'open') {
        $search_criteria->{status} = { '!=' => 3 };
    } elsif ($status eq 'all') {
    } else {
        $search_criteria->{status} = $status;
    }

    $c->log->debug("Search criteria: " . Dumper($search_criteria));

    my $logs = $schema->resultset('Log')->search($search_criteria, { order_by => { -desc => 'start_date' } });

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
        status => 3, # Assuming 3 is the status for completed logs
    });

    # Calculate total time from log entries
    my $total_log_time = 0;
    while (my $log = $log_rs->next) {
        my $start_time = $log->start_time;
        my $end_time = $log->end_time || '00:00:00'; # Default to '00:00:00' if end_time is not set

        my ($start_hour, $start_min) = split(':', $start_time);
        my ($end_hour, $end_min) = split(':', $end_time);

        # Adjust for midnight crossover
        if ($end_hour < $start_hour || ($end_hour == $start_hour && $end_min < $start_min)) {
            $end_hour += 24;
        }

        my $time_diff_in_minutes = ($end_hour - $start_hour) * 60 + ($end_min - $start_min);
        $total_log_time += $time_diff_in_minutes * 60; # Convert minutes to seconds
    }

    return $total_log_time;
}

1;
