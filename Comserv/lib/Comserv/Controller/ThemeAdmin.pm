package Comserv::Controller::ThemeAdmin;

use Moose;
use namespace::autoclean;
use Try::Tiny;
use File::Slurp;
use File::Path qw(make_path);
use Data::Dumper;

BEGIN { extends 'Catalyst::Controller'; }

# Theme management page
sub index :Path :Args(0) {
    my ($self, $c) = @_;
    
    # Add debug information
    $c->stash->{debug_info} = {
        user_exists => $c->user_exists ? 'Yes' : 'No',
        session_id => $c->sessionid,
        session_data => $c->session,
        roles => $c->session->{roles},
    };
    
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
    
    # Get current site
    my $site_name = $c->session->{SiteName};
    my $site;

    # Try to get the site with error handling for missing theme column
    try {
        $site = $c->model('DBEncy')->resultset('Site')->find({ name => $site_name });
    } catch {
        # If there's an error about the theme column
        if ($_ =~ /Unknown column 'me\.theme'/) {
            # Log the error
            $c->log->error("Theme column doesn't exist in sites table. Please run the add_theme_column.pl script.");

            # Get site without theme column
            $site = $c->model('DBEncy')->resultset('Site')->find(
                { name => $site_name },
                { columns => [qw(id name description)] } # Only select columns that exist
            );

            # Add a default theme property
            $site->{theme} = 'default';

            # Add error message to stash with link to add_theme_column
            $c->stash->{error_msg} = "The theme feature requires a database update. <a href='" . $c->uri_for('/admin/add_theme_column') . "'>Click here to add the theme column</a>.";
        } else {
            # For other errors, re-throw
            die $_;
        }
    };

    # If site doesn't have a theme, set to default
    $site->{theme} = $site->{theme} || 'default';
    
    # Get all sites for admin
    my @sites;
    if (lc($site_name) eq 'csc') {
        @sites = $c->model('DBEncy')->resultset('Site')->all;
    } else {
        @sites = ($site);
    }
    
    # Pass data to template
    $c->stash->{site} = $site;
    $c->stash->{sites} = \@sites;
    $c->stash->{template} = 'admin/theme/index.tt';
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

        # Update site theme
        try {
            $site->update({ theme => $theme });
            $c->flash->{message} = "Theme updated to $theme for site " . $site->name;
        } catch {
            # Check if the error is about the missing theme column
            if ($_ =~ /Unknown column 'theme'/) {
                $c->log->error("Theme column doesn't exist in sites table. Please run the add_theme_column.pl script.");
                $c->flash->{error} = "The theme feature requires a database update. Please contact the administrator.";
            } else {
                $c->flash->{error} = "Error updating theme: $_";
            }
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

        # Update site theme
        try {
            $site->update({ theme => lc($site_name) . '_custom' });
            $c->flash->{message} = "Custom theme created successfully for $site_name";
        } catch {
            # Check if the error is about the missing theme column
            if ($_ =~ /Unknown column 'theme'/) {
                $c->log->error("Theme column doesn't exist in sites table. Please run the add_theme_column.pl script.");
                $c->flash->{message} = "Custom theme CSS created, but database update is required to apply it. Please contact the administrator.";
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