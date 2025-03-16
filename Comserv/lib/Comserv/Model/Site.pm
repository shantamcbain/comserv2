package Comserv::Model::Site;

use Moose;
use namespace::autoclean;
use Try::Tiny;
use Comserv::Util::Logging;
use JSON;
use File::Slurp;

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

    my @sites;
    try {
        my $site_rs = $self->schema->resultset('Site');
        @sites = $site_rs->all;
    } catch {
        # If there's an error about the theme column
        if ($_ =~ /Unknown column 'me\.theme'/) {
            # Log the error
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_all_sites', "Theme column doesn't exist in sites table. Please run the add_theme_column.pl script.");

            # Get sites without theme column
            my $site_rs = $self->schema->resultset('Site');
            @sites = $site_rs->search(
                {},
                { columns => [qw(id name description affiliate pid auth_table home_view app_logo app_logo_alt
                                app_logo_width app_logo_height css_view_name mail_from mail_to mail_to_discussion
                                mail_to_admin mail_to_user mail_to_client mail_replyto site_display_name
                                document_root_url link_target http_header_params image_root_url
                                global_datafiles_directory templates_cache_directory app_datafiles_directory
                                datasource_type cal_table http_header_description http_header_keywords)] }
            );

            # Add a default theme property to each site
            foreach my $site (@sites) {
                $site->{theme} = $c->model('ThemeConfig')->get_site_theme($c, $site->{name});
            }

            # Add a message to the flash
            $c->flash->{error_msg} = "The theme feature requires a database update. <a href='/admin/add_theme_column'>Click here to add the theme column</a>.";
        } else {
            # For other errors, re-throw
            die $_;
        }
    };

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_all_sites', "Visited the site page");
    return \@sites;
}

sub get_site_domain {
    my ($self, $c, $domain) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_site_domain', "Looking up domain: $domain");

    # Initialize debug_errors array if it doesn't exist
    $c->stash->{debug_errors} //= [];

    try {
        # First check if the sitedomain table exists
        my $dbh = $self->schema->storage->dbh;
        my $sth = $dbh->table_info('', 'ency', 'sitedomain', 'TABLE');
        my $table_exists = $sth->fetchrow_arrayref;

        unless ($table_exists) {
            my $error_msg = "CRITICAL ERROR: sitedomain table does not exist in database";
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_site_domain', $error_msg);
            push @{$c->stash->{debug_errors}}, $error_msg;

            # Set specific error message for the user
            $c->stash->{domain_error} = {
                type => 'schema_missing',
                message => "The sitedomain table is missing from the database. Please run the database schema update script.",
                domain => $domain,
                technical_details => "Table 'sitedomain' does not exist in the database schema."
            };

            return undef;
        }

        # Look up the domain in the sitedomain table
        my $result = $self->schema->resultset('SiteDomain')->find({ domain => $domain });

        if ($result) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_site_domain',
                "Domain found: $domain (site_id: " . $result->site_id . ")");
            return $result;
        } else {
            my $error_msg = "DOMAIN ERROR: Domain '$domain' not found in sitedomain table";
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_site_domain', $error_msg);
            push @{$c->stash->{debug_errors}}, $error_msg;

            # Set specific error message for the user
            $c->stash->{domain_error} = {
                type => 'domain_missing',
                message => "The domain '$domain' is not configured in the system.",
                domain => $domain,
                technical_details => "Domain '$domain' not found in sitedomain table. Add it using the Site Administration interface.",
                action_required => "Please add this domain to the sitedomain table and associate it with the appropriate site."
            };

            # Set SiteName to 'none' directly
            $c->session->{SiteName} = 'none';
            $c->stash->{SiteName} = 'none';

            return undef;
        }
    } catch {
        my $error = $_;
        if ($error =~ /Table 'ency\.sitedomain' doesn't exist/) {
            my $error_msg = "SCHEMA ERROR: Table 'ency.sitedomain' doesn't exist. Schema update required.";
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_site_domain', $error_msg);
            push @{$c->stash->{debug_errors}}, $error_msg;

            # Set specific error message for the user
            $c->stash->{domain_error} = {
                type => 'schema_error',
                message => "The database schema is outdated and missing required tables.",
                domain => $domain,
                technical_details => "Table 'ency.sitedomain' doesn't exist. Schema update required.",
                action_required => "Please run the database schema update script."
            };

            return undef;
        } else {
            my $error_msg = "DATABASE ERROR: Failed to query sitedomain table: $error";
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_site_domain', $error_msg);
            push @{$c->stash->{debug_errors}}, $error_msg;

            # Set specific error message for the user
            $c->stash->{domain_error} = {
                type => 'database_error',
                message => "A database error occurred while looking up the domain.",
                domain => $domain,
                technical_details => "Error: $error",
                action_required => "Please check the database connection and configuration."
            };

            die $error;
        }
    };
}

