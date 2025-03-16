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
    default => sub {Comserv::Util::Logging->instance}
);

# File paths for theme configuration
sub get_theme_definitions_path {
    my ($self, $c) = @_;
    return $c->path_to('root', 'static', 'config', 'theme_definitions.json');
}

sub get_theme_mappings_path {
    my ($self, $c) = @_;
    return $c->path_to('root', 'static', 'config', 'theme_mappings.json');
}

sub get_theme_css_directory {
    my ($self, $c) = @_;
    return $c->path_to('root', 'static', 'css', 'themes');
}

# Load theme definitions
sub get_theme_definitions {
    my ($self, $c) = @_;

    my $file = $self->get_theme_definitions_path($c);
    return {} unless -f $file;

    try {
        my $json = read_file($file);
        return decode_json($json);
    }
    catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_theme_definitions', "Error loading theme definitions: $_");
        return {};
    };
}

# Get all available themes
sub get_all_themes {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_all_themes', "Getting all available themes");
    return $self->get_theme_definitions($c);
}

# Get a specific theme
sub get_theme {
    my ($self, $c, $theme_name) = @_;

    my $themes = $self->get_theme_definitions($c);

    if (exists $themes->{$theme_name}) {
        return $themes->{$theme_name};
    }
    else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_theme', "Theme not found: $theme_name, returning default");
        return $themes->{default} || { name => "Default", variables => {} };
    }
}

# Validate theme name
sub validate_theme {
    my ($self, $c, $theme_name) = @_;

    # Get all valid themes from theme definitions
    my $themes = $self->get_theme_definitions($c);
    my @valid_themes = keys %$themes;

    # Convert theme name to lowercase for comparison
    $theme_name = lc($theme_name || '');

    # Return the theme name if valid, otherwise return 'default'
    my $valid_theme = (grep {lc($_) eq $theme_name} @valid_themes) ? $theme_name : 'default';

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'validate_theme',
        "Validated theme: $valid_theme (from: " . ($theme_name || 'undefined') . ")");

    return $valid_theme;
}

# Load theme mappings
sub load_theme_mappings {
    my ($self, $c) = @_;
    my $file = $self->get_theme_mappings_path($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'load_theme_mappings', "Loading theme mappings from: $file");

    unless (-f $file) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'load_theme_mappings', "Theme mappings file does not exist: $file");
        return {};
    }

    try {
        my $json = read_file($file);
        my $mappings = decode_json($json);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'load_theme_mappings',
            "Loaded theme mappings: " . join(", ", map { "$_ => $mappings->{sites}{$_}" } keys %{$mappings->{sites}}));
        return $mappings;
    }
    catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'load_theme_mappings', "Error loading theme mappings: $_");
        return {};
    };
}

# Save theme mappings
sub save_theme_mappings {
    my ($self, $c, $mappings) = @_;
    my $file = $self->get_theme_mappings_path($c);

    try {
        write_file($file, encode_json($mappings));
        return 1;
    }
    catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'save_theme_mappings', "Error saving theme mappings: $_");
        return 0;
    };
}

# Get site theme
sub get_site_theme {
    my ($self, $c, $site_name) = @_;

    # Log the site name for debugging
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_site_theme',
        "Getting theme for site: $site_name");

    # Check if we already have a theme in the stash or session for this site
    my $site_key = "theme_" . lc($site_name);

    if ($c->session->{$site_key}) {
        my $theme = $c->session->{$site_key};
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_site_theme',
            "Using theme from session for $site_name: $theme");

        # Store in stash for current request
        $c->stash->{theme_name} = $theme;

        return $theme;
    }

    # Load the theme mappings
    my $mappings = $self->load_theme_mappings($c);

    # Log the available mappings for debugging
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_site_theme',
        "Available mappings: " . join(", ", keys %{$mappings->{sites}}));

    # Try to get the theme using the exact site name first
    my $theme = $mappings->{sites}{$site_name};
    if ($theme) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_site_theme',
            "Found exact match for site $site_name: $theme");
    }

    # If no theme found, try case-insensitive matching
    if (!$theme) {
        foreach my $mapping_site (keys %{$mappings->{sites}}) {
            if (lc($mapping_site) eq lc($site_name)) {
                $theme = $mappings->{sites}{$mapping_site};
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_site_theme',
                    "Found theme via case-insensitive match: $mapping_site -> $theme");
                last;
            }
        }
    }

    # Validate the theme
    $theme = $self->validate_theme($c, $theme);

    # Log the selected theme
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_site_theme',
        "Selected theme for $site_name: " . ($theme || 'default'));

    # Store the theme in both stash and session for future use
    $c->stash->{theme_name} = $theme;
    $c->session->{$site_key} = $theme;  # Store with site-specific key
    $c->session->{theme_name} = $theme;  # Also store in general key for backward compatibility

    return $theme;
}

