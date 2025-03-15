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
has 'logging' => (
    is      => 'ro',
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
    my ($self, $c,$site_id, $new_site_details) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_site', "Updating site with ID $site_id: " . join(", ", map { "$_: $new_site_details->{$_}" } keys %$new_site_details));
    my $site_rs = $self->schema->resultset('Site');
    my $site = $site_rs->find($site_id);
    $site->update($new_site_details) if $site;
    return $site;
}

sub delete_site {
    my ($self, $c,$site_id) = @_;
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
sub get_site_domain {
    my ($self, $c, $domain_name) = @_;

    # Log the attempt to retrieve the domain
    $self->logging->log_with_details(
        $c,
        'info',
        __FILE__,
        __LINE__,
        'get_site_domain',
        "Attempting to fetch site domain record for domain: '$domain_name'."
    );

    # Attempt to ensure the database connection
    eval {
        $self->schema->storage->ensure_connected;
    };
    if ($@) {
        # Log database connection failure
        $self->logging->log_with_details(
            $c,
            'error',
            __FILE__,
            __LINE__,
            'get_site_domain',
            "Database connection failed: $@"
        );

        # Forward to the 'database_setup' action for rendering the setup template
        $c->forward('/admin/database_setup'); # Use the full action path
        $c->detach; # Stop further processing
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


sub get_site_domain {
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

    # Ensure database connection
    my $is_connected = eval {
        $self->schema->storage->ensure_connected;
        1;
    };

    if (!$is_connected) {
        # Log database connection failure
        $self->logging->log_with_details(
            $c,
            'error',
            __FILE__,
            __LINE__,
            'get_site_domain',
            "Database connection failed: $@"
        );

        # Forward to /admin/database_setup
        $c->forward('/admin/database_setup');
            $c->forward($c->view('TT'));
        $c->detach; # Ensure processing halts here
        return;     # Safeguard against continuing further
    }

    # Query the SiteDomain table
    my $site_domain;
    eval {
        my $site_domain_rs = $self->schema->resultset('SiteDomain');
        $site_domain = $site_domain_rs->find({ domain => $domain_name });
    };

    if ($@ || !$site_domain) {
        # Log query failure or missing domain
        my $error_message = $@ ? $@ : "Domain '$domain_name' not found in SiteDomain table.";
        $self->logging->log_with_details(
            $c,
            'error',
            __FILE__,
            __LINE__,
            'get_site_domain',
            "Failed to fetch site domain: $error_message"
        );

        # Forward to /admin/database_setup
        $c->forward('/admin/database_setup');
        $c->detach; # Ensure no further processing happens
        return;     # Safeguard
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
    my ($self, $c,$site_id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_site_details', "Site ID: $site_id");
    my $site_rs = $self->schema->resultset('Site');
    my $site = $site_rs->find({ id => $site_id });
    return $site;
}

__PACKAGE__->meta->make_immutable;

1;