sub add_site {
    my ($self, $c, $site_details) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_site', "Adding new site: " . join(", ", map { "$_: $site_details->{$_}" } keys %$site_details));

    my $site_rs;
    my $new_site;

    try {
        $site_rs = $self->schema->resultset('Site');
        $new_site = $site_rs->create($site_details);
    } catch {
        # If there's an error about the theme column
        if ($_ =~ /Unknown column 'me\.theme'/) {
            # Log the error
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_site', "Theme column doesn't exist in sites table. Please run the add_theme_column.pl script.");

            # Create site without theme column
            my $filtered_details = {%$site_details};
            delete $filtered_details->{theme};

            $site_rs = $self->schema->resultset('Site');
            $new_site = $site_rs->create($filtered_details);

            # Add a default theme property
            $new_site->{theme} = $c->model('ThemeConfig')->get_site_theme($c, $new_site->{name});

            # Add a message to the flash
            $c->flash->{error_msg} = "The theme feature requires a database update. <a href='/admin/add_theme_column'>Click here to add the theme column</a>.";
        } else {
            # For other errors, re-throw
            die $_;
        }
    };

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

    my $site;
    try {
        my $site_rs = $self->schema->resultset('Site');
        $site = $site_rs->find({ id => $site_id });
        $site->delete if $site;
    } catch {
        # If there's an error about the theme column
        if ($_ =~ /Unknown column 'me\.theme'/) {
            # Log the error
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'delete_site', "Theme column doesn't exist in sites table. Please run the add_theme_column.pl script.");

            # Get site without theme column
            my $site_rs = $self->schema->resultset('Site');
            $site = $site_rs->find(
                { id => $site_id },
                { columns => [qw(id name description affiliate pid auth_table home_view app_logo app_logo_alt
                                app_logo_width app_logo_height css_view_name mail_from mail_to mail_to_discussion
                                mail_to_admin mail_to_user mail_to_client mail_replyto site_display_name
                                document_root_url link_target http_header_params image_root_url
                                global_datafiles_directory templates_cache_directory app_datafiles_directory
                                datasource_type cal_table http_header_description http_header_keywords)] }
            );

            # Delete the site if found
            $site->delete if $site;

            # Add a default theme property
            $site->{theme} = $c->model('ThemeConfig')->get_site_theme($c, $site->{name}) if $site;

            # Add a message to the flash
            $c->flash->{error_msg} = "The theme feature requires a database update. <a href='/admin/add_theme_column'>Click here to add the theme column</a>.";
        } else {
            # For other errors, re-throw
            die $_;
        }
    };

    return $site;
}

sub get_site_details_by_name {
    my ($self, $c, $site_name) = @_;
    print " in get_site_details_by_name Site name: $site_name\n";
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_site_details_by_name', "Site name: $site_name");

    my $site;
    try {
        my $site_rs = $self->schema->resultset('Site');
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_site_details_by_name', "Visited the site page $site_rs");
        $site = $site_rs->find({ name => $site_name });
    } catch {
        # If there's an error about the theme column
        if ($_ =~ /Unknown column 'me\.theme'/) {
            # Log the error
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_site_details_by_name', "Theme column doesn't exist in sites table. Please run the add_theme_column.pl script.");

            # Get site without theme column
            my $site_rs = $self->schema->resultset('Site');
            $site = $site_rs->find(
                { name => $site_name },
                { columns => [qw(id name description affiliate pid auth_table home_view app_logo app_logo_alt
                                app_logo_width app_logo_height css_view_name mail_from mail_to mail_to_discussion
                                mail_to_admin mail_to_user mail_to_client mail_replyto site_display_name
                                document_root_url link_target http_header_params image_root_url
                                global_datafiles_directory templates_cache_directory app_datafiles_directory
                                datasource_type cal_table http_header_description http_header_keywords)] }
            );

            # Add a default theme property
            $site->{theme} = $c->model('ThemeConfig')->get_site_theme($c, $site_name) if $site;

            # Add a message to the flash
            $c->flash->{error_msg} = "The theme feature requires a database update. Please run the add_theme_column.pl script.";
        } else {
            # For other errors, re-throw
            die $_;
        }
    };

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
    my ($self, $c, $site_id) = @_;
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


    my $site;
    try {
        my $site_rs = $self->schema->resultset('Site');
        $site = $site_rs->find({ id => $site_id });
    } catch {
        # If there's an error about the theme column
        if ($_ =~ /Unknown column 'me\.theme'/) {
            # Log the error
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_site_details', "Theme column doesn't exist in sites table. Please run the add_theme_column.pl script.");

            # Get site without theme column
            my $site_rs = $self->schema->resultset('Site');
            $site = $site_rs->find(
                { id => $site_id },
                { columns => [qw(id name description affiliate pid auth_table home_view app_logo app_logo_alt
                                app_logo_width app_logo_height css_view_name mail_from mail_to mail_to_discussion
                                mail_to_admin mail_to_user mail_to_client mail_replyto site_display_name
                                document_root_url link_target http_header_params image_root_url
                                global_datafiles_directory templates_cache_directory app_datafiles_directory
                                datasource_type cal_table http_header_description http_header_keywords)] }
            );

            # Add a default theme property
            $site->{theme} = $c->model('ThemeConfig')->get_site_theme($c, $site->{name}) if $site;

            # Add a message to the flash
            $c->flash->{error_msg} = "The theme feature requires a database update. Please run the add_theme_column.pl script.";
        } else {
            # For other errors, re-throw
            die $_;
        }
    };

    return $site;
}

__PACKAGE__->meta->make_immutable;

1;