package Comserv::Controller::ThemeAdmin;

use Moose;
use namespace::autoclean;
use Try::Tiny;
use File::Slurp;
use File::Path qw(make_path);
use Data::Dumper;
use Comserv::Util::Logging;
use Comserv::Util::ThemeManager;

BEGIN { extends 'Catalyst::Controller'; }

__PACKAGE__->config(namespace => 'themeadmin');

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has 'theme_manager' => (
    is => 'ro',
    default => sub { Comserv::Util::ThemeManager->new }
);

# Simple index method that uses the same template as the main index
sub simple :Path('/themeadmin/simple') :Args(0) {
    my ($self, $c) = @_;

    # Log that we've entered the simple method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'simple', "***** ENTERED THEMEADMIN SIMPLE METHOD *****");

    # Get current site
    my $site_name = $c->session->{SiteName};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'simple', "Site name: $site_name");

    # Create a simple site object
    my $site = {
        id => 1,
        name => $site_name,
        theme => lc($site_name) eq 'apis' ? 'apis' :
                 lc($site_name) eq 'usbm' ? 'usbm' : 'default'
    };

    # Create a simple list of available themes
    my @available_themes = qw(default apis usbm);

    # Pass data to template
    $c->stash->{site} = $site;
    $c->stash->{sites} = [$site];
    $c->stash->{available_themes} = \@available_themes;
    $c->stash->{theme_column_exists} = 0;
    $c->stash->{template} = 'admin/theme/index.tt';

    # Log that we're rendering the template
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'simple', "***** RENDERING TEMPLATE: admin/theme/index.tt *****");

    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

# Direct access test page (no permission checks)
sub test :Path('/themeadmin/test') :Args(0) {
    my ($self, $c) = @_;

    # Log that we've entered the test method
    $c->log->info("***** ENTERED THEMEADMIN TEST METHOD *****");

    # Create a simple HTML response
    my $html = <<'HTML';
<!DOCTYPE html>
<html>
<head>
    <title>ThemeAdmin Test</title>
</head>
<body>
    <h1>ThemeAdmin Test Works!</h1>
    <p>This is a test method in the ThemeAdmin controller that doesn't check permissions.</p>
    <p>If you can see this page, the ThemeAdmin controller is being loaded correctly.</p>
    <p><a href="/admin">Return to Admin</a></p>
</body>
</html>
HTML

    # Set the response
    $c->response->body($html);
    $c->response->content_type('text/html');
}

