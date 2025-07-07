package Comserv::Controller::Admin::Theme;

use Moose;
use namespace::autoclean;
use Try::Tiny;
use File::Slurp;
use File::Path qw(make_path);
use Data::Dumper;
use Comserv::Util::Logging;
use JSON;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# Utility methods (moved from ThemeUtils)

# Extract CSS variables from a CSS string
sub extract_css_variables {
    my ($self, $css_content) = @_;

    my %variables;

    # Match CSS variable declarations in the format: --variable-name: value;
    while ($css_content =~ /--([a-zA-Z0-9-]+)\s*:\s*([^;]+);/g) {
        my $name = $1;
        my $value = $2;
        $value =~ s/^\s+|\s+$//g; # Trim whitespace
        $variables{$name} = $value;
    }

    return \%variables;
}

# Merge CSS variables from multiple sources
sub merge_css_variables {
    my ($self, @variable_sets) = @_;

    my %merged;

    # Process each set of variables
    foreach my $vars (@variable_sets) {
        next unless $vars && ref($vars) eq 'HASH';

        # Add each variable to the merged set
        foreach my $key (keys %$vars) {
            $merged{$key} = $vars->{$key};
        }
    }

    return \%merged;
}

# Check if a color is dark (for determining text color)
sub is_dark_color {
    my ($self, $color) = @_;

    # Default to false if no color provided
    return 0 unless $color;

    # Handle hex colors
    if ($color =~ /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i) {
        my $r = hex($1);
        my $g = hex($2);
        my $b = hex($3);

        # Calculate perceived brightness (YIQ formula)
        my $brightness = (($r * 299) + ($g * 587) + ($b * 114)) / 1000;

        # Return true if the color is dark (brightness < 128)
        return $brightness < 128;
    }

    # Default to false for unknown color formats
    return 0;
}

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

    # Get current site from session or use a default
    my $site_name = $c->session->{SiteName} || 'bmast';
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Current site name: $site_name");

    # Create a simple site object without database access
    my $site = {
        id => 1,
        name => $site_name,
        description => 'Site managed by JSON configuration'
    };

    # Get the theme for this site from the theme model
    $site->{theme} = $c->model('ThemeConfig')->get_site_theme($c, $site_name) || 'default';
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Current theme: " . $site->{theme});

    # Create a simple sites array with just this site
    my @sites = ($site);

    # Get available themes
    my $themes = $c->model('ThemeConfig')->get_all_themes($c);
    my @available_themes = sort keys %$themes;

    # Pass data to template
    $c->stash->{site} = $site;
    $c->stash->{sites} = \@sites;
    $c->stash->{available_themes} = \@available_themes;
    $c->stash->{themes} = $themes;
    $c->stash->{theme_name} = $site->{theme};
    $c->stash->{template} = 'admin/theme/index.tt';
}

# Update theme
sub update_theme :Path('/admin/theme/update') :Args(0) {
    my ($self, $c) = @_;

    # Log that we've entered the update_theme method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme', "***** ENTERED ADMIN/THEME UPDATE_THEME METHOD *****");

    # Get parameters
    my $site_id = $c->request->params->{site_id};
    my $theme = $c->request->params->{theme};

    # Log the parameters
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme',
        "Parameters - site_id: " . ($site_id // 'undef') . ", theme: " . ($theme // 'undef'));

    # Get site name from session or use a default
    my $site_name = $c->session->{SiteName} || 'bmast';

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme',
        "Updating theme for site: $site_name to $theme");

    # Update the theme in JSON mapping
    my $json_result = $c->model('ThemeConfig')->set_site_theme($c, $site_name, $theme);

    if ($json_result) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme',
            "Successfully updated theme for site $site_name to $theme");

        # Force theme CSS regeneration
        $c->model('ThemeConfig')->generate_all_theme_css($c);

        $c->flash->{message} = "Theme updated to $theme for site $site_name";
    } else {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_theme',
            "Failed to update theme for site $site_name to $theme");
        $c->flash->{error} = "Error updating theme. Please check server logs for details.";
    }

    # Redirect back to theme index
    $c->response->redirect($c->uri_for($self->action_for('index')));
}

