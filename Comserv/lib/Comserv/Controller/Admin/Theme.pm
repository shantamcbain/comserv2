package Comserv::Controller::Admin::Theme;

use Moose;
use namespace::autoclean;
use Try::Tiny;
use File::Slurp;
use File::Path qw(make_path);
use Data::Dumper;
use Comserv::Util::Logging;
use Comserv::Util::ThemeManager;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has 'theme_manager' => (
    is => 'ro',
    default => sub { Comserv::Util::ThemeManager->new }
);

# Authentication check at the beginning of each request
sub begin : Private {
    my ($self, $c) = @_;

    # Log that we've entered the begin method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', "***** ENTERED ADMIN/THEME BEGIN METHOD *****");

    # Add debug information to the stash
    $c->stash->{debug_info} = {
        user_exists => $c->user_exists ? 'Yes' : 'No',
        session_id => $c->sessionid,
        session_data => $c->session,
        roles => $c->session->{roles},
    };

    # Log the debug information
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin',
        "Debug info: " . Dumper($c->stash->{debug_info}));

    # Check if the user is logged in
    if (!$c->user_exists && !$c->session->{user_id}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', "User not logged in, redirecting to login page");
        $c->flash->{error} = 'You must be logged in to access this page';
        $c->response->redirect($c->uri_for('/'));
        return 0; # Important: Return 0 to stop the request chain
    }

    # Check if the user has the admin role
    my $roles = $c->session->{roles};
    if (!defined $roles || ref $roles ne 'ARRAY' || !grep { $_ eq 'admin' } @$roles) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin',
            "User does not have admin role, redirecting to home page. Roles: " .
            (defined $roles ? (ref $roles eq 'ARRAY' ? join(", ", @$roles) : ref($roles)) : "undefined"));
        $c->flash->{error} = 'You do not have permission to access this page. Required role: admin.';
        $c->response->redirect($c->uri_for('/'));
        return 0; # Important: Return 0 to stop the request chain
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', "User has admin role, proceeding with request");
    return 1; # Important: Return 1 to allow the request to proceed
}

# Theme management page
sub index :Path('/admin/theme') :Args(0) {
    my ($self, $c) = @_;

    # Log that we've entered the index method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "***** ENTERED ADMIN/THEME INDEX METHOD *****");

    # Add debug information to the stash
    $c->stash->{debug_info} = {
        user_exists => $c->user_exists ? 'Yes' : 'No',
        session_id => $c->sessionid,
        session_data => $c->session,
        roles => $c->session->{roles},
    };

    # Log the debug information
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "Debug info: " . Dumper($c->stash->{debug_info}));

    # Check if the user is logged in
    if (!$c->user_exists && !$c->session->{user_id}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "User not logged in, redirecting to login page");
        $c->flash->{error} = 'You must be logged in to access this page';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Check if the user has the admin role
    my $roles = $c->session->{roles};
    if (!defined $roles || ref $roles ne 'ARRAY' || !grep { $_ eq 'admin' } @$roles) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
            "User does not have admin role, redirecting to home page. Roles: " .
            (defined $roles ? (ref $roles eq 'ARRAY' ? join(", ", @$roles) : ref($roles)) : "undefined"));
        $c->flash->{error} = 'You do not have permission to access this page. Required role: admin.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "User has admin role, proceeding with theme management");

    # Get current site from session or use a default
    my $site_name = $c->session->{SiteName} || 'bmast';
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Current site name: $site_name");

    # Create a simple site object without database access
    my $site = {
        id => 1,
        name => $site_name,
        description => 'Site managed by JSON configuration'
    };

    # Get the theme for this site from the theme manager
    $site->{theme} = $self->theme_manager->get_site_theme($c, $site_name) || 'default';
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Current theme: " . $site->{theme});

    # Create a simple sites array with just this site
    my @sites = ($site);

    # Get available themes
    my $themes = $self->theme_manager->get_all_themes($c);
    my @available_themes = sort keys %$themes;

    # Pass data to template
    $c->stash->{site} = $site;
    $c->stash->{sites} = \@sites;
    $c->stash->{available_themes} = \@available_themes;
    $c->stash->{theme_name} = $site->{theme};
    $c->stash->{template} = 'admin/theme/index.tt';
}

