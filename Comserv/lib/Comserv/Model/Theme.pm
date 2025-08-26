package Comserv::Model::Theme;

use strict;
use JSON;
use File::Slurp;
use warnings;
use Moose;
use namespace::autoclean;
use Try::Tiny;
use Comserv::Util::Logging;

has 'schema' => (
    is => 'ro',
    required => 1,
);

# Add method to read theme mappings from JSON
sub get_theme_from_json {
    my ($self, $c, $site_name) = @_;
    
    my $json_path = $c->path_to('root', 'static', 'config', 'theme_mappings.json');
    
    return 'default' unless -f $json_path;
    
    my $json_text = read_file($json_path);
    my $theme_map = decode_json($json_text);
    
    # Normalize site name for lookup
    $site_name = uc($site_name || 'DEFAULT');
    
    # Check if site exists in mapping, otherwise return default
    my $theme = $theme_map->{sites}{$site_name} || 
                $theme_map->{sites}{'DEFAULT'} || 
                'default';
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
        'get_theme_from_json', "Selected theme for $site_name: $theme");
    
    return $theme;
}

# Enhanced theme validation method
sub validate_theme {
    my ($self, $theme_name) = @_;
    
    # List of valid themes
    my @valid_themes = qw(default csc usbm apis);
    
    if (grep { $_ eq lc($theme_name) } @valid_themes) {
        return $theme_name;
    } else {
        return 'default';
    }
}

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# Get all available themes
sub get_all_themes {
    my ($self, $c) = @_;
    
    try {
        my @themes = $self->schema->resultset('Theme')->search(
            { is_active => 1 },
            { order_by => 'name' }
        );
        return \@themes;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_all_themes', "Error fetching themes: $_");
        return [];
    };
}

# Get theme by ID
sub get_theme_by_id {
    my ($self, $c, $theme_id) = @_;
    
    try {
        return $self->schema->resultset('Theme')->find($theme_id);
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_theme_by_id', "Error fetching theme $theme_id: $_");
        return undef;
    };
}

# Get theme by name
sub get_theme_by_name {
    my ($self, $c, $theme_name) = @_;
    
    try {
        return $self->schema->resultset('Theme')->find({ name => $theme_name });
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_theme_by_name', "Error fetching theme $theme_name: $_");
        return undef;
    };
}

# Get theme variables
sub get_theme_variables {
    my ($self, $c, $theme_id) = @_;
    
    try {
        my @variables = $self->schema->resultset('ThemeVariable')->search(
            { theme_id => $theme_id },
            { order_by => 'variable_name' }
        );
        
        my %variables_hash;
        foreach my $var (@variables) {
            $variables_hash{$var->variable_name} = $var->variable_value;
        }
        
        return \%variables_hash;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_theme_variables', "Error fetching theme variables for theme $theme_id: $_");
        return {};
    };
}

# Get site theme
sub get_site_theme {
    my ($self, $c, $site_id) = @_;
    
    try {
        my $site_theme = $self->schema->resultset('SiteTheme')->find({ site_id => $site_id });
        return $site_theme ? $site_theme->theme_id : $self->validate_theme($self->get_theme_from_json($c, $c->model('Site')->get_site_by_id($c, $site_id)->name)); # Default to theme from JSON mapping if not found
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_site_theme', "Error fetching theme for site $site_id: $_");
        return $self->validate_theme($self->get_theme_from_json($c, $c->model('Site')->get_site_by_id($c, $site_id)->name)); # Default to theme from JSON mapping on error
    };
}

# Set site theme
sub set_site_theme {
    my ($self, $c, $site_id, $theme_id) = @_;
    
    try {
        my $site_theme = $self->schema->resultset('SiteTheme')->find({ site_id => $site_id });
        
        if ($site_theme) {
            $site_theme->update({ theme_id => $theme_id, is_customized => 0 });
        } else {
            $self->schema->resultset('SiteTheme')->create({
                site_id => $site_id,
                theme_id => $theme_id,
                is_customized => 0
            });
        }
        
        return 1; # Success
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'set_site_theme', "Error setting theme $theme_id for site $site_id: $_");
        return 0; # Failure
    };
}

