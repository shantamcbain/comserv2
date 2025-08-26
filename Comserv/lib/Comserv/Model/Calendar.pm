package Comserv::Model::Calendar;
use Moose;
use namespace::autoclean;

extends 'Comserv::Model::DBEncy';

sub get_events {
    my ($self, $search_criteria) = @_;

    my @events;
    eval {
        # Get a DBIx::Class::ResultSet object for the 'Event' table
        my $rs = $self->resultset('Event');

        # Fetch the events that match the search criteria
        @events = $rs->search($search_criteria);
    };
    if ($@) {
        # An error occurred, handle it here
        warn "An error occurred while fetching events: $@";
        return;
    }

    return \@events;
}

# Add more methods to interact with other Calendar related tables

__PACKAGE__->meta->make_immutable;

1;