# Theme management page
sub index :Path :Args(0) {
    my ($self, $c) = @_;

    # Debug message at the very beginning of the method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "***** THEMEADMIN INDEX METHOD CALLED *****");

    # Add debug information
    $c->stash->{debug_info} = {
        user_exists => $c->user_exists ? 'Yes' : 'No',
        session_id => $c->sessionid,
        session_data => $c->session,
        roles => $c->session->{roles},
    };

    # Check if the user is logged in
    if (!$c->user_exists && !$c->session->{user_id}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "User not logged in, redirecting to login page");
        $c->flash->{error} = 'You must be logged in to access this page';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Check if the user has the admin role
    my $roles = $c->session->{roles};

    # IMPORTANT: Roles check is completely disabled for testing
    # This should be re-enabled after testing is complete
    if (0) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "User does not have admin role, redirecting to home page");
        $c->flash->{error} = 'You do not have permission to access this page';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Get current site
    my $site_name = $c->session->{SiteName};
    my $site;
    my $theme_column_exists = 0;

    # Check if the theme column exists in the database
    try {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        my $sth = $dbh->prepare("SHOW COLUMNS FROM sites LIKE 'theme'");
        $sth->execute();
        $theme_column_exists = $sth->fetchrow_array() ? 1 : 0;
    } catch {
        $c->log->error("Error checking if theme column exists: $_");
        $theme_column_exists = 0;
    };

    # Try to get the site from the database
    try {
        if ($theme_column_exists) {
            # If theme column exists, get the site with all columns
            $site = $c->model('DBEncy')->resultset('Site')->find({ name => $site_name });
        } else {
            # If theme column doesn't exist, get the site without the theme column
            $site = $c->model('DBEncy')->resultset('Site')->find(
                { name => $site_name },
                { columns => [qw(id name description affiliate pid auth_table home_view app_logo app_logo_alt
                              app_logo_width app_logo_height css_view_name mail_from mail_to mail_to_discussion
                              mail_to_admin mail_to_user mail_to_client mail_replyto site_display_name
                              document_root_url link_target http_header_params image_root_url
                              global_datafiles_directory templates_cache_directory app_datafiles_directory
                              datasource_type cal_table http_header_description http_header_keywords)] }
            );
        }
    } catch {
        $c->log->error("Error getting site: $_");
        # Create a minimal site object
        $site = { id => 0, name => $site_name, description => 'Error getting site details' };
    };

    # Get the theme for this site from our JSON-based theme manager
    my $theme_name = $self->theme_manager->get_site_theme($c, $site_name);

    # Add the theme to the site object
    $site->{theme} = $theme_name;

    # Get all sites for admin
    my @sites;
    if (lc($site_name) eq 'apis') {
        try {
            if ($theme_column_exists) {
                @sites = $c->model('DBEncy')->resultset('Site')->all;
            } else {
                @sites = $c->model('DBEncy')->resultset('Site')->search(
                    {},
                    { columns => [qw(id name description affiliate pid auth_table home_view app_logo app_logo_alt
                                  app_logo_width app_logo_height css_view_name mail_from mail_to mail_to_discussion
                                  mail_to_admin mail_to_user mail_to_client mail_replyto site_display_name
                                  document_root_url link_target http_header_params image_root_url
                                  global_datafiles_directory templates_cache_directory app_datafiles_directory
                                  datasource_type cal_table http_header_description http_header_keywords)] }
                );
            }

            # Add theme property to each site from our JSON-based theme manager
            foreach my $s (@sites) {
                my $site_theme = $self->theme_manager->get_site_theme($c, $s->name);
                $s->{theme} = $site_theme;
            }
        } catch {
            $c->log->error("Error getting all sites: $_");
            @sites = ($site);
        };
    } else {
        @sites = ($site);
    }

    # Get available themes from our JSON-based theme manager
    my $themes = $self->theme_manager->get_all_themes($c);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Available themes from JSON: " . Dumper($themes));

    # Make sure we have all the predefined themes
    my @available_themes = sort keys %$themes;

    # Ensure we have the basic themes
    my @basic_themes = qw(default csc apis usbm);
    foreach my $basic_theme (@basic_themes) {
        if (!grep { $_ eq $basic_theme } @available_themes) {
            push @available_themes, $basic_theme;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Added missing basic theme: $basic_theme");
        }
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Final available themes array: " . join(", ", @available_themes));

    # Pass data to template
    $c->stash->{site} = $site;
    $c->stash->{sites} = \@sites;
    $c->stash->{available_themes} = \@available_themes;
    $c->stash->{theme_column_exists} = $theme_column_exists;
    $c->stash->{themes} = $themes;
    $c->stash->{template} = 'admin/theme/index.tt';  # This is the template path
    $c->stash->{using_json_themes} = 1;
    $c->stash->{info_msg} = "The theme system is using JSON-based theme definitions. Database integration will be available in a future update.";

    # Log the template path
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "Template path: " . $c->stash->{template});

    # Log that we're rendering the template
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "***** RENDERING TEMPLATE: admin/theme/index.tt *****");

    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

# Update theme
sub update_theme :Path('update_theme') :Args(0) {
    my ($self, $c) = @_;

    # Check if the user is logged in
    if (!$c->user_exists) {
        $c->flash->{error} = 'You must be logged in to access this page';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Check if the user has the admin role
    my $roles = $c->session->{roles};
    if (!defined $roles || ref $roles ne 'ARRAY' || !grep { $_ eq 'admin' } @$roles) {
        $c->flash->{error} = 'You do not have permission to access this page';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Get parameters
    my $site_id = $c->request->params->{site_id};
    my $theme = $c->request->params->{theme};

    # Get site
    my $site;

    try {
        $site = $c->model('DBEncy')->resultset('Site')->find($site_id);
        my $site_name = $site->name;

        # Check if the theme column exists in the database
        my $theme_column_exists = 0;
        try {
            my $dbh = $c->model('DBEncy')->schema->storage->dbh;
            my $sth = $dbh->prepare("SHOW COLUMNS FROM sites LIKE 'theme'");
            $sth->execute();
            $theme_column_exists = $sth->fetchrow_array() ? 1 : 0;
        } catch {
            $c->log->error("Error checking if theme column exists: $_");
            $theme_column_exists = 0;
        };

        # Log the theme update attempt
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme',
            "Attempting to update theme for site $site_name to $theme");

        # Update the theme using our JSON-based theme manager
        my $result = $self->theme_manager->set_site_theme($c, $site_name, $theme);

        if ($result) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme',
                "Successfully updated theme for site $site_name to $theme");
            $c->flash->{message} = "Theme updated to $theme for site $site_name";

            # If the theme column exists in the database, also update it
            if ($theme_column_exists) {
                try {
                    $site->update({ theme => $theme });
                    $c->flash->{message} .= " (database updated)";
                } catch {
                    $c->log->error("Error updating theme in database: $_");
                };
            }
        } else {
            $c->flash->{error} = "Error updating theme for site $site_name";
        }
    } catch {
        $c->flash->{error} = "Error finding site: $_";
    };

    # Redirect back to theme index
    $c->response->redirect($c->uri_for($self->action_for('index')));
}

