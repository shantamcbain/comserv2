package Comserv::Model::Site;
use Moose;
use namespace::autoclean;
use Try::Tiny;
use Comserv::Util::Logging;
extends 'Catalyst::Model';

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has 'schema' => (
    is => 'ro',
    required => 1,
);

sub COMPONENT {
    my ($class, $app, $args) = @_;

    my $schema = $app->model('DBEncy')->schema;
    return $class->new({ %$args, schema => $schema });
}

sub get_all_sites {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_all_sites', "Getting all sites");
    $self->schema->storage->ensure_connected;
    my $site_rs = $self->schema->resultset('Site');
    my @sites = $site_rs->all;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_all_sites', "Visited the site page");
   return \@sites;
}

sub get_site_domain {
    my ($self,  $c, $domain) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_site_domain', "Domain: $domain");
    try {
        my $result = $self->schema->resultset('SiteDomain')->find({ domain => $domain });
        return $result;
    } catch {
        if ($_ =~ /Table 'ency\.sitedomain' doesn't exist/) {
            Catalyst::Exception->throw("Schema update required");
        } else {
            die $_;
        }
    };
}

sub add_site {
    my ($self, $c, $site_details) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_site', "Adding new site: " . join(", ", map { "$_: $site_details->{$_}" } keys %$site_details));
    my $site_rs = $self->schema->resultset('Site');
    my $new_site = $site_rs->create($site_details);
    return $new_site;
}

sub update_site {
    my ($self, $c,$site_id, $new_site_details) =  @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_site', "Updating site with ID $site_id: " . join(", ", map { "$_: $new_site_details->{$_}" } keys %$new_site_details));
    my $site_rs = $self->schema->resultset('Site');
    my $site = $site_rs->find($site_id);
    $site->update($new_site_details) if $site;
    return $site;
}

