package Comserv::Model::ThemeConfig;

use Moose;
use namespace::autoclean;
use JSON;
use File::Slurp;
use Try::Tiny;
use Comserv::Util::Logging;

extends 'Catalyst::Model';

has 'logging' => (
    is      => 'ro',
    default => sub {Comserv::Util::Logging->instance},
    handles => ['log_with_details'],
);

# Canonical: read from static/config/theme_definitions.json
sub get_theme_definitions_path {
    my ($self, $c) = @_;
    return $c->path_to('root', 'static', 'config', 'theme_definitions.json');
}

sub get_theme_mappings_path {
    # In the new single-source plan, mappings are read from the canonical definitions JSON.
    # This function is kept for compatibility; actual mappings are derived from theme_definitions.json.
    return undef;
}

sub get_theme_css_directory {
    my ($self, $c) = @_;
    return $c->path_to('root', 'static', 'css', 'themes');
}

sub get_theme_definitions {
    my ($self, $c) = @_;

    my $file = $self->get_theme_definitions_path($c);
    return {} unless -e $file;

    try {
        my $json = read_file($file);
        my $defs = decode_json($json);
        # Normalize to expected top-level keys if necessary
        return $defs->{themes} ? $defs->{themes} : $defs;
    }
    catch {
        $self->log_with_details($c, 'error', __FILE__, __LINE__, 'get_theme_definitions', "Error loading theme definitions: $_");
        return {};
    };
}

# Get all available themes
sub get_all_themes {
    my ($self, $c) = @_;
    $self->log_with_details($c, 'info', __FILE__, __LINE__, 'get_all_themes', "Loading canonical theme definitions");
    my $defs = $self->get_theme_definitions($c);
    return $defs;
}

# Get specific theme data by theme name
sub get_theme {
    my ($self, $c, $theme_name) = @_;
    
    $self->log_with_details($c, 'info', __FILE__, __LINE__, 'get_theme', "Getting theme data for: $theme_name");
    
    my $themes = $self->get_theme_definitions($c);
    
    if (exists $themes->{$theme_name}) {
        $self->log_with_details($c, 'info', __FILE__, __LINE__, 'get_theme', "Found theme data for: $theme_name");
        return $themes->{$theme_name};
    }
    
    $self->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_theme', "Theme '$theme_name' not found, returning empty data");
    return { variables => {} };
}

# Get the theme for a specific site
sub get_site_theme {
    my ($self, $c, $site_name) = @_;
    
    $self->log_with_details($c, 'info', __FILE__, __LINE__, 'get_site_theme', "Getting theme for site: $site_name");
    
    # Check if there's a theme preference in session
    if ($c->session && $c->session->{"theme_$site_name"}) {
        my $session_theme = $c->session->{"theme_$site_name"};
        $self->log_with_details($c, 'info', __FILE__, __LINE__, 'get_site_theme', "Using theme from session for $site_name: $session_theme");
        return $session_theme;
    }
    
    # Load theme definitions and site mappings
    my $file = $self->get_theme_definitions_path($c);
    return 'default' unless -e $file;
    
    my $theme_config;
    try {
        my $json = read_file($file);
        $theme_config = decode_json($json);
    }
    catch {
        $self->log_with_details($c, 'error', __FILE__, __LINE__, 'get_site_theme', "Error loading theme config: $_");
        return 'default';
    };
    
    # Get site theme mappings
    my $site_themes = $theme_config->{site_themes} || {};
    
    # Log available mappings for debugging
    my @available = keys %$site_themes;
    $self->log_with_details($c, 'info', __FILE__, __LINE__, 'get_site_theme', "Available mappings: " . join(', ', @available));
    
    # Try exact match first
    my $normalized_site = lc($site_name);
    if (exists $site_themes->{$normalized_site}) {
        my $theme = $site_themes->{$normalized_site};
        $self->log_with_details($c, 'info', __FILE__, __LINE__, 'get_site_theme', "Found exact match for site $site_name: $theme");
        
        # Cache in session for future requests
        $c->session->{"theme_$site_name"} = $theme if $c->session;
        
        # Validate theme exists in definitions
        my $themes = $theme_config->{themes} || {};
        if (exists $themes->{$theme}) {
            $self->log_with_details($c, 'info', __FILE__, __LINE__, 'get_site_theme', "Selected theme for $site_name: $theme");
            return $theme;
        } else {
            $self->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_site_theme', "Theme '$theme' not found in definitions, using default");
        }
    }
    
    # Return default theme if no match found
    my $default_theme = 'default';
    $self->log_with_details($c, 'info', __FILE__, __LINE__, 'get_site_theme', "No mapping found for site $site_name, using default theme: $default_theme");
    
    # Cache default in session
    $c->session->{"theme_$site_name"} = $default_theme if $c->session;
    
    return $default_theme;
}

