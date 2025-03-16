package Comserv::Controller::Admin::ThemeEditor;
    use Moose;
    use namespace::autoclean;
    use File::Slurp;
    use Try::Tiny;
    use Comserv::Util::Logging;
    use Comserv::Util::ThemeManager;
    use File::Find;
    use JSON;

    BEGIN { extends 'Catalyst::Controller'; }

    has 'logging' => (
        is => 'ro',
        default => sub { Comserv::Util::Logging->instance }
    );

    has 'theme_manager' => (
        is => 'ro',
        default => sub { Comserv::Util::ThemeManager->new }
    );

sub edit :Path('/admin/theme/edit') :Args(1) {
    my ($self, $c, $theme_name) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit', "Saving CSS content for theme: $theme_name");

    # Check admin permissions
    unless ($c->session->{roles} && grep { $_ eq 'admin' } @{$c->session->{roles}}) {
        $c->flash->{error} = 'Admin access required';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    my $css_file = $c->path_to('root', 'static', 'css', $theme_name . '.css');
    # Get the JSON file path from ThemeManager for consistency
    my $json_file = $self->theme_manager->json_file($c);

    # Log the JSON file path for debugging
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit', "Using JSON file from ThemeManager: $json_file");

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
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'edit', "CSS Content: $css_content");

    # Get CSS variables from both possible locations and merge them
    my $css_variables = {};

    # First try using ThemeManager (config location)
    try {
        # Get the theme using ThemeManager
        my $theme = $self->theme_manager->get_theme($c, $theme_name);

        if ($theme && ref($theme) eq 'HASH') {
            # Extract variables from the theme
            $css_variables = $theme->{variables} || {};
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit',
                "Found theme '$theme_name' with " . scalar(keys %$css_variables) . " variables using ThemeManager");
        } else {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'edit',
                "Theme '$theme_name' not found or invalid in config theme definitions");
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit',
            "Error getting theme variables from ThemeManager: $_");
    };

    # Then try the css/themes location and merge variables
    try {
        my $css_themes_file = $c->path_to('root', 'static', 'css', 'themes', 'theme_definitions.json');

        if (-f $css_themes_file) {
            my $json_text = read_file($css_themes_file);
            my $theme_data = decode_json($json_text);

            # Check both possible structures
            my $theme;
            if ($theme_data->{themes} && $theme_data->{themes}->{$theme_name}) {
                $theme = $theme_data->{themes}->{$theme_name};
            } elsif ($theme_data->{$theme_name}) {
                $theme = $theme_data->{$theme_name};
            }

            if ($theme && ref($theme) eq 'HASH' && $theme->{variables}) {
                # Merge with existing variables (css/themes variables take precedence)
                my $theme_vars = $theme->{variables} || {};
                my $var_count_before = scalar(keys %$css_variables);

                # Merge the variables
                foreach my $key (keys %$theme_vars) {
                    $css_variables->{$key} = $theme_vars->{$key};
                }

                my $var_count_after = scalar(keys %$css_variables);
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit',
                    "Added " . ($var_count_after - $var_count_before) . " variables from css/themes location");
            }
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit',
            "Error getting theme variables from css/themes location: $_");
    };

    # If no variables were found, set an error
    if (scalar(keys %$css_variables) == 0) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'edit',
            "No CSS variables found for theme '$theme_name' in any location");
        $css_variables = { error => "No CSS variables found for theme '$theme_name'" };
    }

    # Log the content of css_variables with more details
    my $var_count = scalar(keys %$css_variables);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit',
        "CSS Variables for theme '$theme_name': Found $var_count variables");

    if ($var_count > 0) {
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'edit',
            "CSS Variables content: " . encode_json($css_variables));
    } else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'edit',
            "No CSS variables found for theme '$theme_name'");
    }

    $c->stash(
        template => 'admin/theme/edit_css.tt',
        css_content => $css_content,
        theme_name => $theme_name,
        css_variables => $css_variables
    );
}
sub update_css_variables {
    my ($self, $c) = @_;

    my $root_dir = $c->path_to('root');
    my $json_file = $c->path_to('root', 'admin', 'theme', 'css_variables.json');

    # Read existing CSS variables from JSON file
    my $json_text = read_file($json_file);
    my $css_variables = decode_json($json_text)->{variables};

    # Subroutine to process each file
    sub process_file {
        return unless -f $_;
        return unless $_ =~ /\.tt$/;

        my $file_content = read_file($_);
        while ($file_content =~ /--([a-zA-Z0-9-]+)\b/g) {
            $css_variables->{$1} //= "Description";
        }
    }

    # Find all .tt files and process them
    find(\&process_file, $root_dir);

    # Write updated CSS variables back to JSON file
    my $updated_json_text = encode_json({ variables => $css_variables });
    write_file($json_file, $updated_json_text);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_css_variables', "CSS variables list updated successfully.");
}
    __PACKAGE__->meta->make_immutable;
    1;