sub delete_site {
    my ($self, $c, $site_id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete_site', "Deleting site with ID $site_id");
    my $site_rs = $self->schema->resultset('Site');
    my $site = $site_rs->find($site_id);
    $site->delete if $site;
    return $site;
}

sub get_site_details_by_name {
    my ($self, $c, $site_name) = @_;
    print " in get_site_details_by_name Site name: $site_name\n";
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_site_details_by_name', "Site name: $site_name");
    my $site_rs = $self->schema->resultset('Site');
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_site_details_by_name', "Visited the site page $site_rs");
    my $site = $site_rs->find({ name => $site_name });
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_site_details_by_name', "Site found: " . ($site ? $site->id : 'None'));
    return $site;
}

# Renamed to avoid duplicate method
sub get_site_domain_by_name {
    my ($self, $c, $domain_name) = @_;

    # Check if domain_name is defined
    unless (defined $domain_name && $domain_name ne '') {
        $self->logging->log_with_details(
            $c,
            'error',
            __FILE__,
            __LINE__,
            'get_site_domain',
            "Domain name not provided"
        );
        return;
    }

    # Attempt to query the SiteDomain table
    my $site_domain;
    eval {
        $site_domain = $self->schema->resultset('SiteDomain')->find({ domain => $domain_name });
    };

    if ($@ || !$site_domain) {
        # Log failure for missing or invalid domain
        my $error = !$site_domain
            ? "Site domain '$domain_name' not found."
            : "Error querying site domain for '$domain_name': $@";
        $self->logging->log_with_details(
            $c,
            'error',
            __FILE__,
            __LINE__,
            'get_site_domain',
            $error
        );

        # Forward to the 'database_setup' action on failure
        $c->forward('/admin/database_setup'); # Use the Admin controller's action
        $c->detach; # Stop further processing
        return;
    }

    # On success, log and return the site domain object
    $self->logging->log_with_details(
        $c,
        'info',
        __FILE__,
        __LINE__,
        'get_site_domain',
        "Site domain successfully retrieved for '$domain_name'."
    );

    return $site_domain;
}



# Renamed to avoid duplicate method
sub get_site_domain_with_error_handling {
    my ($self, $c, $domain_name) = @_;

    # Log the attempt to fetch the site domain
    $self->logging->log_with_details(
        $c,
        'info',
        __FILE__,
        __LINE__,
        'get_site_domain',
        "Fetching site domain record for domain name: '$domain_name'."
    );

    # Try to ensure database connection with better error handling
    my $is_connected = 0;
    my $connection_error = '';

    eval {
        $is_connected = $self->schema->storage->ensure_connected;
        $is_connected = 1 if $is_connected; # normalize to 1 if successful
    };

    if ($@) {
        $connection_error = $@;
    }

    # If connection failed, log and return null
    unless ($is_connected) {
        # Log database connection failure with detailed error
        $self->logging->log_with_details(
            $c,
            'error',
            __FILE__,
            __LINE__,
            'get_site_domain',
            "Database connection failed: " . ($connection_error || "Unknown error")
        );

        # Add a message to the stash for the user
        if ($c && ref($c) eq 'Catalyst::Context') {
            $c->stash->{db_connection_error} = 1;
            $c->stash->{error_message} = "Could not connect to the database. Please check your database configuration.";
        }

        return;
    }

    # Query the SiteDomain table with better error handling
    my $site_domain;
    my $query_error = '';

    eval {
        my $site_domain_rs = $self->schema->resultset('SiteDomain');
        $site_domain = $site_domain_rs->find({ domain => $domain_name });
    };

    if ($@) {
        $query_error = $@;
    }

    # If query failed or no domain found, log and return null
    if ($query_error || !$site_domain) {
        # Log query failure or missing domain
        my $error_message = $query_error || "Domain '$domain_name' not found in SiteDomain table.";
        $self->logging->log_with_details(
            $c,
            'error',
            __FILE__,
            __LINE__,
            'get_site_domain',
            "Failed to fetch site domain: $error_message"
        );

        # Add a message to the stash if domain not found
        if ($c && ref($c) eq 'Catalyst::Context' && !$query_error) {
            $c->stash->{domain_not_found} = 1;
            $c->stash->{domain_name} = $domain_name;
        }

        return;
    }

    # Log success and return the site domain object
    $self->logging->log_with_details(
        $c,
        'info',
        __FILE__,
        __LINE__,
        'get_site_domain',
        "Successfully retrieved site domain for '$domain_name'."
    );

    return $site_domain;
}

sub get_site_details {
    my ($self, $site_id, $c) = @_;

    # Check if site_id is defined
    unless (defined $site_id && $site_id ne '') {
        if ($c) {
            $self->logging->log_with_details(
                $c,
                'error',
                __FILE__,
                __LINE__,
                'get_site_details',
                "Site ID not provided"
            );
        }
        return $self->get_default_site();
    }

    # Try to get site details with error handling
    my $site;
    eval {
        my $site_rs = $self->schema->resultset('Site');
        $site = $site_rs->find({ id => $site_id });
    };

    # If there was an error or no site found, return default site
    if ($@ || !$site) {
        if ($c) {
            $self->logging->log_with_details(
                $c,
                'error',
                __FILE__,
                __LINE__,
                'get_site_details',
                "Failed to get site details for ID $site_id: " . ($@ || "Site not found")
            );
        }
        return $self->get_default_site();
    }

    # Log success
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_site_details', "Site ID: $site_id");

    return $site;
}

# Renamed to avoid duplicate method
sub get_site_details_by_name_with_error_handling {
    my ($self, $c, $site_name) = @_;

    # Log the attempt
    if ($c) {
        $self->logging->log_with_details(
            $c,
            'info',
            __FILE__,
            __LINE__,
            'get_site_details_by_name_with_error_handling',
            "Site name: $site_name"
        );
    }

    # Return default values if no site name provided
    unless (defined $site_name && $site_name ne '') {
        return $self->get_default_site();
    }

    # Try to find the site by name
    my $site;
    eval {
        my $site_rs = $self->schema->resultset('Site');
        $site = $site_rs->find({ name => $site_name });
    };

    # If there was an error or no site found, return default site
    if ($@ || !$site) {
        if ($c) {
            $self->logging->log_with_details(
                $c,
                'error',
                __FILE__,
                __LINE__,
                'get_site_details_by_name_with_error_handling',
                "Failed to get site details for name $site_name: " . ($@ || "Site not found")
            );
        }
        return $self->get_default_site();
    }

    # Log success
    if ($c) {
        $self->logging->log_with_details(
            $c,
            'info',
            __FILE__,
            __LINE__,
            'get_site_details_by_name_with_error_handling',
            "Site found: " . $site->id
        );
    }

    return $site;
}

# Create a default site object when database connection fails
sub get_default_site {
    my ($self) = @_;

    # Create a simple object with default values
    my $default_site = {
        name => 'default',
        site_display_name => 'Default Site',
        css_view_name => '/static/css/default.css',
        mail_to_admin => 'admin@example.com',
        mail_replyto => 'helpdesk.computersystemconsulting.ca',
        home_view => 'Root'
    };

    # Convert the hashref to an object with accessor methods
    return bless $default_site, 'Comserv::Model::Site::DefaultSite';
}

# Package for default site object
package Comserv::Model::Site::DefaultSite;

# Simple accessor method for all fields
sub AUTOLOAD {
    my $self = shift;
    our $AUTOLOAD;
    my $method = $AUTOLOAD;
    $method =~ s/.*:://;
    return $self->{$method} if exists $self->{$method};
    return undef;
}

sub DESTROY { }

package Comserv::Model::Site;
__PACKAGE__->meta->make_immutable;

1;