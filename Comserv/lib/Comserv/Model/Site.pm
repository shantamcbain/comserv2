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
                $site->{theme} = 'default';
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
            $new_site->{theme} = 'default';

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
    my ($self, $c,$site_id, $new_site_details) = @_;
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
            $site->{theme} = 'default' if $site;

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
            $site->{theme} = 'default' if $site;

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


sub get_site_details {
    my ($self, $c, $site_id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_site_details', "Site ID: $site_id");

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
            $site->{theme} = 'default' if $site;

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