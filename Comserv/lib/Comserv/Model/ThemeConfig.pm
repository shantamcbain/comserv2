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

__PACKAGE__->meta->make_immutable;
1;