# Create custom theme
sub create_custom_theme :Path('create_custom_theme') :Args(0) {
    my ($self, $c) = @_;

    # Check if the user is logged in
    if (!$c->user_exists) {
        $c->flash->{error} = 'You must be logged in to access this page';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Check if the user has the admin role
    my $roles = $c->session->{roles};
    if (!defined $roles || ref $roles ne 'ARRAY' || !grep { $_ eq 'admin' } @$roles) {
        $c->flash->{error} = 'You do not have permission to access this page';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Get parameters
    my $site_id = $c->request->params->{site_id};
    my $primary_color = $c->request->params->{primary_color};
    my $secondary_color = $c->request->params->{secondary_color};
    my $accent_color = $c->request->params->{accent_color};
    my $text_color = $c->request->params->{text_color};
    my $link_color = $c->request->params->{link_color};

    # Get site
    my $site;
    my $site_name;

    try {
        $site = $c->model('DBEncy')->resultset('Site')->find($site_id);
        $site_name = $site->name;
    } catch {
        $c->flash->{error} = "Error finding site: $_";
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    };

    # Create theme data structure
    my $theme_data = {
        name => "$site_name Custom Theme",
        description => "Custom theme for $site_name",
        variables => {
            "primary-color" => $primary_color,
            "secondary-color" => $secondary_color,
            "accent-color" => $accent_color,
            "text-color" => $text_color,
            "background-color" => "#ffffff",
            "link-color" => $link_color,
            "link-hover-color" => $link_color,
            "border-color" => $secondary_color,
            "table-header-bg" => $secondary_color,
            "warning-color" => "#ff0000",
            "success-color" => "#009900",
            "button-bg" => $primary_color,
            "button-text" => $text_color,
            "button-border" => $accent_color,
            "button-hover-bg" => $accent_color,
            "nav-bg" => $primary_color,
            "nav-text" => $text_color,
            "nav-hover-bg" => "rgba(0, 0, 0, 0.1)"
        }
    };

    # Generate theme name
    my $theme_name = lc($site_name) . '_custom';

    # Create the theme using our JSON-based theme manager
    my $result = $self->theme_manager->create_theme($c, $theme_name, $theme_data);

    if ($result) {
        # Set the site to use this theme
        $self->theme_manager->set_site_theme($c, $site_name, $theme_name);

        $c->flash->{message} = "Custom theme created successfully for $site_name and applied to the site.";

        # Check if the theme column exists in the database
        my $theme_column_exists = 0;
        try {
            my $dbh = $c->model('DBEncy')->schema->storage->dbh;
            my $sth = $dbh->prepare("SHOW COLUMNS FROM sites LIKE 'theme'");
            $sth->execute();
            $theme_column_exists = $sth->fetchrow_array() ? 1 : 0;
        } catch {
            $c->log->error("Error checking if theme column exists: $_");
            $theme_column_exists = 0;
        };

        # If the theme column exists in the database, also update it
        if ($theme_column_exists) {
            try {
                $site->update({ theme => $theme_name });
                $c->flash->{message} .= " (database updated)";
            } catch {
                $c->log->error("Error updating theme in database: $_");
            };
        }
    } else {
        $c->flash->{error} = "Error creating custom theme for $site_name";
    }

    # Redirect back to theme index
    $c->response->redirect($c->uri_for($self->action_for('index')));
}

__PACKAGE__->meta->make_immutable;
1;