# Update theme variable
sub update_theme_variable {
    my ($self, $c, $theme_id, $variable_name, $variable_value) = @_;
    
    try {
        my $variable = $self->schema->resultset('ThemeVariable')->find({
            theme_id => $theme_id,
            variable_name => $variable_name
        });
        
        if ($variable) {
            $variable->update({ variable_value => $variable_value });
        } else {
            $self->schema->resultset('ThemeVariable')->create({
                theme_id => $theme_id,
                variable_name => $variable_name,
                variable_value => $variable_value
            });
        }
        
        # Mark the site theme as customized if this is a site-specific theme
        my $site_theme = $self->schema->resultset('SiteTheme')->search({ theme_id => $theme_id })->first;
        if ($site_theme) {
            $site_theme->update({ is_customized => 1 });
        }
        
        return 1; # Success
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_theme_variable', 
            "Error updating variable $variable_name for theme $theme_id: $_");
        return 0; # Failure
    };
}

# Create a new theme
sub create_theme {
    my ($self, $c, $theme_data) = @_;
    
    try {
        my $new_theme = $self->schema->resultset('Theme')->create({
            name => $theme_data->{name},
            description => $theme_data->{description},
            base_theme => $theme_data->{base_theme} || 'default',
            is_active => 1
        });
        
        # Copy variables from base theme
        my $base_theme_id = $self->get_theme_by_name($c, $theme_data->{base_theme} || 'default')->id;
        my $base_variables = $self->get_theme_variables($c, $base_theme_id);
        
        foreach my $var_name (keys %$base_variables) {
            $self->schema->resultset('ThemeVariable')->create({
                theme_id => $new_theme->id,
                variable_name => $var_name,
                variable_value => $base_variables->{$var_name}
            });
        }
        
        return $new_theme->id;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_theme', 
            "Error creating theme " . $theme_data->{name} . ": $_");
        return 0; # Failure
    };
}

# Generate CSS for a theme
sub generate_theme_css {
    my ($self, $c, $theme_id) = @_;
    
    try {
        my $theme = $self->get_theme_by_id($c, $theme_id);
        my $variables = $self->get_theme_variables($c, $theme_id);
        
        # Start with CSS variable declarations
        my $css = "/* Theme: " . $theme->name . " */\n";
        $css .= ":root {\n";
        
        # Add each variable
        foreach my $var_name (sort keys %$variables) {
            $css .= "  --$var_name: " . $variables->{$var_name} . ";\n";
        }
        
        $css .= "}\n";
        
        # Add any theme-specific overrides if needed
        if ($theme->name eq 'usbm') {
            $css .= "\n/* USBM specific styles */\n";
            $css .= "body {\n";
            $css .= "  background-color: var(--primary-color);\n";
            $css .= "}\n";
        }
        
        return $css;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'generate_theme_css', 
            "Error generating CSS for theme $theme_id: $_");
        return "/* Error generating theme CSS */";
    };
}

# Create a custom theme for a site
sub create_site_custom_theme {
    my ($self, $c, $site_id, $site_name) = @_;
    
    try {
        # Get current site theme
        my $current_theme_id = $self->get_site_theme($c, $site_id);
        my $current_theme = $self->get_theme_by_id($c, $current_theme_id);
        
        # Create a new theme based on the current one
        my $custom_theme_name = lc($site_name) . "-custom";
        
        # Check if this custom theme already exists
        my $existing_theme = $self->get_theme_by_name($c, $custom_theme_name);
        if ($existing_theme) {
            # If it exists, just set it as the site's theme
            $self->set_site_theme($c, $site_id, $existing_theme->id);
            return $existing_theme->id;
        }
        
        # Create new custom theme
        my $new_theme_id = $self->create_theme($c, {
            name => $custom_theme_name,
            description => "Custom theme for $site_name",
            base_theme => $current_theme->name
        });
        
        # Set as site theme
        $self->set_site_theme($c, $site_id, $new_theme_id);
        
        return $new_theme_id;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_site_custom_theme', 
            "Error creating custom theme for site $site_id: $_");
        return 0; # Failure
    };
}

__PACKAGE__->meta->make_immutable;
1;
