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

    # Always remove theme from site_details as it's stored in a JSON file, not in the database
    my $filtered_details = {%$site_details};
    delete $filtered_details->{theme};
    
    # Ensure required fields have values
    $filtered_details->{affiliate} = 1 unless defined $filtered_details->{affiliate} && $filtered_details->{affiliate} ne '';
    $filtered_details->{pid} = 0 unless defined $filtered_details->{pid} && $filtered_details->{pid} ne '';
    
    # Set default values for other potentially required fields if they're missing
    my @required_fields = qw(
        app_logo app_logo_alt app_logo_width app_logo_height
        document_root_url link_target http_header_params image_root_url
        global_datafiles_directory templates_cache_directory app_datafiles_directory
        datasource_type cal_table http_header_description http_header_keywords
        mail_to_discussion mail_to_client
    );
    
    foreach my $field (@required_fields) {
        unless (defined $filtered_details->{$field} && $filtered_details->{$field} ne '') {
            # Set default values based on field type
            if ($field =~ /width|height/) {
                $filtered_details->{$field} = 100; # Default size
            } elsif ($field =~ /mail_to/) {
                $filtered_details->{$field} = $filtered_details->{mail_from} || 'admin@example.com';
            } elsif ($field =~ /directory|url/) {
                $filtered_details->{$field} = '/';
            } else {
                $filtered_details->{$field} = 'default';
            }
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_site', 
                "Setting default value for missing field $field: " . $filtered_details->{$field});
        }
    }

    try {
        $site_rs = $self->schema->resultset('Site');
        
        # Check if a site with the same name already exists
        if (defined $filtered_details->{name}) {
            my $existing_site = $site_rs->find({ name => $filtered_details->{name} });
            if ($existing_site) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'add_site', 
                    "Site with name '" . $filtered_details->{name} . "' already exists (ID: " . $existing_site->id . ")");
                
                # Add debug message
                if (defined $c->stash->{debug_errors} && ref $c->stash->{debug_errors} eq 'ARRAY') {
                    push @{$c->stash->{debug_errors}}, "Site with name '" . $filtered_details->{name} . "' already exists";
                } else {
                    $c->stash->{debug_errors} = ["Site with name '" . $filtered_details->{name} . "' already exists"];
                }
                
                # Return the existing site instead of creating a duplicate
                return $existing_site;
            }
        }
        
        # Create the new site if it doesn't exist
        $new_site = $site_rs->create($filtered_details);
        
        # If we have a theme in the original details, set it using ThemeConfig
        if ($site_details->{theme} && $new_site) {
            $c->model('ThemeConfig')->set_site_theme($c, $new_site->name, $site_details->{theme});
        }
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_site', "Error creating site: $error");
        
        # Check for duplicate key error (MySQL specific)
        if ($error =~ /Duplicate entry.*for key.*name/) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_site', 
                "Site with name '" . $filtered_details->{name} . "' already exists");
            
            # Add debug message
            if (defined $c->stash->{debug_errors} && ref $c->stash->{debug_errors} eq 'ARRAY') {
                push @{$c->stash->{debug_errors}}, "Site with name '" . $filtered_details->{name} . "' already exists";
            } else {
                $c->stash->{debug_errors} = ["Site with name '" . $filtered_details->{name} . "' already exists"];
            }
            
            # Try to return the existing site
            my $existing_site = $site_rs->find({ name => $filtered_details->{name} });
            return $existing_site if $existing_site;
            
            die "Site with name '" . $filtered_details->{name} . "' already exists";
        }
        # Provide more specific error message for common issues
        elsif ($error =~ /Field '(\w+)' doesn't have a default value/) {
            my $missing_field = $1;
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_site', 
                "Missing required field: $missing_field. Please provide a value for this field.");
            die "Missing required field: $missing_field. Please provide a value for this field.";
        } else {
            die $error;
        }
    };

    return $new_site;
}

sub update_site {
    my ($self, $c, $site_id, $new_site_details) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_site', "Updating site with ID $site_id: " . join(", ", map { "$_: $new_site_details->{$_}" } keys %$new_site_details));
    
    # Extract theme if present
    my $theme = $new_site_details->{theme};
    my $filtered_details = {%$new_site_details};
    delete $filtered_details->{theme};
    
    # Update site in database
    my $site_rs = $self->schema->resultset('Site');
    my $site = $site_rs->find($site_id);
    
    if ($site) {
        $site->update($filtered_details);
        
        # Update theme if provided
        if (defined $theme) {
            $c->model('ThemeConfig')->set_site_theme($c, $site->name, $theme);
        }
    }
    
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
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_site_details_by_name', "Site name: $site_name");
    # Push debug message to stash as requested
    $c->stash->{debug_msg} = "Looking up site details for: $site_name";

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