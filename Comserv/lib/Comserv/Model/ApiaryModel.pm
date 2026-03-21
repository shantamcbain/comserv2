package Comserv::Model::ApiaryModel;
use Moose;
use namespace::autoclean;

extends 'Catalyst::Model';

=head1 NAME

Comserv::Model::ApiaryModel - Model for Apiary operations

=head1 DESCRIPTION

This model provides methods for managing bee operations, including queens, frames, yards, and hives.

=head1 METHODS

=head2 get_frames_for_queen

Retrieves all frames associated with a specific queen.

=cut

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

=head2 get_yards_for_site

Retrieves all bee yards associated with a specific site.

=cut

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

=head2 get_hives_for_yard

Retrieves all hives in a specific yard.

=cut

sub get_hives_for_yard {
    my ($self, $yard_id) = @_;

    my @hives;
    eval {
        # Get a DBIx::Class::Schema object
        my $schema = $self->schema;

        # Get a DBIx::Class::ResultSet object for the 'Hive' table
        my $rs = $schema->resultset('Hive');

        # Fetch all hives for the given yard
        @hives = $rs->search({ yard_id => $yard_id });
    };
    if ($@) {
        # An error occurred, handle it here
        warn "An error occurred while fetching hives for yard: $@";
        return;
    }

    return \@hives;
}

=head2 get_queens_for_hive

Retrieves all queens associated with a specific hive.

=cut

sub get_queens_for_hive {
    my ($self, $hive_id) = @_;

    my @queens;
    eval {
        # Get a DBIx::Class::Schema object
        my $schema = $self->schema;

        # Get a DBIx::Class::ResultSet object for the 'Queen' table
        my $rs = $schema->resultset('Queen');

        # Fetch all queens for the given hive
        @queens = $rs->search({ hive_id => $hive_id });
    };
    if ($@) {
        # An error occurred, handle it here
        warn "An error occurred while fetching queens for hive: $@";
        return;
    }

    return \@queens;
}

__PACKAGE__->meta->make_immutable;

1;