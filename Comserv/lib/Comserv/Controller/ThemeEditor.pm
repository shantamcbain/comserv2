package Comserv::Controller::ThemeEditor;

use Moose;
use namespace::autoclean;
use Try::Tiny;
use File::Slurp;
use File::Path qw(make_path);
use Data::Dumper;
use JSON;
use Comserv::Util::Logging;
use Class::C3;

BEGIN { extends 'Catalyst::Controller'; }

__PACKAGE__->config(namespace => 'themeeditor');

# Debug the controller loading
sub COMPONENT {
    my ($class, $app, $args) = @_;

    $app->log->info("Loading ThemeEditor controller with namespace: " . $class->config->{namespace});
    $app->log->info("ThemeEditor controller actions: " . join(", ", map { $_->name } $class->get_action_methods()));

    return $class->next::method($app, $args);
}

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# Main WYSIWYG theme editor page
sub index :Path :Args(0) {
    my ($self, $c) = @_;

    # Log that we've entered the index method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "***** ENTERED THEMEEDITOR INDEX METHOD *****");

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

    # Get all available themes
    my $themes = $c->model('ThemeConfig')->get_all_themes($c);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Available themes from JSON: " . Dumper($themes));

    # Get list of theme names
    my @theme_names = sort keys %$themes;

    # Pass data to template
    $c->stash->{themes} = $themes;
    $c->stash->{theme_names} = \@theme_names;
    $c->stash->{template} = 'admin/theme/editor.tt';

    # Log that we're rendering the template
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "***** RENDERING TEMPLATE: admin/theme/editor.tt *****");
}