# Set the theme for a specific site (persists to JSON)
sub set_site_theme {
    my ($self, $c, $site_name, $theme_name) = @_;

    $self->log_with_details($c, 'info', __FILE__, __LINE__, 'set_site_theme',
        "Setting theme for site '$site_name' to '$theme_name'");

    try {
        my $config_file = $self->get_theme_definitions_path($c);

        my $config_data = {};
        if (-f $config_file) {
            my $json = read_file($config_file);
            $config_data = decode_json($json);
        }

        $config_data->{site_themes} ||= {};
        $config_data->{site_themes}{ lc($site_name) } = $theme_name;

        write_file($config_file, encode_json($config_data));

        # Update session cache
        $c->session->{"theme_$site_name"} = $theme_name if $c->session;

        $self->log_with_details($c, 'info', __FILE__, __LINE__, 'set_site_theme',
            "Successfully set theme '$theme_name' for site '$site_name'");
        return 1;
    }
    catch {
        $self->log_with_details($c, 'error', __FILE__, __LINE__, 'set_site_theme',
            "Error setting theme '$theme_name' for site '$site_name': $_");
        return 0;
    };
}

# Create a new theme definition
sub create_theme {
    my ($self, $c, $theme_data) = @_;

    my $theme_name = $theme_data->{name} or return 0;
    $self->log_with_details($c, 'info', __FILE__, __LINE__, 'create_theme',
        "Creating new theme: $theme_name");

    try {
        my $config_file = $self->get_theme_definitions_path($c);

        my $config_data = {};
        if (-f $config_file) {
            my $json = read_file($config_file);
            $config_data = decode_json($json);
        }

        $config_data->{themes} ||= {};

        # If based on an existing theme, copy its variables first
        my $variables = {};
        if (my $base = $theme_data->{base_theme}) {
            my $base_vars = ($config_data->{themes}{$base} || {})->{variables} || {};
            %$variables = %$base_vars;
        }

        # Overlay any provided variables
        if ($theme_data->{variables} && ref $theme_data->{variables} eq 'HASH') {
            %$variables = (%$variables, %{ $theme_data->{variables} });
        }

        $config_data->{themes}{$theme_name} = {
            name        => $theme_data->{display_name} || ucfirst($theme_name),
            description => $theme_data->{description}  || "Custom theme",
            variables   => $variables,
        };

        write_file($config_file, encode_json($config_data));

        # Generate the CSS file for the new theme
        $self->_write_theme_css($c, $theme_name, $config_data->{themes}{$theme_name});

        $self->log_with_details($c, 'info', __FILE__, __LINE__, 'create_theme',
            "Successfully created theme: $theme_name");
        return 1;
    }
    catch {
        $self->log_with_details($c, 'error', __FILE__, __LINE__, 'create_theme',
            "Error creating theme '$theme_name': $_");
        return 0;
    };
}

# Regenerate CSS files for all themes
sub generate_all_theme_css {
    my ($self, $c) = @_;

    $self->log_with_details($c, 'info', __FILE__, __LINE__, 'generate_all_theme_css',
        "Regenerating CSS files for all themes");

    my $config_file = $self->get_theme_definitions_path($c);
    return unless -f $config_file;

    try {
        my $json        = read_file($config_file);
        my $config_data = decode_json($json);
        my $themes      = $config_data->{themes} || {};

        foreach my $theme_name (keys %$themes) {
            $self->_write_theme_css($c, $theme_name, $themes->{$theme_name});
        }
    }
    catch {
        $self->log_with_details($c, 'error', __FILE__, __LINE__, 'generate_all_theme_css',
            "Error generating CSS files: $_");
    };
}

