
package Comserv::Model::BMasterModel;
use Moose;
use namespace::autoclean;


extends 'Catalyst::Model';

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
    } catch {
        ERROR("An error occurred while fetching frames for queen: $_");
        return;
    }

    return \@frames;
}
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

__PACKAGE__->meta->make_immutable;

1;