# Edit theme CSS
sub edit :Path('/admin/theme/edit') :Args(1) {
    my ($self, $c, $theme_name) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit', "Editing CSS for theme: $theme_name");

    my $theme_dir = $c->model('ThemeConfig')->get_theme_css_directory($c);
    my $css_file = "$theme_dir/$theme_name.css";

    if ($c->req->method eq 'POST') {
        my $css_content = $c->req->params->{css_content};
        try {
            write_file($css_file, $css_content);
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit', "CSS file updated successfully for theme: $theme_name");
            $c->flash->{success} = 'CSS file updated successfully';
        } catch {
            $c->flash->{error} = "Error saving CSS: $_";
        };
    }

    my $css_content = -f $css_file ? read_file($css_file) : '';

    # Get theme data from the model
    my $theme_data = $c->model('ThemeConfig')->get_theme($c, $theme_name);
    my $theme_variables = $theme_data->{variables} || {};

    # If no variables were found, set an error
    if (scalar(keys %$theme_variables) == 0) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'edit',
            "No theme variables found for theme '$theme_name'");
        $theme_variables = { error => "No theme variables found for theme '$theme_name'" };
    }

    # Get list of available images
    my @image_dirs = ('BMaster', 'apis', 'csc', 'usbm');
    my %available_images;

    foreach my $dir (@image_dirs) {
        my $image_path = $c->path_to('root', 'static', 'images', $dir);
        if (-d $image_path) {
            my @images = glob("$image_path/*.{jpg,jpeg,png,gif}");
            $available_images{$dir} = [map { my $file = $_; $file =~ s/.*\/([^\/]+)$/$1/; $file } @images];
        }
    }

    # Log the variables for debugging
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit',
        "Theme variables: " . join(", ", keys %$theme_variables));

    # Log the theme data for debugging
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit',
        "Theme data keys: " . join(", ", keys %$theme_data));

    # Log the CSS content for debugging
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit',
        "CSS content length: " . length($css_content));

    # Log available images
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit',
        "Available image directories: " . join(", ", keys %available_images));

    $c->stash(
        template => 'admin/theme/edit_css.tt',
        css_content => $css_content,
        theme_name => $theme_name,
        theme_variables => $theme_variables,
        theme_data => $theme_data,
        available_images => \%available_images
    );
}

# Create custom theme
sub create_custom_theme :Path('/admin/theme/create_custom') :Args(0) {
    my ($self, $c) = @_;

    # Log that we've entered the create_custom_theme method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_custom_theme', "***** ENTERED ADMIN/THEME CREATE_CUSTOM_THEME METHOD *****");

    # Get parameters
    my $site_id = $c->request->params->{site_id};
    my $primary_color = $c->request->params->{primary_color};
    my $secondary_color = $c->request->params->{secondary_color};
    my $accent_color = $c->request->params->{accent_color};
    my $text_color = $c->request->params->{text_color};
    my $link_color = $c->request->params->{link_color};

    # Get site name from session or use a default
    my $site_name = $c->session->{SiteName} || 'bmast';

    # Create theme data
    my $theme_data = {
        name => "Custom Theme for $site_name",
        description => "Custom theme created for $site_name",
        variables => {
            "primary-color" => $primary_color,
            "secondary-color" => $secondary_color,
            "accent-color" => $accent_color,
            "text-color" => $text_color,
            "link-color" => $link_color,
            "link-hover-color" => $link_color,
            "background-color" => "#ffffff",
            "border-color" => $secondary_color,
            "table-header-bg" => $secondary_color,
            "warning-color" => "#ff0000",
            "success-color" => "#009900",
            "button-bg" => $primary_color,
            "button-text" => $text_color,
            "button-border" => $accent_color,
            "button-hover-bg" => $accent_color
        }
    };

    # Create the custom theme
    my $theme_name = lc($site_name) . '_custom';
    my $result = $c->model('ThemeConfig')->create_theme($c, $theme_name, $theme_data);

    if ($result) {
        # Set the site to use the new theme
        $c->model('ThemeConfig')->set_site_theme($c, $site_name, $theme_name);

        # Generate CSS files
        $c->model('ThemeConfig')->generate_all_theme_css($c);
        
        $c->flash->{message} = "Custom theme created successfully for $site_name";
    } else {
        $c->flash->{error} = "Error creating custom theme. Please check server logs for details.";
    }

    # Redirect back to theme index
    $c->response->redirect($c->uri_for($self->action_for('index')));
}

