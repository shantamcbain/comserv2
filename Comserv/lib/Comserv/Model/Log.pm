package Comserv::Model::Log;
use Moose;

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
    my ($self,  $c, $status) = @_;
    my $schema = $c->model('DBEncy');

    # Define search criteria
    my $search_criteria = { SiteName => $c->session->{SiteName} };

    # Add status to search criteria if not 'all'
    if ($status ne 'all') {
        $search_criteria->{status} = $status;
    }

    # Retrieve all log records
    my $logs = $schema->resultset('Log')->search($search_criteria, { order_by => 'start_date' });

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

1;