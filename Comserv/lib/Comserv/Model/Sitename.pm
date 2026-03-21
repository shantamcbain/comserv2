package Comserv::Model::Sitename;

use Moose;
use namespace::autoclean;
use Try::Tiny;
use Comserv::Util::Logging;

extends 'Catalyst::Model';

# Attributes
has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has 'schema' => (
    is => 'ro',
    required => 1,
);

# Component initialization
sub COMPONENT {
    my ($class, $app, $args) = @_;
    my $schema = $app->model('DBEncy')->schema;
    return $class->new({ %$args, schema => $schema });
}

# Sitename operations
sub get_all_sitenames {
    my ($self, $c) = @_;

    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'get_all_sitenames',
        "Getting all site names"
    );

    my @sitenames;
    my $result;

    try {
        # Try to get the sitename resultset
        my $sitename_rs = $self->schema->resultset('Sitename');

        $self->logging->log_with_details(
            $c, 'info', __FILE__, __LINE__, 'get_all_sitenames',
            "Successfully got resultset"
        );

        # Get all sitenames
        @sitenames = $sitename_rs->all;

        $self->logging->log_with_details(
            $c, 'info', __FILE__, __LINE__, 'get_all_sitenames',
            "Retrieved " . scalar(@sitenames) . " site names"
        );

        # Log each sitename for debugging
        foreach my $sitename (@sitenames) {
            $self->logging->log_with_details(
                $c, 'info', __FILE__, __LINE__, 'get_all_sitenames',
                "Sitename: ID=" . $sitename->id . ", Name=" . $sitename->name . 
                ", Domain=" . ($sitename->domain || 'N/A')
            );
        }

        # Store the array reference of sitenames
        $result = \@sitenames;

        # Log the reference type for debugging
        $self->logging->log_with_details(
            $c, 'info', __FILE__, __LINE__, 'get_all_sitenames',
            "Returning reference type: " . ref($result) . " with " . scalar(@$result) . " elements"
        );
    } catch {
        my $error = $_;
        $self->logging->log_with_details(
            $c, 'error', __FILE__, __LINE__, 'get_all_sitenames',
            "Error fetching site names: $error"
        );
        $result = [];
    };

    return $result || [];
}

sub get_sitename_details {
    my ($self, $c, $sitename_id) = @_;

    return unless defined $sitename_id;

    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'get_sitename_details',
        "Getting site name details for ID: $sitename_id"
    );

    try {
        my $sitename = $self->schema->resultset('Sitename')->find($sitename_id);
        return $sitename if $sitename;

        $self->logging->log_with_details(
            $c, 'warn', __FILE__, __LINE__, 'get_sitename_details',
            "Site name not found for ID: $sitename_id"
        );
        return;
    } catch {
        my $error = $_;
        $self->logging->log_with_details(
            $c, 'error', __FILE__, __LINE__, 'get_sitename_details',
            "Error fetching site name details: $error"
        );
        return;
    };
}

sub get_sitename_by_name {
    my ($self, $c, $name) = @_;

    return unless defined $name;

    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'get_sitename_by_name',
        "Getting site name details for name: $name"
    );

    my $result;

    try {
        my $sitename = $self->schema->resultset('Sitename')->find({ name => $name });

        if ($sitename) {
            $self->logging->log_with_details(
                $c, 'info', __FILE__, __LINE__, 'get_sitename_by_name',
                "Found site name: ID=" . $sitename->id . ", Name=" . $sitename->name
            );
            $result = $sitename;
        } else {
            $self->logging->log_with_details(
                $c, 'warn', __FILE__, __LINE__, 'get_sitename_by_name',
                "Site name not found for name: $name"
            );
        }
    } catch {
        my $error = $_;
        $self->logging->log_with_details(
            $c, 'error', __FILE__, __LINE__, 'get_sitename_by_name',
            "Error fetching site name details: $error"
        );
    };

    return $result;
}

# Make the class immutable
__PACKAGE__->meta->make_immutable;

1;