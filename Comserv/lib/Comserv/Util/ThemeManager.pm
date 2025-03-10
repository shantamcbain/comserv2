package Comserv::Util::ThemeManager;

use strict;
use warnings;
use Moose;
use namespace::autoclean;
use JSON;
use Try::Tiny;
use File::Slurp qw(read_file write_file);
use Comserv::Util::Logging;

has 'json_file' => (
    is => 'ro',
    default => sub {
        # Try to use a relative path if possible
        if (-e 'root/static/css/themes/theme_definitions.json') {
            return 'root/static/css/themes/theme_definitions.json';
        } else {
            return '/comserv/Comserv/root/static/css/themes/theme_definitions.json';
        }
    }
);

has 'css_dir' => (
    is => 'ro',
    default => sub {
        # Try to use a relative path if possible
        if (-d 'root/static/css/themes') {
            return 'root/static/css/themes';
        } else {
            return '/comserv/Comserv/root/static/css/themes';
        }
    }
);

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# Get all themes
sub get_all_themes {
    my ($self, $c) = @_;

    try {
        # Use Catalyst's path_to method if available
        my $json_file = $self->json_file;
        if ($c && $c->can('path_to')) {
            $json_file = $c->path_to('root', 'static', 'css', 'themes', 'theme_definitions.json');
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_all_themes', "Using Catalyst path: $json_file");
        }

        my $json_content = read_file($json_file);
        my $data = decode_json($json_content);
        return $data->{themes};
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_all_themes', "Error reading theme definitions: $_");
        return {};
    };
}

# Get theme by name
sub get_theme {
    my ($self, $c, $theme_name) = @_;
    
    try {
        my $json_content = read_file($self->json_file);
        my $data = decode_json($json_content);
        
        if (exists $data->{themes}{$theme_name}) {
            return $data->{themes}{$theme_name};
        } else {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_theme', "Theme not found: $theme_name, returning default");
            return $data->{themes}{default};
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_theme', "Error reading theme definitions: $_");
        return undef;
    };
}

# Get site theme
sub get_site_theme {
    my ($self, $c, $site_name) = @_;

    try {
        # Use Catalyst's path_to method if available
        my $json_file = $self->json_file;
        if ($c && $c->can('path_to')) {
            $json_file = $c->path_to('root', 'static', 'css', 'themes', 'theme_definitions.json');
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_site_theme', "Using Catalyst path: $json_file");
        }

        my $json_content = read_file($json_file);
        my $data = decode_json($json_content);

        # Convert site name to lowercase
        my $site_name_lower = lc($site_name);

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_site_theme',
            "Looking for theme for site: $site_name_lower in site_themes: " . Dumper($data->{site_themes}));

        if (exists $data->{site_themes}{$site_name_lower}) {
            my $theme = $data->{site_themes}{$site_name_lower};
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_site_theme',
                "Found theme for site $site_name_lower: $theme");
            return $theme;
        } else {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_site_theme',
                "No theme mapping for site: $site_name, returning default");
            return 'default';
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_site_theme',
            "Error reading theme definitions: $_");
        return 'default';
    };
}

# Set site theme
sub set_site_theme {
    my ($self, $c, $site_name, $theme_name) = @_;

    try {
        # Use Catalyst's path_to method if available
        my $json_file = $self->json_file;
        if ($c && $c->can('path_to')) {
            $json_file = $c->path_to('root', 'static', 'css', 'themes', 'theme_definitions.json');
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'set_site_theme', "Using Catalyst path: $json_file");
        }

        my $json_content = read_file($json_file);
        my $data = decode_json($json_content);
        
        # Convert site name to lowercase
        my $site_name_lower = lc($site_name);

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'set_site_theme',
            "Setting theme for site $site_name_lower to $theme_name");

        # Check if theme exists
        if (!exists $data->{themes}{$theme_name}) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'set_site_theme',
                "Theme does not exist: $theme_name");
            return 0;
        }

        # Log the current site-theme mappings
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'set_site_theme',
            "Current site-theme mappings: " . Dumper($data->{site_themes}));

        # Update site theme mapping
        $data->{site_themes}{$site_name_lower} = $theme_name;

        # Log the updated site-theme mappings
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'set_site_theme',
            "Updated site-theme mappings: " . Dumper($data->{site_themes}));
        
        # Write updated data back to file
        write_file($json_file, encode_json($data));

        # Generate the CSS file for the theme
        $self->generate_theme_css($c, $theme_name);

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'set_site_theme', "Updated theme for site $site_name to $theme_name");
        return 1;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'set_site_theme', "Error updating site theme: $_");
        return 0;
    };
}

# Create a new theme
sub create_theme {
    my ($self, $c, $theme_name, $theme_data) = @_;
    
    try {
        my $json_content = read_file($self->json_file);
        my $data = decode_json($json_content);
        
        # Check if theme already exists
        if (exists $data->{themes}{$theme_name}) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'create_theme', "Theme already exists: $theme_name");
            return 0;
        }
        
        # Add new theme
        $data->{themes}{$theme_name} = $theme_data;
        
        # Write updated data back to file
        write_file($self->json_file, encode_json($data));
        
        # Generate CSS file for the theme
        $self->generate_theme_css($c, $theme_name);
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_theme', "Created new theme: $theme_name");
        return 1;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_theme', "Error creating theme: $_");
        return 0;
    };
}

# Update an existing theme
sub update_theme {
    my ($self, $c, $theme_name, $theme_data) = @_;
    
    try {
        my $json_content = read_file($self->json_file);
        my $data = decode_json($json_content);
        
        # Check if theme exists
        if (!exists $data->{themes}{$theme_name}) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'update_theme', "Theme does not exist: $theme_name");
            return 0;
        }
        
        # Update theme
        $data->{themes}{$theme_name} = $theme_data;
        
        # Write updated data back to file
        write_file($self->json_file, encode_json($data));
        
        # Generate CSS file for the theme
        $self->generate_theme_css($c, $theme_name);
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme', "Updated theme: $theme_name");
        return 1;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_theme', "Error updating theme: $_");
        return 0;
    };
}

