package Comserv::Controller::ThemeAdmin;

use Moose;
use namespace::autoclean;
use Try::Tiny;
use File::Slurp;
use File::Path qw(make_path);
use Data::Dumper;
use Comserv::Util::Logging;
use JSON qw(encode_json decode_json);

BEGIN { extends 'Catalyst::Controller'; }

__PACKAGE__->config(namespace => 'themeadmin');

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# Simple index method that uses the same template as the main index
sub simple :Path('/themeadmin/simple') :Args(0) {
    my ($self, $c) = @_;

    # Log that we've entered the simple method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'simple', "***** ENTERED THEMEADMIN SIMPLE METHOD *****");

    # Check if the user is logged in
    if (!$c->user_exists && !$c->session->{user_id}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'simple', "User not logged in, redirecting to login page");
        $c->flash->{error} = 'You must be logged in to access this page';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Check if the user has the admin role
    my $roles = $c->session->{roles};
    if (!defined $roles || ref $roles ne 'ARRAY' || !grep { $_ eq 'admin' } @$roles) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'simple',
            "User does not have admin role, redirecting to home page. Roles: " .
            (defined $roles ? (ref $roles eq 'ARRAY' ? join(", ", @$roles) : ref($roles)) : "undefined"));
        $c->flash->{error} = 'You do not have permission to access this page. Required role: admin.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Get current site
    my $site_name = $c->session->{SiteName};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'simple', "Site name: $site_name");

    # Create a simple site object
    # Get the theme for this site from our theme config
    my $theme_name = $c->model('ThemeConfig')->get_site_theme($c, $site_name);

    my $site = {
        id => 1,
        name => $site_name,
        theme => $theme_name || 'default'
    };

    # Create a simple list of available themes
    my @available_themes = qw(default apis usbm dark);

    # Pass data to template
    $c->stash->{site} = $site;
    $c->stash->{sites} = [$site];
    $c->stash->{available_themes} = \@available_themes;
    $c->stash->{theme_column_exists} = 0;
    $c->stash->{template} = 'admin/theme/index.tt';

    # Make sure the theme_name is set in both the stash and session for the Header.tt template
    $c->stash->{theme_name} = $site->{theme};
    $c->session->{theme_name} = $site->{theme};

    # Log that we're rendering the template
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'simple', "***** RENDERING TEMPLATE: admin/theme/index.tt *****");

    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

# Direct access test page (no permission checks)
sub test :Path('/themeadmin/test') :Args(0) {
    my ($self, $c) = @_;

    # Log that we've entered the test method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test', "***** ENTERED THEMEADMIN TEST METHOD *****");

    # Check if the user is logged in
    if (!$c->user_exists && !$c->session->{user_id}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test', "User not logged in, redirecting to login page");
        $c->flash->{error} = 'You must be logged in to access this page';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Check if the user has the admin role
    my $roles = $c->session->{roles};
    if (!defined $roles || ref $roles ne 'ARRAY' || !grep { $_ eq 'admin' } @$roles) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test',
            "User does not have admin role, redirecting to home page. Roles: " .
            (defined $roles ? (ref $roles eq 'ARRAY' ? join(", ", @$roles) : ref($roles)) : "undefined"));
        $c->flash->{error} = 'You do not have permission to access this page. Required role: admin.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

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

# CSS Settings form - main entry point from admin navigation
sub css_form :Path('/css_form') :Args(0) {
    my ($self, $c) = @_;

    # Log that we've entered the css_form method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'css_form', "***** ENTERED CSS_FORM METHOD *****");

    # Check if the user is logged in
    if (!$c->user_exists && !$c->session->{user_id}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'css_form', "User not logged in, redirecting to login page");
        $c->flash->{error} = 'You must be logged in to access this page';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Check if the user has the admin role
    my $roles = $c->session->{roles};
    if (!defined $roles || ref $roles ne 'ARRAY' || !grep { $_ eq 'admin' } @$roles) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'css_form',
            "User does not have admin role, redirecting to home page. Roles: " .
            (defined $roles ? (ref $roles eq 'ARRAY' ? join(", ", @$roles) : ref($roles)) : "undefined"));
        $c->flash->{error} = 'You do not have permission to access this page. Required role: admin.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Get current site
    my $site_name = $c->session->{SiteName};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'css_form', "Site name: $site_name");

    # Get the theme for this site from our theme config
    my $theme_name = $c->model('ThemeConfig')->get_site_theme($c, $site_name);

    # Get available themes from the themes directory
    my $themes_dir = $c->path_to('root', 'static', 'css', 'themes');
    my @available_themes;
    
    if (-d $themes_dir) {
        opendir(my $dh, $themes_dir) or die "Cannot open themes directory: $!";
        @available_themes = grep { 
            /\.css$/ && $_ ne 'base-containers.css' && -f "$themes_dir/$_" 
        } readdir($dh);
        closedir($dh);
        
        # Remove .css extension for display
        @available_themes = map { s/\.css$//r } @available_themes;
        @available_themes = sort @available_themes;
    }

    # Add basic themes if not found
    my @basic_themes = qw(default csc apis usbm dark admin apiary);
    foreach my $basic_theme (@basic_themes) {
        if (!grep { $_ eq $basic_theme } @available_themes) {
            push @available_themes, $basic_theme;
        }
    }

    # Pass data to template
    $c->stash->{current_theme} = $theme_name || 'default';
    $c->stash->{available_themes} = \@available_themes;
    $c->stash->{site_name} = $site_name;
    $c->stash->{template} = 'admin/css_settings.tt';

    # Log that we're rendering the template
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'css_form', "***** RENDERING TEMPLATE: admin/css_settings.tt *****");

    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