# Internal helper – write a single theme's CSS file
sub _write_theme_css {
    my ($self, $c, $theme_name, $theme_data) = @_;

    my $theme_dir = $self->get_theme_css_directory($c);

    unless (-d $theme_dir) {
        require File::Path;
        File::Path::make_path($theme_dir)
            or do {
            $self->log_with_details($c, 'error', __FILE__, __LINE__, '_write_theme_css',
                "Cannot create themes directory: $!");
            return;
        };
    }

    my $variables = $theme_data->{variables} || {};
    my $css = "/* Theme: $theme_name */\n:root {\n";
    foreach my $var (sort keys %$variables) {
        $css .= "  --$var: $variables->{$var};\n";
    }
    $css .= "}\n";

    if (my $special = $theme_data->{special_styles}) {
        foreach my $selector (keys %$special) {
            $css .= "\n$selector {\n  $special->{$selector}\n}\n";
        }
    }

    my $css_file = "$theme_dir/$theme_name.css";
    write_file($css_file, $css);

    $self->log_with_details($c, 'info', __FILE__, __LINE__, '_write_theme_css',
        "Written CSS file: $css_file");
}

# Save theme data to the theme definitions file
sub save_theme {
    my ($self, $c, $theme_name, $theme_data) = @_;
    
    $self->log_with_details($c, 'info', __FILE__, __LINE__, 'save_theme', "Saving theme: $theme_name");
    
    try {
        # Load current theme definitions
        my $config_file = $c->path_to('root', 'static', 'config', 'theme_definitions.json');
        
        my $config_data = {};
        if (-f $config_file) {
            my $config_json = read_file($config_file);
            $config_data = decode_json($config_json);
        }
        
        # Initialize themes section if it doesn't exist
        $config_data->{themes} ||= {};
        
        # Update the theme
        $config_data->{themes}->{$theme_name} = $theme_data;
        
        # Write back to file
        my $json_output = encode_json($config_data);
        write_file($config_file, $json_output);
        
        $self->log_with_details($c, 'info', __FILE__, __LINE__, 'save_theme', 
            "Successfully saved theme '$theme_name' to $config_file");
        
        return 1;
        
    } catch {
        $self->log_with_details($c, 'error', __FILE__, __LINE__, 'save_theme', 
            "Error saving theme '$theme_name': $_");
        return 0;
    };
}

# Update (replace) an existing theme's data - alias for save_theme
sub update_theme {
    my ($self, $c, $theme_name, $theme_data) = @_;
    return $self->save_theme($c, $theme_name, $theme_data);
}

# Get the favicon URL for a site (falls back to undef → default)
sub get_site_favicon {
    my ($self, $c, $site_name) = @_;

    my $config_file = $self->get_theme_definitions_path($c);
    return undef unless -f $config_file;

    my $config_data;
    try {
        my $json = read_file($config_file);
        $config_data = decode_json($json);
    }
    catch {
        return undef;
    };

    return $config_data->{site_favicons}{ lc($site_name) };
}

# Set the favicon URL for a site (persists to JSON)
sub set_site_favicon {
    my ($self, $c, $site_name, $favicon_url) = @_;

    $self->log_with_details($c, 'info', __FILE__, __LINE__, 'set_site_favicon',
        "Setting favicon for '$site_name' to '$favicon_url'");

    try {
        my $config_file = $self->get_theme_definitions_path($c);
        my $config_data = {};
        if (-f $config_file) {
            my $json = read_file($config_file);
            $config_data = decode_json($json);
        }
        $config_data->{site_favicons} ||= {};
        $config_data->{site_favicons}{ lc($site_name) } = $favicon_url;
        write_file($config_file, encode_json($config_data));
        return 1;
    }
    catch {
        $self->log_with_details($c, 'error', __FILE__, __LINE__, 'set_site_favicon', "Error: $_");
        return 0;
    };
}

__PACKAGE__->meta->make_immutable;
1;
