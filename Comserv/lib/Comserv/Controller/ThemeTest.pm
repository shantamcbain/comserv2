package Comserv::Controller::ThemeTest;

use Moose;
use namespace::autoclean;
use Try::Tiny;
use File::Slurp;
use File::Path qw(make_path);
use Data::Dumper;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

__PACKAGE__->config(namespace => 'themetest');

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# Simple test page that doesn't require authentication
sub index :Path :Args(0) {
    my ($self, $c) = @_;

    # Log that we've entered the index method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "***** THEMETEST INDEX METHOD CALLED *****");

    # Set the template to our simple test page
    $c->stash->{template} = 'themetest.tt';

    # Log that we're rendering the template
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "***** RENDERING TEMPLATE: themetest.tt *****");
}

# Test CSS editor that doesn't require authentication
sub edit_css :Path('edit_css') :Args(1) {
    my ($self, $c, $theme_name) = @_;
    
    # Log that we've entered the edit_css method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_css', "***** THEMETEST EDIT_CSS METHOD CALLED FOR $theme_name *****");
    
    # Get the theme CSS file path
    my $theme_css_path = $c->path_to('root', 'static', 'css', 'themes', "$theme_name.css");
    
    # Check if the theme CSS file exists
    unless (-f $theme_css_path) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_css', "Theme CSS file not found: $theme_css_path");
        
        # Create the directory if it doesn't exist
        my $themes_dir = $c->path_to('root', 'static', 'css', 'themes');
        unless (-d $themes_dir) {
            make_path($themes_dir) or do {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_css', "Cannot create themes directory: $!");
                $c->stash->{error_msg} = "Cannot create themes directory: $!";
                $c->stash->{template} = 'admin/theme/edit_css.tt';
                return;
            };
        }
        
        # Create an empty file for this theme
        open my $fh, '>', $theme_css_path or do {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_css', "Cannot create theme file: $!");
            $c->stash->{error_msg} = "Cannot create theme file: $!";
            $c->stash->{template} = 'admin/theme/edit_css.tt';
            return;
        };
        close $fh;
    }
    
    # If this is a POST request, update the CSS file
    if ($c->request->method eq 'POST') {
        my $css_content = $c->request->params->{css_content};
        
        # Write the updated CSS to the file
        try {
            # Update the theme CSS file
            write_file($theme_css_path, $css_content);
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_css', 
                "Successfully updated CSS for theme: $theme_name");
            
            # Also update the main CSS file for backward compatibility
            my $main_css_file = $c->path_to('root', 'static', 'css', "$theme_name.css");
            if (-f $main_css_file) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_css', 
                    "Updating main CSS file for backward compatibility: $main_css_file");
                write_file($main_css_file, $css_content);
            }
            
            # Check if the CSS contains a background image
            if ($css_content =~ /background-image\s*:\s*url\(['"]?([^'")]+)['"]?\)/i) {
                my $bg_image = $1;
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_css', 
                    "Found background image in CSS: $bg_image");
                
                # Update the theme_definitions.json file to include the background image
                my $themes = $c->model('ThemeConfig')->get_all_themes($c);
                if (exists $themes->{$theme_name}) {
                    # Extract the body styles
                    if ($css_content =~ /body\s*{([^}]+)}/i) {
                        my $body_styles = $1;
                        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_css', 
                            "Found body styles: $body_styles");
                        
                        # Update the special_styles section
                        $themes->{$theme_name}->{special_styles} = {
                            body => $body_styles
                        };
                        
                        # Save the updated theme definitions
                        my $theme_defs_path = $c->path_to('root', 'static', 'config', 'theme_definitions.json');
                        require JSON;
                        my $json = JSON::encode_json($themes);
                        write_file($theme_defs_path, $json);
                        
                        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_css', 
                            "Updated theme_definitions.json with background image");
                    }
                }
            }
            
            $c->stash->{message} = "Theme CSS updated successfully";
        } catch {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_css', 
                "Error updating CSS for theme $theme_name: $_");
            $c->stash->{error_msg} = "Error updating CSS: $_";
        };
    }
    
    # Read the current CSS content
    my $css_content = read_file($theme_css_path);
    
    # Pass data to template
    $c->stash->{theme_name} = $theme_name;
    $c->stash->{css_content} = $css_content;
    $c->stash->{template} = 'admin/theme/edit_css.tt';
}

# Help page
sub help :Path('help') :Args(0) {
    my ($self, $c) = @_;
    
    # Log that we've entered the help method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'help', 
        "***** THEMETEST HELP METHOD CALLED *****");
    
    # Set the template
    $c->stash->{template} = 'admin/theme/help.tt';
}

__PACKAGE__->meta->make_immutable;
1;