# Edit a specific theme
sub edit :Path('edit') :Args(1) {
    my ($self, $c, $theme_name) = @_;

    # Log that we've entered the edit method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit', "***** ENTERED THEMEEDITOR EDIT METHOD FOR $theme_name *****");

    # Check if the user is logged in
    if (!$c->user_exists && !$c->session->{user_id}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit', "User not logged in, redirecting to login page");
        $c->flash->{error} = 'You must be logged in to access this page';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Get the theme
    my $theme = $c->model('ThemeConfig')->get_theme($c, $theme_name);

    if (!$theme) {
        $c->flash->{error} = "Theme '$theme_name' not found";
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    # Get current site
    my $site_name = $c->session->{SiteName};

    # Pass data to template
    $c->stash->{theme} = $theme;
    $c->stash->{theme_name} = $theme_name;
    $c->stash->{site_name} = $site_name;
    $c->stash->{template} = 'admin/theme/edit.tt';

    # Log that we're rendering the template
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit', "***** RENDERING TEMPLATE: admin/theme/edit.tt *****");
}

# WYSIWYG theme editor
sub wysiwyg :Path('wysiwyg') :Args(1) {
    my ($self, $c, $theme_name) = @_;

    # Log that we've entered the wysiwyg method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'wysiwyg', "***** ENTERED THEMEEDITOR WYSIWYG METHOD FOR $theme_name *****");

    # Check if the user is logged in
    if (!$c->user_exists && !$c->session->{user_id}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'wysiwyg', "User not logged in, redirecting to login page");
        $c->flash->{error} = 'You must be logged in to access this page';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Get the theme
    my $theme = $c->model('ThemeConfig')->get_theme($c, $theme_name);

    if (!$theme) {
        $c->flash->{error} = "Theme '$theme_name' not found";
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    # Get current site
    my $site_name = $c->session->{SiteName};

    # Pass data to template
    $c->stash->{theme} = $theme;
    $c->stash->{theme_name} = $theme_name;
    $c->stash->{site_name} = $site_name;
    $c->stash->{template} = 'admin/theme/wysiwyg.tt';

    # Log that we're rendering the template
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'wysiwyg', "***** RENDERING TEMPLATE: admin/theme/wysiwyg.tt *****");
}

# Update theme
sub update_theme :Path('update_theme') :Args(0) {
    my ($self, $c) = @_;

    # Log that we've entered the update_theme method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme', "***** ENTERED THEMEEDITOR UPDATE_THEME METHOD *****");

    # Check if the user is logged in
    if (!$c->user_exists && !$c->session->{user_id}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme', "User not logged in, redirecting to login page");
        $c->flash->{error} = 'You must be logged in to access this page';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Get parameters
    my $theme_name = $c->request->params->{theme_name};
    my $theme_display_name = $c->request->params->{theme_display_name};
    my $theme_description = $c->request->params->{theme_description};

    # Get the theme
    my $theme = $c->model('ThemeConfig')->get_theme($c, $theme_name);

    if (!$theme) {
        $c->flash->{error} = "Theme '$theme_name' not found";
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    # Update theme metadata
    $theme->{name} = $theme_display_name;
    $theme->{description} = $theme_description;

    # Update theme variables
    foreach my $param (keys %{$c->request->params}) {
        if ($param =~ /^var_(.+)$/) {
            my $var_name = $1;
            my $var_value = $c->request->params->{$param};
            $theme->{variables}->{$var_name} = $var_value;
        }
    }

    # Update special styles
    foreach my $param (keys %{$c->request->params}) {
        if ($param =~ /^special_style_(.+)$/) {
            my $style_name = $1;
            my $style_value = $c->request->params->{$param};

            # Handle special case for body background image
            if ($style_name eq 'body_background_image' && $style_value) {
                $theme->{special_styles}->{body} = "background-image: url($style_value);" .
                    ($theme->{special_styles}->{body_additional} || '');
            }
            elsif ($style_name eq 'body_additional') {
                $theme->{special_styles}->{body_additional} = $style_value;

                # Update the body style with both background image and additional styles
                my $bg_image = '';
                if ($theme->{special_styles}->{body} &&
                    $theme->{special_styles}->{body} =~ /background-image:\s*url\((.+?)\);/) {
                    $bg_image = "background-image: url($1);";
                }

                $theme->{special_styles}->{body} = $bg_image . $style_value;
            }
            else {
                $theme->{special_styles}->{$style_name} = $style_value;
            }
        }
    }

    # Save the updated theme
    my $result = $c->model('ThemeConfig')->update_theme($c, $theme_name, $theme);

    if ($result) {
        $c->flash->{message} = "Theme '$theme_display_name' updated successfully";
    } else {
        $c->flash->{error} = "Error updating theme '$theme_name'";
    }

    # Redirect back to the edit page
    $c->response->redirect($c->uri_for($self->action_for('edit'), [$theme_name]));
}

# Edit theme (handles the edit_theme URL from the template)
sub edit_theme :Path('edit_theme') :Args(0) {
    my ($self, $c) = @_;

    # Log that we've entered the edit_theme method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_theme', "***** ENTERED THEMEEDITOR EDIT_THEME METHOD *****");

    # Check if the user is logged in
    if (!$c->user_exists && !$c->session->{user_id}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_theme', "User not logged in, redirecting to login page");
        $c->flash->{error} = 'You must be logged in to access this page';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Get the theme name from the query parameters
    my $theme_name = $c->request->params->{theme_name};

    if (!$theme_name) {
        $c->flash->{error} = "No theme specified";
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    # Get the theme
    my $theme = $c->model('ThemeConfig')->get_theme($c, $theme_name);

    if (!$theme) {
        $c->flash->{error} = "Theme '$theme_name' not found";
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    # Get current site
    my $site_name = $c->session->{SiteName};

    # Pass data to template
    $c->stash->{theme} = $theme;
    $c->stash->{theme_name} = $theme_name;
    $c->stash->{site_name} = $site_name;
    $c->stash->{template} = 'admin/theme/edit.tt';

    # Get site themes for the site-theme mappings section
    my $site_themes = {};
    try {
        my $json_file = $c->model('ThemeConfig')->get_theme_definitions_path($c);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_theme', "Reading theme definitions from: $json_file");

        if (-f $json_file) {
            my $json_content = read_file($json_file);
            my $data = decode_json($json_content);
            $site_themes = $data->{site_themes} || {};
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_theme',
                "Found " . scalar(keys %$site_themes) . " site-theme mappings");
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_theme',
                "Theme definitions file not found: $json_file");
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_theme', "Error reading theme definitions: $_");
    };

    $c->stash->{site_themes} = $site_themes;

    # Log that we're rendering the template
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_theme', "***** RENDERING TEMPLATE: admin/theme/edit.tt *****");
}

# Apply theme changes in real-time (AJAX endpoint)
sub apply_changes :Path('apply_changes') :Args(0) {
    my ($self, $c) = @_;

    # Log that we've entered the apply_changes method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'apply_changes', "***** ENTERED THEMEEDITOR APPLY_CHANGES METHOD *****");

    # Check if the user is logged in
    if (!$c->user_exists && !$c->session->{user_id}) {
        $c->response->body('{"success": false, "error": "Not logged in"}');
        $c->response->content_type('application/json');
        return;
    }

    # Get parameters
    my $theme_name = $c->request->params->{theme_name};
    my $variable_name = $c->request->params->{variable_name};
    my $variable_value = $c->request->params->{variable_value};

    # Get the theme
    my $theme = $c->model('ThemeConfig')->get_theme($c, $theme_name);

    if (!$theme) {
        $c->response->body('{"success": false, "error": "Theme not found"}');
        $c->response->content_type('application/json');
        return;
    }

    # Update the variable
    $theme->{variables}->{$variable_name} = $variable_value;

    # Generate CSS for the updated theme (but don't save it yet)
    my $css = $c->model('ThemeConfig')->generate_theme_css($c, $theme);

    # Return success response with the CSS
    $c->response->body('{"success": true, "css": ' . $c->json_encode($css) . '}');
    $c->response->content_type('application/json');
}

__PACKAGE__->meta->make_immutable;
1;