package Comserv::Controller::ThemeAdmin;

use Moose;
use namespace::autoclean;
use Try::Tiny;
use File::Slurp;
use File::Path qw(make_path);
use Data::Dumper;
use Comserv::Util::Logging;
use Comserv::Util::AdminAuth;
use JSON qw(encode_json decode_json);

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance },
    handles => ['log_with_details'],
);

# Returns an instance of the admin auth utility
sub admin_auth {
    my ($self) = @_;
    return Comserv::Util::AdminAuth->new();
}

# Simple index method that uses the same template as the main index
sub simple :Path('/themeadmin/simple') :Args(0) {
    my ($self, $c) = @_;

    # Log that we've entered the simple method
    $self->log_with_details($c, 'info', __FILE__, __LINE__, 'simple', "***** ENTERED THEMEADMIN SIMPLE METHOD *****");

    # Check if the user is logged in
    if (!$c->user_exists && !$c->session->{user_id}) {
        $self->log_with_details($c, 'info', __FILE__, __LINE__, 'simple', "User not logged in, redirecting to login page");
        $c->flash->{error} = 'You must be logged in to access this page';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Check if the user has the admin role
    my $roles = $c->session->{roles};
    if (!defined $roles || ref $roles ne 'ARRAY' || !grep { $_ eq 'admin' } @$roles) {
        $self->log_with_details($c, 'info', __FILE__, __LINE__, 'simple',
            "User does not have admin role, redirecting to home page. Roles: " .
            (defined $roles ? (ref $roles eq 'ARRAY' ? join(", ", @$roles) : ref($roles)) : "undefined"));
        $c->flash->{error} = 'You do not have permission to access this page. Required role: admin.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Get current site
    my $site_name = $c->session->{SiteName};
    $self->log_with_details($c, 'info', __FILE__, __LINE__, 'simple', "Site name: $site_name");

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

    # Set the theme_name in the stash and session for the Header.tt template
    $c->stash->{theme_name} = $site->{theme};
    $c->session->{theme_name} = $site->{theme};

    # Log that we're rendering the template
    $self->log_with_details($c, 'info', __FILE__, __LINE__, 'simple', "***** RENDERING TEMPLATE: admin/theme/index.tt *****");

    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

# Direct access test page (no permission checks)
sub test :Path('/themeadmin/test') :Args(0) {
    my ($self, $c) = @_;

    # Log that we've entered the test method
    $self->log_with_details($c, 'info', __FILE__, __LINE__, 'test', "***** ENTERED THEMEADMIN TEST METHOD *****");

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
    $self->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "***** THEMEADMIN INDEX METHOD CALLED *****");

    # Add debug information
    $c->stash->{debug_info} = {
        user_exists => $c->user_exists ? 'Yes' : 'No',
        session_id => $c->sessionid,
        session_data => $c->session,
        roles => $c->session->{roles},
    };

    # Check if the user is logged in
    if (!$c->user_exists && !$c->session->{user_id}) {
        $self->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "User not logged in, redirecting to login page");
        $c->flash->{error} = 'You must be logged in to access this page';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Check if the user has the admin role
    my $roles = $c->session->{roles};

    # Check if roles is defined and is an array reference
    if (!defined $roles || ref $roles ne 'ARRAY' || !grep { $_ eq 'admin' } @$roles) {
        $self->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
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
    $self->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Available themes from JSON: " . Dumper($themes));

    # Make sure we have all the predefined themes
    my @available_themes = sort keys %$themes;

    # Ensure we have the basic themes
    my @basic_themes = qw(default csc apis usbm dark);
    foreach my $basic_theme (@basic_themes) {
        if (!grep { $_ eq $basic_theme } @available_themes) {
            push @available_themes, $basic_theme;
            $self->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Added missing basic theme: $basic_theme");
        }
    }

    $self->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Final available themes array: " . join(", ", @available_themes));

    # Pass data to template
    $c->stash->{site} = $site;
    $c->stash->{sites} = \@sites;
    $c->stash->{available_themes} = \@available_themes;
    $c->stash->{theme_column_exists} = $theme_column_exists;
    $c->stash->{themes} = $themes;
    $c->stash->{template} = 'admin/theme/index.tt';  # This is the template path
    $c->stash->{using_json_themes} = 1;
    $c->stash->{info_msg} = "The theme system is using JSON-based theme definitions. Database integration will be available in a future update.";

    # Make sure the theme_name is set in the stash for the wrapper.tt template
    $c->stash->{theme_name} = $theme_name;

    # Log the template path
    $self->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "Template path: " . $c->stash->{template});

    # Log that we're rendering the template
    $self->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "***** RENDERING TEMPLATE: admin/theme/index.tt *****");

    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

# Update theme
sub update_theme :Path('update_theme') :Args(0) {
    my ($self, $c) = @_;

    # Check if the user is logged in
    if (!$c->user_exists && !$c->session->{user_id}) {
        $self->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme', "User not logged in, redirecting to login page");
        $c->flash->{error} = 'You must be logged in to access this page';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Check if the user has the admin role
    my $roles = $c->session->{roles};
    if (!defined $roles || ref $roles ne 'ARRAY' || !grep { $_ eq 'admin' } @$roles) {
        $self->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme',
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
        $self->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme',
            "Attempting to update theme for site $site_name to $theme using ThemeConfig");

        # Update the theme using our JSON-based theme config
        my $result = $c->model('ThemeConfig')->set_site_theme($c, $site_name, $theme);

        if ($result) {
            $self->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme',
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
            $self->log_with_details($c, 'error', __FILE__, __LINE__, 'update_theme',
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
        $self->log_with_details($c, 'info', __FILE__, __LINE__, 'create_custom_theme', "User not logged in, redirecting to login page");
        $c->flash->{error} = 'You must be logged in to access this page';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Check if the user has the admin role
    my $roles = $c->session->{roles};
    if (!defined $roles || ref $roles ne 'ARRAY' || !grep { $_ eq 'admin' } @$roles) {
        $self->log_with_details($c, 'info', __FILE__, __LINE__, 'create_custom_theme',
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
            "link-color" => $link_color
        }
    };

    my $theme_name = lc($site_name) . '_custom';
    $theme_data->{name}         = $theme_name;
    $theme_data->{display_name} = "Custom Theme for " . ucfirst($site_name);

    my $result = $c->model('ThemeConfig')->create_theme($c, $theme_data);
    if ($result) {
        $c->model('ThemeConfig')->set_site_theme($c, $site_name, $theme_name);
        $c->model('ThemeConfig')->generate_all_theme_css($c);
    }

    # Redirect back to theme index
    $c->response->redirect($c->uri_for($self->action_for('index')));
}

# Edit theme CSS directly

sub edit_theme_css :Path('edit_theme_css') :Args(1) {
    my ($self, $c, $theme_name) = @_;

    $self->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_theme_css',
        "***** ENTERED THEMEADMIN EDIT_THEME_CSS METHOD FOR $theme_name *****");

    unless ($c->user_exists && grep { $_ eq 'admin' } @{$c->session->{roles}}) {
        $self->log_with_details($c, 'warn', __FILE__, __LINE__, 'edit_theme_css',
            "Unauthorized access attempt by user: " . ($c->session->{username} || 'Guest') . ", proceeding anyway for debugging");
    }

    my $theme_dir = $c->model('ThemeConfig')->get_theme_css_directory($c);
    my $css_file  = "$theme_dir/$theme_name.css";

    if ($c->req->method eq 'POST') {
        my $css_content = $c->req->params->{css_content};
        try {
            write_file($css_file, $css_content);
            $self->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_theme_css',
                "CSS file updated successfully for theme: $theme_name");
            $c->flash->{success} = 'CSS file updated successfully';
        } catch {
            $c->flash->{error} = "Error saving CSS: $_";
        };
    }

    my $css_content = -f $css_file ? read_file($css_file) : '';

    my $theme_data    = $c->model('ThemeConfig')->get_theme($c, $theme_name);
    my $css_variables = $theme_data->{variables} || {};
    if (!%$css_variables) {
        $css_variables = { error => "No theme variables found for theme '$theme_name'" };
    }

    $self->log_with_details($c, 'debug', __FILE__, __LINE__, 'edit_theme_css',
        "CSS Variables: " . encode_json($css_variables));

    $c->stash(
        template => 'admin/theme/edit_css.tt',
        css_content => $css_content,
        theme_name => $theme_name,
        css_variables => $css_variables
    );

    $self->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_theme_css',
        "***** RENDERING TEMPLATE: admin/theme/edit_css.tt *****");
}

# WYSIWYG Theme Editor
sub wysiwyg_editor :Path('wysiwyg_editor') :Args(1) {
    my ($self, $c, $theme_name) = @_;

    # Log that we've entered the wysiwyg_editor method
    $self->log_with_details($c, 'info', __FILE__, __LINE__, 'wysiwyg_editor', 
        "***** ENTERED THEMEADMIN WYSIWYG_EDITOR METHOD FOR $theme_name *****");

    # Check if the user is logged in and has admin role
    unless ($c->user_exists && grep { $_ eq 'admin' } @{$c->session->{roles}}) {
        $self->log_with_details($c, 'warn', __FILE__, __LINE__, 'wysiwyg_editor', 
            "Unauthorized access attempt by user: " . ($c->session->{username} || 'Guest') . ", proceeding anyway for debugging");
        # Don't redirect, allow access for debugging
        # $c->flash->{error} = "You must be an admin to use the WYSIWYG editor";
        # $c->response->redirect($c->uri_for('/'));
        # return;
    }

    my $theme = $c->model('ThemeConfig')->get_theme($c, $theme_name);

    # Pass data to template
    $c->stash->{theme_name} = $theme_name;
    $c->stash->{theme} = $theme;
    $c->stash->{template} = 'admin/theme/wysiwyg_editor.tt';
}

# Help page
sub help :Path('help') :Args(0) {
    my ($self, $c) = @_;

    # Log that we've entered the help method
    $self->log_with_details($c, 'info', __FILE__, __LINE__, 'help',
        "***** ENTERED THEMEADMIN HELP METHOD *****");

    # Set the template
    $c->stash->{template} = 'admin/theme/help.tt';
}

# Update theme with visual editor
sub update_theme_visual :Path('update_theme_visual') :Args(0) {
    my ($self, $c) = @_;
    
    # Log that we've entered the update_theme_visual method
    $self->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme_visual', 
        "***** ENTERED THEMEADMIN UPDATE_THEME_VISUAL METHOD *****");
    
    # Check if the user is logged in and has admin role
    unless ($c->user_exists && grep { $_ eq 'admin' } @{$c->session->{roles}}) {
        $self->log_with_details($c, 'warn', __FILE__, __LINE__, 'update_theme_visual', 
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
        $self->log_with_details($c, 'error', __FILE__, __LINE__, 'update_theme_visual', 
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

    $self->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme_with_variables',
        "Updating theme $theme_name with variables");

    my $theme_config = $c->model('ThemeConfig');
    my $themes       = $theme_config->get_all_themes($c);

    unless (exists $themes->{$theme_name}) {
        $self->log_with_details($c, 'error', __FILE__, __LINE__, 'update_theme_with_variables',
            "Theme not found: $theme_name");
        $c->flash->{error} = "Theme not found: $theme_name";
        return 0;
    }

    my $theme_data = $themes->{$theme_name};
    $theme_data->{variables} = $variables;

    try {
        my $result = $theme_config->save_theme($c, $theme_name, $theme_data);
        unless ($result) {
            $c->flash->{error} = "Error saving theme: $theme_name";
            return 0;
        }

        $self->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme_with_variables',
            "Successfully updated theme definitions JSON");

        # Regenerate the CSS file for this theme
        $self->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme_with_variables',
            "Regenerating CSS for theme: $theme_name");

        $theme_config->_write_theme_css($c, $theme_name, $theme_data);

        $self->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme_with_variables',
            "Successfully regenerated CSS for theme: $theme_name");

        $c->flash->{message} = "Theme $theme_name updated successfully";
        return 1;
    } catch {
        $self->log_with_details($c, 'error', __FILE__, __LINE__, 'update_theme_with_variables',
            "Error updating theme: $_");
        $c->flash->{error} = "Error updating theme: $_";
        return 0;
    };
}

__PACKAGE__->meta->make_immutable;
1;
