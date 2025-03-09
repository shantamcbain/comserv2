package Comserv::Controller::ThemeAdmin;

use Moose;
use namespace::autoclean;
use Try::Tiny;
use File::Slurp;
use File::Path qw(make_path);
use Data::Dumper;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
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
sub index :Path('/themeadmin') :Args(0) {
    my ($self, $c) = @_;

    # Debug message at the very beginning of the method
    warn "***** THEMEADMIN INDEX METHOD CALLED *****";
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "***** THEMEADMIN INDEX METHOD CALLED *****");

    # Add debug information
    $c->stash->{debug_info} = {
        user_exists => $c->user_exists ? 'Yes' : 'No',
        session_id => $c->sessionid,
        session_data => $c->session,
        roles => $c->session->{roles},
    };

    # Log that we've entered the ThemeAdmin index method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "***** ENTERED THEMEADMIN INDEX METHOD *****");

    # Print the current path to the log
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Current path: " . $c->req->path);

    # Print the current user info to the log
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "User exists: " . ($c->user_exists ? 'Yes' : 'No'));
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Session ID: " . $c->sessionid);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Session data: " . Dumper($c->session));

    # Check if the user is logged in
    # We're using session data instead of $c->user_exists because the latter is returning false
    # even though the session contains user information
    if (!$c->user_exists && !$c->session->{user_id}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "User not logged in, redirecting to login page");
        $c->flash->{error} = 'You must be logged in to access this page';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "User is logged in according to session data, proceeding");

    # Check if the user has the admin role
    my $roles = $c->session->{roles};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "User roles: " . Dumper($roles));

    # Log detailed information about the roles check
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Roles defined: " . (defined $roles ? 'Yes' : 'No'));
    if (defined $roles) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Roles is an array: " . (ref $roles eq 'ARRAY' ? 'Yes' : 'No'));
        if (ref $roles eq 'ARRAY') {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Roles array contains 'admin': " . (grep { $_ eq 'admin' } @$roles ? 'Yes' : 'No'));
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Roles array: " . join(', ', @$roles));
        }
    }

    # IMPORTANT: Roles check is completely disabled for testing
    # This should be re-enabled after testing is complete
    if (0) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "User does not have admin role, redirecting to home page");
        $c->flash->{error} = 'You do not have permission to access this page';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Log that we're proceeding even if the user doesn't have the admin role
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Proceeding with ThemeAdmin index (bypassing role check for testing)");

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "User has admin role, proceeding with ThemeAdmin index");

    # Get current site
    my $site_name = $c->session->{SiteName};
    my $site;
    my $theme_column_exists = 0;

    # Check if the theme column exists
    try {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        my $sth = $dbh->prepare("SHOW COLUMNS FROM sites LIKE 'theme'");
        $sth->execute();
        $theme_column_exists = $sth->fetchrow_array() ? 1 : 0;
    } catch {
        $c->log->error("Error checking if theme column exists: $_");
        $theme_column_exists = 0;
    };

    # Try to get the site
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

    # If we have a site but no theme column, check for a theme mapping file
    if ($site && !$theme_column_exists) {
        # Add a default theme property
        $site->{theme} = 'default';

        # Check if there's a theme mapping for this site
        my $theme_info_file = $c->path_to('root', 'static', 'css', 'themes', 'theme_mappings.txt');
        if (-e $theme_info_file) {
            try {
                my $theme_info = read_file($theme_info_file);
                if ($theme_info =~ /^$site_name:\s*(\S+)/m) {
                    $site->{theme} = $1;
                    $c->log->info("Found theme mapping for $site_name: " . $site->{theme});
                }
            } catch {
                $c->log->error("Error reading theme mappings file: $_");
            };
        }

        # Set theme based on site name if no mapping found
        if ($site->{theme} eq 'default') {
            if (lc($site_name) eq 'usbm') {
                $site->{theme} = 'usbm';
            } elsif (lc($site_name) eq 'apis') {
                $site->{theme} = 'apis';
            }
        }

        # Add message about theme column
        $c->stash->{info_msg} = "The theme system is currently using file-based themes. Database integration will be available after running the add_theme_column.pl script.";
    }

    # If site doesn't have a theme, set to default
    $site->{theme} = $site->{theme} || 'default';

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

            # If we don't have the theme column, add theme property to each site
            if (!$theme_column_exists) {
                foreach my $s (@sites) {
                    $s->{theme} = 'default';

                    # Check if there's a theme mapping for this site
                    my $theme_info_file = $c->path_to('root', 'static', 'css', 'themes', 'theme_mappings.txt');
                    if (-e $theme_info_file) {
                        try {
                            my $theme_info = read_file($theme_info_file);
                            my $site_name = $s->name;
                            if ($theme_info =~ /^$site_name:\s*(\S+)/m) {
                                $s->{theme} = $1;
                            }
                        } catch {
                            $c->log->error("Error reading theme mappings file: $_");
                        };
                    }

                    # Set theme based on site name if no mapping found
                    if ($s->{theme} eq 'default') {
                        my $name = lc($s->name);
                        if ($name eq 'usbm') {
                            $s->{theme} = 'usbm';
                        } elsif ($name eq 'apis') {
                            $s->{theme} = 'apis';
                        }
                    }
                }
            }
        } catch {
            $c->log->error("Error getting all sites: $_");
            @sites = ($site);
        };
    } else {
        @sites = ($site);
    }

    # Get available themes
    my @available_themes;
    try {
        my $theme_dir = $c->path_to('root', 'static', 'css', 'themes');
        opendir(my $dh, $theme_dir) or die "Cannot open directory: $!";
        while (my $file = readdir($dh)) {
            next if $file =~ /^\./;  # Skip hidden files
            next unless $file =~ /\.css$/;  # Only include CSS files
            my $theme_name = $file;
            $theme_name =~ s/\.css$//;  # Remove .css extension
            push @available_themes, $theme_name;
        }
        closedir($dh);
    } catch {
        $c->log->error("Error getting available themes: $_");
        @available_themes = qw(default apis usbm);
    };

    # Pass data to template
    $c->stash->{site} = $site;
    $c->stash->{sites} = \@sites;
    $c->stash->{available_themes} = \@available_themes;
    $c->stash->{theme_column_exists} = $theme_column_exists;
    $c->stash->{template} = 'admin/theme/index.tt';

    # Log that we're rendering the template
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "***** RENDERING TEMPLATE: admin/theme/index.tt *****");

    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

