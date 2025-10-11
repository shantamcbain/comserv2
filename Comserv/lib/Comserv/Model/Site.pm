
package Comserv::Model::Site;

use Moose;
use namespace::autoclean;
use Try::Tiny;
use Comserv::Util::Logging;
use JSON;
use File::Slurp;

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

# Site operations
sub get_all_sites {
    my ($self, $c) = @_;

    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'get_all_sites',
        "Getting all sites"
    );

    my @sites;
    my $result;

    try {
        # Try to get the site resultset
        my $site_rs = $self->schema->resultset('Site');

        $self->logging->log_with_details(
            $c, 'info', __FILE__, __LINE__, 'get_all_sites',
            "Successfully got resultset"
        );

        # Get all sites
        @sites = $site_rs->all;

        $self->logging->log_with_details(
            $c, 'info', __FILE__, __LINE__, 'get_all_sites',
            "Retrieved " . scalar(@sites) . " sites"
        );

        # Log each site for debugging
        foreach my $site (@sites) {
            $self->logging->log_with_details(
                $c, 'info', __FILE__, __LINE__, 'get_all_sites',
                "Site: ID=" . $site->id . ", Name=" . $site->name
            );
        }

        # Store the array reference of sites
        $result = \@sites;

        # Log the reference type for debugging
        $self->logging->log_with_details(
            $c, 'info', __FILE__, __LINE__, 'get_all_sites',
            "Returning reference type: " . ref($result) . " with " . scalar(@$result) . " elements"
        );
    } catch {
        my $error = $_;
        $self->logging->log_with_details(
            $c, 'error', __FILE__, __LINE__, 'get_all_sites',
            "Error fetching sites: $error"
        );
        $result = [];
    };

    return $result || [];
}

sub get_site_details {
    my ($self, $c, $site_id) = @_;

    return unless defined $site_id;

    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'get_site_details',
        "Getting site details for ID: $site_id"
    );

    try {
        my $site = $self->schema->resultset('Site')->find($site_id);
        return $site if $site;

        $self->logging->log_with_details(
            $c, 'warn', __FILE__, __LINE__, 'get_site_details',
            "Site not found for ID: $site_id"
        );
        return;
    } catch {
        my $error = $_;
        $self->logging->log_with_details(
            $c, 'error', __FILE__, __LINE__, 'get_site_details',
            "Error fetching site details: $error"
        );
        return;
    };
}

sub get_site_details_by_name {
    my ($self, $c, $site_name) = @_;

    return unless defined $site_name;

    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'get_site_details_by_name',
        "Getting site details for name: $site_name"
    );

    my $result;

    try {
        my $site = $self->schema->resultset('Site')->find({ name => $site_name });

        if ($site) {
            $self->logging->log_with_details(
                $c, 'info', __FILE__, __LINE__, 'get_site_details_by_name',
                "Found site: ID=" . $site->id . ", Name=" . $site->name
            );
            $result = $site;
        } else {
            $self->logging->log_with_details(
                $c, 'warn', __FILE__, __LINE__, 'get_site_details_by_name',
                "Site not found for name: $site_name"
            );
        }
    } catch {
        my $error = $_;
        $self->logging->log_with_details(
            $c, 'error', __FILE__, __LINE__, 'get_site_details_by_name',
            "Error fetching site details: $error"
        );
    };

    return $result;
}

sub get_site_domain {
    my ($self, $c, $domain) = @_;

    return unless defined $domain;

    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'get_site_domain',
        "Looking up domain: $domain"
    );

    try {
        # Try both SiteDomain and sitedomain table names (case sensitivity issue)
        my $site_domain;

        # First try with the original table name
        eval {
            $site_domain = $self->schema->resultset('SiteDomain')->find({ domain => $domain });
        };

        # If that fails, try with lowercase table name
        if ($@ || !$site_domain) {
            eval {
                $site_domain = $self->schema->resultset('sitedomain')->find({ domain => $domain });
            };
        }

        # If still not found, try case-insensitive match on domain name
        if (!$site_domain) {
            # Try with search instead of find for case-insensitive comparison
            my $rs = $self->schema->resultset('SiteDomain')->search(
                \[ 'LOWER(domain) = ?', lc($domain) ]
            );
            $site_domain = $rs->first if $rs && $rs->count > 0;

            # If still not found, try with lowercase table name
            if (!$site_domain) {
                eval {
                    my $rs = $self->schema->resultset('sitedomain')->search(
                        \[ 'LOWER(domain) = ?', lc($domain) ]
                    );
                    $site_domain = $rs->first if $rs && $rs->count > 0;
                };
            }
        }

        # If we found a domain, return it
        return $site_domain if $site_domain;

        # If we get here, the domain wasn't found
        $self->logging->log_with_details(
            $c, 'warn', __FILE__, __LINE__, 'get_site_domain',
            "Domain not found: $domain"
        );
        return;
    } catch {
        my $error = $_;
        $self->logging->log_with_details(
            $c, 'error', __FILE__, __LINE__, 'get_site_domain',
            "Error looking up domain: $error"
        );
        return;
    };
}

sub add_site {
    my ($self, $c, $site_details) = @_;

    return unless ref $site_details eq 'HASH';

    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'add_site',
        "Adding new site"
    );

    try {
        my $site = $self->schema->resultset('Site')->create($site_details);
        return $site if $site;

        $self->logging->log_with_details(
            $c, 'error', __FILE__, __LINE__, 'add_site',
            "Failed to create site"
        );
        return;
    } catch {
        my $error = $_;
        $self->logging->log_with_details(
            $c, 'error', __FILE__, __LINE__, 'add_site',
            "Error creating site: $error"
        );
        return;
    };
}

sub update_site {
    my ($self, $c, $site_id, $site_details) = @_;

    return unless defined $site_id && ref $site_details eq 'HASH';

    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'update_site',
        "Updating site ID: $site_id"
    );

    try {
        my $site = $self->schema->resultset('Site')->find($site_id);
        return unless $site;

        $site->update($site_details);
        return $site;
    } catch {
        my $error = $_;
        $self->logging->log_with_details(
            $c, 'error', __FILE__, __LINE__, 'update_site',
            "Error updating site: $error"
        );
        return;
    };
}

sub delete_site {
    my ($self, $c, $site_id) = @_;

    return unless defined $site_id;

    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'delete_site',
        "Deleting site ID: $site_id"
    );

    try {
        my $site = $self->schema->resultset('Site')->find($site_id);
        return unless $site;

        $site->delete;
        return 1;
    } catch {
        my $error = $_;
        $self->logging->log_with_details(
            $c, 'error', __FILE__, __LINE__, 'delete_site',
            "Error deleting site: $error"
        );
        return;
    };
}

# Make the class immutable
__PACKAGE__->meta->make_immutable;

1;