# Delete a theme
sub delete_theme {
    my ($self, $c, $theme_name) = @_;
    
    # Don't allow deleting built-in themes
    if ($theme_name eq 'default' || $theme_name eq 'csc' || $theme_name eq 'apis' || $theme_name eq 'usbm') {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'delete_theme', "Cannot delete built-in theme: $theme_name");
        return 0;
    }
    
    try {
        my $json_content = read_file($self->json_file);
        my $data = decode_json($json_content);
        
        # Check if theme exists
        if (!exists $data->{themes}{$theme_name}) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'delete_theme', "Theme does not exist: $theme_name");
            return 0;
        }
        
        # Check if any sites are using this theme
        foreach my $site (keys %{$data->{site_themes}}) {
            if ($data->{site_themes}{$site} eq $theme_name) {
                # Reset site to default theme
                $data->{site_themes}{$site} = 'default';
            }
        }
        
        # Delete theme
        delete $data->{themes}{$theme_name};
        
        # Write updated data back to file
        write_file($self->json_file, encode_json($data));
        
        # Delete CSS file if it exists
        my $css_file = $self->css_dir . "/$theme_name.css";
        if (-e $css_file) {
            unlink $css_file;
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete_theme', "Deleted theme: $theme_name");
        return 1;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'delete_theme', "Error deleting theme: $_");
        return 0;
    };
}

# Generate CSS file for a theme
sub generate_theme_css {
    my ($self, $c, $theme_name) = @_;

    try {
        my $theme = $self->get_theme($c, $theme_name);

        if (!$theme) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'generate_theme_css', "Theme not found: $theme_name");
            return 0;
        }

        # Start with CSS variable declarations
        my $css = "/* Theme: " . $theme->{name} . " */\n";
        $css .= "/* Description: " . $theme->{description} . " */\n\n";
        $css .= ":root {\n";

        # Add each variable
        foreach my $var_name (sort keys %{$theme->{variables}}) {
            $css .= "  --$var_name: " . $theme->{variables}{$var_name} . ";\n";
        }

        $css .= "}\n\n";

        # Add body styles
        $css .= "body, body.theme-$theme_name {\n";
        $css .= "  font-family: var(--body-font);\n";
        $css .= "  font-size: var(--font-size-base);\n";
        $css .= "  color: var(--text-color);\n";
        $css .= "  background-color: var(--background-color);\n";

        # Add any special styles
        if (exists $theme->{special_styles} && exists $theme->{special_styles}{body}) {
            $css .= "  " . $theme->{special_styles}{body} . "\n";
        }

        $css .= "}\n\n";

        # Add link styles
        $css .= "a {\n";
        $css .= "  color: var(--link-color);\n";
        $css .= "}\n\n";

        $css .= "a:hover {\n";
        $css .= "  color: var(--link-hover-color);\n";
        $css .= "}\n\n";

        # Add button styles
        $css .= "button,\n";
        $css .= ".button,\n";
        $css .= "input[type=\"submit\"] {\n";
        $css .= "  background-color: var(--button-bg);\n";
        $css .= "  color: var(--button-text);\n";
        $css .= "  border: 1px solid var(--button-border);\n";
        $css .= "}\n\n";

        $css .= "button:hover,\n";
        $css .= ".button:hover,\n";
        $css .= "input[type=\"submit\"]:hover {\n";
        $css .= "  background-color: var(--button-hover-bg);\n";
        $css .= "}\n\n";

        # Add nav styles
        $css .= "nav {\n";
        $css .= "  background-color: var(--nav-bg);\n";
        $css .= "  color: var(--nav-text);\n";
        $css .= "}\n\n";

        # Add legacy elements if they exist
        if (exists $theme->{legacy_elements}) {
            $css .= "/* Legacy Elements */\n";

            foreach my $selector (sort keys %{$theme->{legacy_elements}}) {
                $css .= ".$selector, $selector {\n";

                foreach my $property (sort keys %{$theme->{legacy_elements}{$selector}}) {
                    $css .= "  $property: " . $theme->{legacy_elements}{$selector}{$property} . ";\n";
                }

                $css .= "}\n\n";
            }
        }

        # Write CSS file
        my $css_file = $self->css_dir . "/$theme_name.css";
        write_file($css_file, $css);

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'generate_theme_css', "Generated CSS file for theme: $theme_name");
        return 1;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'generate_theme_css', "Error generating CSS for theme $theme_name: $_");
        return 0;
    };
}

# Create a custom theme for a site
sub create_custom_theme {
    my ($self, $c, $site_name, $theme_data) = @_;
    
    # Generate a theme name based on the site name
    my $theme_name = lc($site_name) . '_custom';
    
    # Create the theme
    my $result = $self->create_theme($c, $theme_name, $theme_data);
    
    if ($result) {
        # Set the site to use this theme
        $self->set_site_theme($c, $site_name, $theme_name);
        return $theme_name;
    } else {
        return undef;
    }
}

# Generate all theme CSS files
sub generate_all_theme_css {
    my ($self, $c) = @_;
    
    try {
        my $themes = $self->get_all_themes($c);
        
        foreach my $theme_name (keys %$themes) {
            $self->generate_theme_css($c, $theme_name);
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'generate_all_theme_css', "Generated CSS files for all themes");
        return 1;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'generate_all_theme_css', "Error generating CSS files: $_");
        return 0;
    };
}

__PACKAGE__->meta->make_immutable;
1;