# Update CSS for a theme
sub update_css :Path('/admin/theme/update_css') :Args(1) {
    my ($self, $c, $theme_name) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_css', "Updating CSS for theme: $theme_name");

    # Get the CSS content from the form
    my $css_content = $c->req->params->{css_content};

    # Log the CSS content length for debugging
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_css',
        "CSS content length: " . (defined $css_content ? length($css_content) : 'undefined'));

    # Get the theme directory
    my $theme_dir = $c->model('ThemeConfig')->get_theme_css_directory($c);
    my $css_file = "$theme_dir/$theme_name.css";

    # Log the file path for debugging
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_css',
        "CSS file path: $css_file");

    # Make sure the theme directory exists
    unless (-d $theme_dir) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_css',
            "Creating theme directory: $theme_dir");
        make_path($theme_dir);
    }

    # Save the CSS content
    try {
        # Write the CSS content to the file
        write_file($css_file, $css_content);

        # Log success
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_css',
            "CSS file updated successfully for theme: $theme_name");

        # Set success message
        $c->flash->{message} = "CSS file updated successfully";

        # Also update the theme in the theme_definitions.json if needed
        my $theme = $c->model('ThemeConfig')->get_theme($c, $theme_name);
        if ($theme) {
            # Extract CSS variables from the CSS content
            my $css_variables = $self->extract_css_variables($css_content);

            # Log the extracted variables
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_css',
                "Extracted " . scalar(keys %$css_variables) . " CSS variables from the content");

            # If we found variables, update the theme definition
            if (scalar(keys %$css_variables) > 0) {
                # Update the theme variables
                foreach my $var_name (keys %$css_variables) {
                    $theme->{variables}->{$var_name} = $css_variables->{$var_name};
                }

                # Save the updated theme
                my $result = $c->model('ThemeConfig')->update_theme($c, $theme_name, $theme);

                if ($result) {
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_css',
                        "Theme definition updated with CSS variables");
                } else {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'update_css',
                        "Failed to update theme definition with CSS variables");
                }
            }
        }
    } catch {
        # Log error
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_css',
            "Error saving CSS: $_");

        # Set error message
        $c->flash->{error} = "Error saving CSS: $_";
    };

    # Redirect back to the edit page
    $c->response->redirect($c->uri_for($self->action_for('edit_css'), [$theme_name]));
}

# Add a compatibility method to handle old URLs
sub legacy_redirect :Path('/themeadmin') :Args {
    my ($self, $c, @args) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'legacy_redirect',
        "Redirecting legacy theme URL: /themeadmin/" . join('/', @args));

    my $new_path = '/admin/theme';

    if (@args) {
        if ($args[0] eq 'update_theme') {
            $new_path = '/admin/theme/update';
        }
        elsif ($args[0] eq 'edit_theme_css' && $args[1]) {
            $new_path = '/admin/theme/edit/' . $args[1];
        }
        elsif ($args[0] eq 'wysiwyg_editor' && $args[1]) {
            $new_path = '/admin/theme/edit/' . $args[1];
        }
    }

    $c->response->redirect($c->uri_for($new_path));
    return;
}

__PACKAGE__->meta->make_immutable;
1;