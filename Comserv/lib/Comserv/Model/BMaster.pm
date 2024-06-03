package Comserv::Model::BMaster;
use Moose;
use namespace::autoclean;

# This package extends the Catalyst::Model class
extends 'Catalyst::Model';

# This subroutine fetches frames for a given queen
# @param $queen_tag_number - The tag number of the queen for which frames are to be fetched
# @return \@frames - An array reference containing the frames for the given queen
sub get_frames_for_queen {
    my ($self, $queen_tag_number) = @_;

    my @frames;
    eval {
        # Get a DBIx::Class::Schema object
        my $schema = $self->schema;

        # Get a DBIx::Class::ResultSet object for the 'Frame' table
        my $rs = $schema->resultset('Frame');

        # Fetch the frames for the given queen
        @frames = $rs->search({ queen_id => $queen_tag_number });
    };
    if ($@) {
        # An error occurred, handle it here
        warn "An error occurred while fetching frames for queen: $@";
        return;
    }

    return \@frames;
}

# This subroutine fetches yards for a given site
# @param $site_name - The name of the site for which yards are to be fetched
# @return \@yards - An array reference containing the yards for the given site
sub get_yards_for_site {
    my ($self, $site_name) = @_;

    my @yards;
    eval {
        # Get a DBIx::Class::Schema object
        my $schema = $self->schema;

        # Get a DBIx::Class::ResultSet object for the 'ApisYardsTb' table
        my $rs = $schema->resultset('ApisYardsTb');

        # Fetch all yards for the given site
        @yards = $rs->search({ sitename => $site_name });
    };
    if ($@) {
        # An error occurred, handle it here
        warn "An error occurred while fetching yards: $@";
        return;
    }

    return \@yards;
}

# This subroutine counts the number of queens
# @return $count - The number of queens
sub count_queens {
    my ($self) = @_;

    my $count;
    eval {
        # Get a DBIx::Class::Schema object
        my $schema = $self->schema;

        # Get a DBIx::Class::ResultSet object for the 'Queen' table
        my $rs = $schema->resultset('Queen');

        # Count the number of queens
        $count = $rs->count();
    };
    if ($@) {
        # An error occurred, handle it here
        warn "An error occurred while counting queens: $@";
        return;
    }

    return $count;
}

# This subroutine adds a yard
# @param $c - The Catalyst context object
# @param $yard_name - The name of the yard to be added
# @return 1 - Returns 1 if the yard is successfully added
sub add_yard {
    my ($self, $c, $yard_name) = @_;

    # Validate the yard_name parameter
    unless (defined $yard_name && $yard_name =~ /^[a-zA-Z0-9_]+$/) {
        warn "Invalid yard name: $yard_name";
        return;
    }

    eval {
        # Get a DBIx::Class::Schema object
        my $schema = $self->schema;

        # Check if the 'Yard' table exists
        my $rs = $schema->resultset('Yard');

        # If the 'Yard' table does not exist, create it
        if (!$rs) {
$c->model('DBEncy')->create_table_from_result('Yard', $schema);        }

        # Add the new yard to the 'Yard' table
        $rs->create({ yard_name => $yard_name });
    };
    if ($@) {
        # An error occurred, handle it here
        warn "An error occurred while adding a yard: $@";
        return;
    }

    return 1;
}

# This subroutine counts the number of frames
# @return $count - The number of frames
sub count_frames {
    my ($self) = @_;

    my $count;
    eval {
        # Get a DBIx::Class::Schema object
        my $schema = $self->schema;

        # Get a DBIx::Class::ResultSet object for the 'Frame' table
        my $rs = $schema->resultset('Frame');

        # Count the number of frames
        $count = $rs->count();
    };
    if ($@) {
        # An error occurred, handle it here
        warn "An error occurred while counting frames: $@";
        return;
    }

    return $count;
}

# This line makes the package immutable
__PACKAGE__->meta->make_immutable;

1;