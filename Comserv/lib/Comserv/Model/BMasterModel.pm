package Comserv::Model::BMasterModel;
use Moose;
use namespace::autoclean;
use Try::Tiny;
use Comserv::Util::Logging;

extends 'Catalyst::Model';

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub get_frames_for_queen {
    my ($self, $c, $queen_tag_number) = @_;
    my @frames;

    # Log the start of the subroutine
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_frames_for_queen', "Fetching frames for queen with tag number: $queen_tag_number");

    try {
        # Get a DBIx::Class::Schema object
        my $schema = $self->schema;
        # Get a DBIx::Class::ResultSet object for the 'Frame' table
        my $rs = $schema->resultset('Frame');
        # Fetch the frames for the given queen
        @frames = $rs->search({ queen_id => $queen_tag_number });
    } catch {
        # Log the error
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_frames_for_queen', "An error occurred while fetching frames: $_");
        return;
    };

    return \@frames;
}

sub get_yards_for_site {
    my ($self, $c, $site_name) = @_;
    my @yards;

    # Log the start of the subroutine
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_yards_for_site', "Fetching yards for site: $site_name");

    eval {
        # Get a DBIx::Class::Schema object
        my $schema = $self->schema;
        # Get a DBIx::Class::ResultSet object for the 'ApisYardsTb' table
        my $rs = $schema->resultset('ApisYardsTb');
        # Fetch all yards for the given site
        @yards = $rs->search({ sitename => $site_name });
    };
    if ($@) {
        # Log the error
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_yards_for_site', "An error occurred while fetching yards: $@");
        return;
    }

    return \@yards;
}

__PACKAGE__->meta->make_immutable;

1;