# Update theme from CSS Settings form
sub update_theme_from_css_form :Path('/css_form/update_theme') :Args(0) {
    my ($self, $c) = @_;

    # Check if the user is logged in and has admin role
    if (!$c->user_exists && !$c->session->{user_id}) {
        $c->flash->{error} = 'You must be logged in to access this page';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    my $roles = $c->session->{roles};
    if (!defined $roles || ref $roles ne 'ARRAY' || !grep { $_ eq 'admin' } @$roles) {
        $c->flash->{error} = 'You do not have permission to access this page. Required role: admin.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Get the selected theme
    my $theme = $c->request->params->{theme};
    my $site_name = $c->session->{SiteName};

    if (!$theme) {
        $c->flash->{error} = 'No theme selected';
        $c->response->redirect($c->uri_for('/css_form'));
        return;
    }

    # Update the theme using ThemeConfig model
    try {
        $c->model('ThemeConfig')->set_site_theme($c, $site_name, $theme);
        $c->flash->{success} = "Theme updated to '$theme' successfully";
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme_from_css_form', 
            "Theme updated to '$theme' for site '$site_name'");
    } catch {
        $c->flash->{error} = "Failed to update theme: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_theme_from_css_form', 
            "Failed to update theme: $_");
    };

    $c->response->redirect($c->uri_for('/css_form'));
}