# Update theme
sub update_theme :Local {
    my ($self, $c) = @_;

    # Log that we've entered the update_theme method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme', "***** ENTERED ADMIN/THEME UPDATE_THEME METHOD *****");

    # Add debug information to the stash
    $c->stash->{debug_info} = {
        user_exists => $c->user_exists ? 'Yes' : 'No',
        session_id => $c->sessionid,
        session_data => $c->session,
        roles => $c->session->{roles},
    };

    # Log the debug information
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme',
        "Debug info: " . Dumper($c->stash->{debug_info}));

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

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme', "User has admin role, proceeding with theme update");

    # Get parameters
    my $site_id = $c->request->params->{site_id};
    my $theme = $c->request->params->{theme};

    # Log the parameters
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme',
        "Parameters - site_id: " . ($site_id // 'undef') . ", theme: " . ($theme // 'undef'));

    # Log all request parameters for debugging
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme',
        "All request parameters: " . Dumper($c->request->params));

    # Get site name from session or use a default
    my $site_name = $c->session->{SiteName} || 'bmast';

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme',
        "Updating theme for site: $site_name to $theme");

    # Update the theme in JSON mapping
    my $json_result = $self->theme_manager->set_site_theme($c, $site_name, $theme);

    if ($json_result) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme',
            "Successfully updated theme for site $site_name to $theme");

        # Force theme CSS regeneration
        $self->theme_manager->generate_all_theme_css($c);

        $c->flash->{message} = "Theme updated to $theme for site $site_name";
    } else {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_theme',
            "Failed to update theme for site $site_name to $theme");
        $c->flash->{error} = "Error updating theme. Please check server logs for details.";
    }

    # Redirect back to theme index
    $c->response->redirect($c->uri_for($self->action_for('index')));
}

# Create custom theme
sub create_custom_theme :Local {
    my ($self, $c) = @_;

    # Log that we've entered the create_custom_theme method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_custom_theme', "***** ENTERED ADMIN/THEME CREATE_CUSTOM_THEME METHOD *****");

    # Add debug information to the stash
    $c->stash->{debug_info} = {
        user_exists => $c->user_exists ? 'Yes' : 'No',
        session_id => $c->sessionid,
        session_data => $c->session,
        roles => $c->session->{roles},
    };

    # Log the debug information
    $self->logging->log_with_details($c, '
info', __FILE__, __LINE__, 'create_custom_theme',
        "Debug info: " . Dumper($c->stash->{debug_info}));

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

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_custom_theme', "User has admin role, proceeding with custom theme creation");

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

        # Update site theme
        try {
            $site->update({ theme => lc($site_name) . '_custom' });
            $self->theme_manager->set_site_theme($c, $site_name, lc($site_name) . '_custom');
            $self->theme_manager->generate_all_theme_css($c);
            $c->flash->{message} = "Custom theme created successfully for $site_name";
        } catch {
            # Check if the error is about the missing theme column
            if ($_ =~ /Unknown column 'theme'/) {
                $c->log->error("Theme column doesn't exist in sites table. Please run the add_theme_column.pl script.");

                # Update in JSON mapping only
                $self->theme_manager->set_theme_in_json($c, $site_name, lc($site_name) . '_custom');
                $self->theme_manager->generate_all_theme_css($c);
                
                $c->flash->{message} = "Custom theme CSS created, but database update is required to apply it. Please run the add_theme_column.pl script.";
            } else {
                $c->flash->{error} = "Error updating site theme: $_";
            }
        };
    } catch {
        $c->flash->{error} = "Error creating custom theme: $_";
    };
    
    # Redirect back to theme index
    $c->response->redirect($c->uri_for($self->action_for('index')));
}

__PACKAGE__->meta->make_immutable;
1;