# Set site theme
sub set_site_theme {
    my ($self, $c, $site_name, $theme_name) = @_;

    # Log the theme update attempt
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'set_site_theme',
        "Setting theme for site $site_name to $theme_name");

    my $mappings = $self->load_theme_mappings($c);

    # Validate the theme
    my $validated_theme = $self->validate_theme($c, $theme_name);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'set_site_theme',
        "Validated theme: $validated_theme");

    # Check if the site already exists in the mappings (case-insensitive)
    my $existing_site_key = undef;
    foreach my $mapping_site (keys %{$mappings->{sites}}) {
        if (lc($mapping_site) eq lc($site_name)) {
            $existing_site_key = $mapping_site;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'set_site_theme',
                "Found existing site mapping: $mapping_site");
            last;
        }
    }

    # If the site exists, update its theme; otherwise, add a new entry with the original case
    if ($existing_site_key) {
        $mappings->{sites}{$existing_site_key} = $validated_theme;
    } else {
        $mappings->{sites}{$site_name} = $validated_theme;
    }

    # Store the theme in both stash and session for immediate use
    $c->stash->{theme_name} = $validated_theme;

    # Store with site-specific key
    my $site_key = "theme_" . lc($site_name);
    $c->session->{$site_key} = $validated_theme;

    # Also store in general key for backward compatibility
    $c->session->{theme_name} = $validated_theme;

    my $result = $self->save_theme_mappings($c, $mappings);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'set_site_theme',
        "Theme mapping saved: " . ($result ? "Success" : "Failed") .
        " for site $site_name with theme $validated_theme");

    return $result;
}

# Remove site theme mapping
sub remove_site_theme {
    my ($self, $c, $site_name) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'remove_site_theme',
        "Removing theme for site $site_name");

    my $mappings = $self->load_theme_mappings($c);

    # Check if the site exists in the mappings (case-insensitive)
    my $existing_site_key = undef;
    foreach my $mapping_site (keys %{$mappings->{sites}}) {
        if (lc($mapping_site) eq lc($site_name)) {
            $existing_site_key = $mapping_site;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'remove_site_theme',
                "Found existing site mapping to remove: $mapping_site");
            last;
        }
    }

    # If the site exists, remove it
    if ($existing_site_key) {
        delete $mappings->{sites}{$existing_site_key};

        # Clear the site-specific session key
        my $site_key = "theme_" . lc($site_name);
        delete $c->session->{$site_key};

        # If this was the current theme, clear the general key too
        if ($c->session->{theme_name} && $c->session->{theme_name} eq $c->stash->{theme_name}) {
            delete $c->session->{theme_name};
            delete $c->stash->{theme_name};
        }
    } else {
        $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__, 'remove_site_theme',
            "No mapping found for site: $site_name");
    }

    my $result = $self->save_theme_mappings($c, $mappings);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'remove_site_theme',
        "Theme mapping removed: " . ($result ? "Success" : "Failed") .
        " for site $site_name");

    return $result;
}

# Generate CSS for all themes
sub generate_all_theme_css {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'generate_all_theme_css', "Starting theme CSS generation");

    # Get all themes
    my $themes = $self->get_theme_definitions($c);

    # Create themes directory if it doesn't exist
    my $theme_dir = $self->get_theme_css_directory($c);
    my $css_dir = $c->path_to('root', 'static', 'css');

    unless (-d $theme_dir) {
        mkdir $theme_dir or do {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'generate_all_theme_css',
                "Failed to create themes directory: $!");
            return 0;
        };
    }
    mkdir $css_dir unless -d $css_dir;

    # Generate CSS for each theme
    foreach my $theme_name (keys %$themes) {
        my $theme_data = $themes->{$theme_name};

        # Generate CSS content
        my $css = "/* Theme: $theme_name */\n:root {\n";

        # Add variables
        foreach my $var_name (sort keys %{$theme_data->{variables}}) {
            $css .= "  --$var_name: " . $theme_data->{variables}{$var_name} . ";\n";
        }

        $css .= "}\n\n";

        # Add special styles if they exist
        if ($theme_data->{special_styles}) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'generate_all_theme_css',
                "Adding special styles for theme: $theme_name");

            foreach my $selector (keys %{$theme_data->{special_styles}}) {
                $css .= "$selector {\n";
                $css .= "  " . $theme_data->{special_styles}{$selector} . "\n";
                $css .= "}\n\n";
            }
        }

        # Write CSS file
        my $css_file = "$theme_dir/$theme_name.css";
        try {
            write_file($css_file, $css);
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'generate_all_theme_css',
                "Generated CSS for theme: $theme_name");
        }
        catch {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'generate_all_theme_css',
                "Failed to write CSS file for theme $theme_name: $_");
            return 0;
        };
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'generate_all_theme_css',
        "Completed theme CSS generation");
    return 1;
}

# Create new theme
sub create_theme {
    my ($self, $c, $theme_name, $theme_data) = @_;

    my $themes = $self->get_theme_definitions($c);
    $themes->{$theme_name} = $theme_data;

    my $file = $self->get_theme_definitions_path($c);
    try {
        write_file($file, encode_json($themes));
        return 1;
    }
    catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_theme', "Error creating theme: $_");
        return 0;
    };
}

# Update existing theme
sub update_theme {
    my ($self, $c, $theme_name, $theme_data) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme',
        "Updating theme: $theme_name");

    my $themes = $self->get_theme_definitions($c);

    # Check if the theme exists
    if (!exists $themes->{$theme_name}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_theme',
            "Theme not found: $theme_name");
        return 0;
    }

    # Update the theme
    $themes->{$theme_name} = $theme_data;

    # Save the updated themes
    my $file = $self->get_theme_definitions_path($c);
    try {
        write_file($file, encode_json($themes));
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_theme',
            "Theme updated successfully: $theme_name");
        return 1;
    }
    catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_theme',
            "Error updating theme: $_");
        return 0;
    };
}

__PACKAGE__->meta->make_immutable;
1;