# Customize theme colors from CSS Settings form
sub customize_theme :Path('/css_form/customize_theme') :Args(0) {
    my ($self, $c) = @_;

    # Check if the user is logged in and has admin role
    if (!$c->user_exists && !$c->session->{user_id}) {
        $c->flash->{error} = 'You must be logged in to access this page';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    my $roles = $c->session->{roles};
    if (!defined $roles || ref $roles ne 'ARRAY' || !grep { $_ eq 'admin' } @$roles) {
        $c->flash->{error} = 'You do not have permission to access this page. Required role: admin.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Get the custom colors from the form
    my $params = $c->request->params;
    my $site_name = $c->session->{SiteName};

    my $custom_colors = {
        'primary-color' => $params->{primary_color},
        'secondary-color' => $params->{secondary_color},
        'success-color' => $params->{success_color},
        'warning-color' => $params->{warning_color},
        'danger-color' => $params->{danger_color},
        'bg-color' => $params->{bg_color},
        'card-bg' => $params->{card_bg},
        'text-color' => $params->{text_color},
        'border-color' => $params->{border_color},
    };

    # Generate custom theme CSS
    try {
        my $custom_theme_name = $site_name . '_custom';
        my $themes_dir = $c->path_to('root', 'static', 'css', 'themes');
        my $custom_theme_file = "$themes_dir/$custom_theme_name.css";

        # Create custom CSS content
        my $css_content = "/* Custom theme for $site_name */\n";
        $css_content .= ":root {\n";
        
        foreach my $property (keys %$custom_colors) {
            my $value = $custom_colors->{$property};
            if ($value) {
                $css_content .= "    --$property: $value;\n";
            }
        }
        
        $css_content .= "}\n\n";
        $css_content .= "/* Import base containers for styling */\n";
        $css_content .= "\@import url('base-containers.css');\n";

        # Write the custom theme file
        open(my $fh, '>', $custom_theme_file) or die "Cannot open $custom_theme_file: $!";
        print $fh $css_content;
        close($fh);

        # Set the custom theme as active
        $c->model('ThemeConfig')->set_site_theme($c, $site_name, $custom_theme_name);

        $c->flash->{success} = "Custom theme created and applied successfully";
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'customize_theme', 
            "Custom theme '$custom_theme_name' created for site '$site_name'");

    } catch {
        $c->flash->{error} = "Failed to create custom theme: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'customize_theme', 
            "Failed to create custom theme: $_");
    };

    $c->response->redirect($c->uri_for('/css_form'));
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

    # Check if roles is defined and is an array reference
    if (!defined $roles || ref $roles ne 'ARRAY' || !grep { $_ eq 'admin' } @$roles) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
            "User does not have admin role, redirecting to home page. Roles: " .
            (defined $roles ? (ref $roles eq 'ARRAY' ? join(", ", @$roles) : ref($roles)) : "undefined"));
        $c->flash->{error} = 'You do not have permission to access this page. Required role: admin.';
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

    # Get the theme for this site from our JSON-based theme config
    my $theme_name = $c->model('ThemeConfig')->get_site_theme($c, $site_name);

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
                my $site_theme = $c->model('ThemeConfig')->get_site_theme($c, $s->name);
                $s->{theme} = $site_theme;
            }
        } catch {
            $c->log->error("Error getting all sites: $_");
            @sites = ($site);
        };
    } else {
        @sites = ($site);
    }

    # Get available themes from our JSON-based theme config
    my $themes = $c->model('ThemeConfig')->get_all_themes($c);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Available themes from JSON: " . Dumper($themes));

    # Make sure we have all the predefined themes
    my @available_themes = sort keys %$themes;

    # Ensure we have the basic themes
    my @basic_themes = qw(default csc apis usbm dark);
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

    # Make sure the theme_name is set in the stash for the wrapper.tt.notusedbyapplication template
    $c->stash->{theme_name} = $theme_name;

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
    if (!$c->user_exists && !$c->session->{user_id}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme', "User not logged in, redirecting to login page");
        $c->flash->{error} = 'You must be logged in to access this page';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Check if the user has the admin role
    my $roles = $c->session->{roles};
    if (!defined $roles || ref $roles ne 'ARRAY' || !grep { $_ eq 'admin' } @$roles) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme',
            "User does not have admin role, redirecting to home page. Roles: " .
            (defined $roles ? (ref $roles eq 'ARRAY' ? join(", ", @$roles) : ref($roles)) : "undefined"));
        $c->flash->{error} = 'You do not have permission to access this page. Required role: admin.';
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
        my $site_name =
 $site->name;

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
            "Attempting to update theme for site $site_name to $theme using ThemeConfig");

        # Update the theme using our JSON-based theme config
        my $result = $c->model('ThemeConfig')->set_site_theme($c, $site_name, $theme);

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
                    $c->flash->{message} .= " (Note: Database update failed but theme file was updated)";
                };
            }
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_theme',
                "Failed to update theme for site $site_name to $theme");
            $c->flash->{error} = "Error updating theme for site $site_name. Please check server logs for details.";
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
    if (!$c->user_exists && !$c->session->{user_id}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_custom_theme', "User not logged in, redirecting to login page");
        $c->flash->{error} = 'You must be logged in to access this page';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Check if the user has the admin role
    my $roles = $c->session->{roles};
    if (!defined $roles || ref $roles ne 'ARRAY' || !grep { $_ eq 'admin' } @$roles) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_custom_theme',
            "User does not have admin role, redirecting to home page. Roles: " .
            (defined $roles ? (ref $roles eq 'ARRAY' ? join(", ", @$roles) : ref($roles)) : "undefined"));
        $c->flash->{error} = 'You do not have permission to access this page. Required role: admin.';
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