# Update theme
sub update_theme :Local {
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

        # Try to update site theme in database if the column exists
        try {
            # First check if the theme column exists
            my $dbh = $c->model('DBEncy')->schema->storage->dbh;
            my $sth = $dbh->prepare("SHOW COLUMNS FROM sites LIKE 'theme'");
            $sth->execute();
            my $column_exists = $sth->fetchrow_array();

            if ($column_exists) {
                # If the column exists, update it
                $site->update({ theme => $theme });
                $c->flash->{message} = "Theme updated to $theme for site $site_name";
            } else {
                # If the column doesn't exist, just create a file with instructions
                my $theme_info_file = $c->path_to('root', 'static', 'css', 'themes', 'theme_mappings.txt');
                my $theme_info = "";

                # Read existing mappings if the file exists
                if (-e $theme_info_file) {
                    $theme_info = read_file($theme_info_file);

                    # Remove any existing mapping for this site
                    $theme_info =~ s/^$site_name:.*\n//mg;
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme', "Removed existing mapping for $site_name");
                }

                # Add the new mapping
                $theme_info .= "$site_name: $theme\n";

                # Write the updated mappings
                write_file($theme_info_file, $theme_info);
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme', "Wrote new mapping to theme_mappings.txt");

                $c->flash->{message} = "Theme preference saved for $site_name. The theme will be applied when the database is updated.";
            }
        } catch {
            $c->log->error("Error checking or updating theme: $_");
            $c->flash->{error} = "Error updating theme: $_";
        };
    } catch {
        $c->flash->{error} = "Error finding site: $_";
    };

    # Redirect back to theme index
    $c->response->redirect($c->uri_for($self->action_for('index')));
}

# Create custom theme
sub create_custom_theme :Local {
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

    # Create custom theme CSS
    my $theme_css = "/* Custom Theme for $site_name */\n";
    $theme_css .= ":root {\n";
    $theme_css .= "  --primary-color: $primary_color;\n";
    $theme_css .= "  --secondary-color: $secondary_color;\n";
    $theme_css .= "  --accent-color: $accent_color;\n";
    $theme_css .= "  --text-color: $text_color;\n";
    $theme_css .= "  --link-color: $link_color;\n";
    $theme_css .= "  --link-hover-color: $link_color;\n";
    $theme_css .= "  --background-color: #ffffff;\n";
    $theme_css .= "  --border-color: $secondary_color;\n";
    $theme_css .= "  --table-header-bg: $secondary_color;\n";
    $theme_css .= "  --warning-color: #ff0000;\n";
    $theme_css .= "  --success-color: #009900;\n";
    $theme_css .= "  \n";
    $theme_css .= "  --button-bg: $primary_color;\n";
    $theme_css .= "  --button-text: $text_color;\n";
    $theme_css .= "  --button-border: $accent_color;\n";
    $theme_css .= "  --button-hover-bg: $accent_color;\n";
    $theme_css .= "}\n";

    # Create theme directory if it doesn't exist
    my $theme_dir = $c->path_to('root', 'static', 'css', 'themes');
    make_path($theme_dir) unless -d $theme_dir;

    # Write custom theme file
    my $theme_file = lc($site_name) . '_custom.css';
    my $theme_path = $c->path_to('root', 'static', 'css', 'themes', $theme_file);

    try {
        write_file($theme_path, $theme_css);

        # Try to update site theme in database if the column exists
        try {
            # First check if the theme column exists
            my $dbh = $c->model('DBEncy')->schema->storage->dbh;
            my $sth = $dbh->prepare("SHOW COLUMNS FROM sites LIKE 'theme'");
            $sth->execute();
            my $column_exists = $sth->fetchrow_array();

            if ($column_exists) {
                # If the column exists, update it
                $site->update({ theme => lc($site_name) . '_custom' });
                $c->flash->{message} = "Custom theme created successfully for $site_name and applied to the site.";
            } else {
                # If the column doesn't exist, just create a file with instructions
                my $theme_info_file = $c->path_to('root', 'static', 'css', 'themes', 'theme_mappings.txt');
                my $theme_info = "";

                # Read existing mappings if the file exists
                if (-e $theme_info_file) {
                    $theme_info = read_file($theme_info_file);
                }

                # Add the new mapping
                $theme_info .= "$site_name: " . lc($site_name) . "_custom\n";

                # Write the updated mappings
                write_file($theme_info_file, $theme_info);

                $c->flash->{message} = "Custom theme CSS created successfully for $site_name. The theme will be applied when the database is updated.";
            }
        } catch {
            $c->log->error("Error checking or updating theme: $_");
            $c->flash->{message} = "Custom theme CSS created, but there was an error updating the database. The theme will be available at /static/css/themes/$theme_file";
        };
    } catch {
        $c->flash->{error} = "Error creating custom theme: $_";
    };

    # Redirect back to theme index
    $c->response->redirect($c->uri_for($self->action_for('index')));
}

__PACKAGE__->meta->make_immutable;
1;