# Edit theme CSS directly

sub edit_theme_css :Path('edit_theme_css') :Args(1) {
    my ($self, $c, $theme_name) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_theme_css',
        "***** ENTERED THEMEADMIN EDIT_THEME_CSS METHOD FOR $theme_name *****");

    unless ($c->user_exists && grep { $_ eq 'admin' } @{$c->session->{roles}}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'edit_theme_css',
            "Unauthorized access attempt by user: " . ($c->session->{username} || 'Guest') . ", proceeding anyway for debugging");
    }

    my $css_file = $c->path_to('root', 'static', 'css', "$theme_name.css");
    my $json_file = $c->path_to('root', 'static', 'css', 'themes', 'theme_definitions.json');

    if ($c->req->method eq 'POST') {
        my $css_content = $c->req->params->{css_content};
        try {
            write_file($css_file, $css_content);
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_theme_css',
                "CSS file updated successfully for theme: $theme_name");
            $c->flash->{success} = 'CSS file updated successfully';
        } catch {
            $c->flash->{error} = "Error saving CSS: $_";
        };
    }

    my $css_content = -f $css_file ? read_file($css_file) : '';

    my $css_variables = {};
    try {
        my $json_text = read_file($json_file);
        my $theme_definitions = decode_json($json_text);
        $css_variables = $theme_definitions->{$theme_name}->{variables} || {};
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_theme_css',
            "Error reading JSON file: $_");
        $css_variables = { error => 'Error reading JSON file' };
    };

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'edit_theme_css',
        "CSS Variables: " . encode_json($css_variables));

    $c->stash(
        template => 'admin/theme/edit_css.tt',
        css_content => $css_content,
        theme_name => $theme_name,
        css_variables => $css_variables
    );

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_theme_css',
        "***** RENDERING TEMPLATE: admin/theme/edit_css.tt *****");
}

# WYSIWYG Theme Editor
sub wysiwyg_editor :Path('wysiwyg_editor') :Args(1) {
    my ($self, $c, $theme_name) = @_;

    # Log that we've entered the wysiwyg_editor method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'wysiwyg_editor', 
        "***** ENTERED THEMEADMIN WYSIWYG_EDITOR METHOD FOR $theme_name *****");

    # Check if the user is logged in and has admin role
    unless ($c->user_exists && grep { $_ eq 'admin' } @{$c->session->{roles}}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'wysiwyg_editor', 
            "Unauthorized access attempt by user: " . ($c->session->{username} || 'Guest') . ", proceeding anyway for debugging");
        # Don't redirect, allow access for debugging
        # $c->flash->{error} = "You must be an admin to use the WYSIWYG editor";
        # $c->response->redirect($c->uri_for('/'));
        # return;
    }

    # Get the theme data from theme_definitions.json
    my $theme = $self->theme_manager->get_theme($c, $theme_name);

    # Pass data to template
    $c->stash->{theme_name} = $theme_name;
    $c->stash->{theme} = $theme;
    $c->stash->{template} = 'admin/theme/wysiwyg_editor.tt';
}

# Help page
sub help :Path('help') :Args(0) {
    my ($self, $c) = @_;

    # Log that we've entered the help method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'help',
        "***** ENTERED THEMEADMIN HELP METHOD *****");

    # Set the template
    $c->stash->{template} = 'admin/theme/help.tt';
}

# Update theme with visual editor
sub update_theme_visual :Path('update_theme_visual') :Args(0) {
    my ($self, $c) = @_;
    
    # Log that we've entered the update_theme_visual method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme_visual', 
        "***** ENTERED THEMEADMIN UPDATE_THEME_VISUAL METHOD *****");
    
    # Check if the user is logged in and has admin role
    unless ($c->user_exists && grep { $_ eq 'admin' } @{$c->session->{roles}}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'update_theme_visual', 
            "Unauthorized access attempt by user: " . ($c->session->{username} || 'Guest'));
        $c->flash->{error} = "You must be an admin to update themes";
        $c->response->redirect($c->uri_for('/'));
        return;
    }
    
    # Get parameters
    my $theme_name = $c->request->params->{'theme_name'};
    my $theme_variables = $c->request->params->{'theme-variables'};
    
    # Decode JSON theme variables
    my $variables;
    eval {
        require JSON;
        $variables = JSON::decode_json($theme_variables);
    };
    
    if ($@ || !$variables) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_theme_visual', 
            "Error decoding theme variables: $@");
        $c->flash->{error} = "Error updating theme: Invalid data format";
        $c->response->redirect($c->uri_for('/themeadmin'));
        return;
    }
    
    # Update the theme with the new variables
    $self->update_theme_with_variables($c, $theme_name, $variables);
}

# Method to update theme with variables and regenerate CSS
sub update_theme_with_variables {
    my ($self, $c, $theme_name, $variables) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme_with_variables',
        "Updating theme $theme_name with variables");

    # Get the current theme data
    my $themes = $self->theme_manager->get_all_themes($c);

    # Check if theme exists
    if (!exists $themes->{$theme_name}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_theme_with_variables',
            "Theme not found: $theme_name");
        $c->flash->{error} = "Theme not found: $theme_name";
        return 0;
    }

    # Update theme variables
    $themes->{$theme_name}->{variables} = $variables;

    # Save updated themes to JSON file
    my $theme_defs_path = $c->path_to('root', 'static', 'config', 'theme_definitions.json');
    try {
        require JSON;
        my $json = JSON::encode_json($themes);
        File::Slurp::write_file($theme_defs_path, $json);

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme_with_variables',
            "Successfully updated theme definitions JSON");

        # Regenerate the CSS file for this theme
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme_with_variables',
            "Regenerating CSS for theme: $theme_name");

        # Generate CSS content
        my $theme_data = $themes->{$theme_name};
        my $css = "/* Theme: $theme_name */\n:root {\n";

        # Add variables
        foreach my $var_name (sort keys %{$theme_data->{variables}}) {
            $css .= "  --$var_name: " . $theme_data->{variables}{$var_name} . ";\n";
        }

        $css .= "}\n\n";

        # Add special styles if they exist
        if ($theme_data->{special_styles}) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme_with_variables',
                "Adding special styles for theme: $theme_name");

            foreach my $selector (keys %{$theme_data->{special_styles}}) {
                $css .= "$selector {\n";
                $css .= "  " . $theme_data->{special_styles}{$selector} . "\n";
                $css .= "}\n\n";
            }
        }

        # Write CSS file
        my $theme_dir = $c->path_to('root', 'static', 'css', 'themes');
        my $css_file = "$theme_dir/$theme_name.css";

        # Create theme directory if it doesn't exist
        unless (-d $theme_dir) {
            File::Path::make_path($theme_dir) or do {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_theme_with_variables',
                    "Failed to create themes directory: $!");
                $c->flash->{error} = "Failed to create themes directory: $!";
                return 0;
            };
        }

        # Write the CSS file
        File::Slurp::write_file($css_file, $css);

        # Also update the main CSS file for backward compatibility
        my $main_css_file = $c->path_to('root', 'static', 'css', "$theme_name.css");
        if (-f $main_css_file) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme_with_variables',
                "Updating main CSS file for backward compatibility: $main_css_file");
            File::Slurp::write_file($main_css_file, $css);
        }

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme_with_variables',
            "Successfully regenerated CSS for theme: $theme_name");

        $c->flash->{message} = "Theme $theme_name updated successfully";
        return 1;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_theme_with_variables',
            "Error updating theme: $_");
        $c->flash->{error} = "Error updating theme: $_";
        return 0;
    };
}

__PACKAGE__->meta->make_immutable;
1;
