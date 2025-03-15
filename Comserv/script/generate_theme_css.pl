#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Catalyst::ScriptRunner;
use JSON;
use File::Slurp;
use File::Path qw(make_path);

# Run the script
Catalyst::ScriptRunner->run('Comserv', 'GenerateThemeCSS');

package Comserv::Script::GenerateThemeCSS;
use Moose;
use namespace::autoclean;
use Try::Tiny;

extends 'Catalyst::Script';

has 'app' => (
    is => 'ro',
    lazy => 1,
    default => sub { shift->_app },
);

sub run {
    my $self = shift;
    my $app = $self->app;
    
    print "Generating CSS files for all themes...\n";
    
    # Get the theme directory
    my $theme_dir = $app->path_to('root', 'static', 'css', 'themes');
    
    # Create directory if it doesn't exist
    unless (-d $theme_dir) {
        make_path($theme_dir) or die "Cannot create theme directory: $!";
        print "Created theme directory: $theme_dir\n";
    }
    
    # Get theme definitions from JSON
    my $theme_defs_path = $app->path_to('root', 'static', 'config', 'theme_definitions.json');
    my $theme_defs = {};
    
    if (-f $theme_defs_path) {
        try {
            my $json_text = read_file($theme_defs_path);
            $theme_defs = decode_json($json_text);
            print "Read theme definitions from $theme_defs_path\n";
        } catch {
            warn "Error reading theme definitions: $_\n";
        };
    } else {
        warn "Theme definitions file not found: $theme_defs_path\n";
    }
    
    # Generate CSS for each theme
    foreach my $theme_name (keys %$theme_defs) {
        my $theme_data = $theme_defs->{$theme_name};
        my $theme_file = "$theme_dir/$theme_name.css";
        
        print "Generating CSS for theme: $theme_name\n";
        
        # Create CSS content
        my $css = "/* Theme: " . ($theme_data->{name} || ucfirst($theme_name)) . " */\n";
        $css .= "/* Description: " . ($theme_data->{description} || ucfirst($theme_name) . ' Theme') . " */\n\n";
        $css .= ":root {\n";
        
        # Add variables
        if ($theme_data->{variables} && ref $theme_data->{variables} eq 'HASH') {
            foreach my $var (sort keys %{$theme_data->{variables}}) {
                $css .= "  --$var: " . $theme_data->{variables}{$var} . ";\n";
            }
        } else {
            # Default variables if none provided
            $css .= "  --primary-color: #ffffff;\n";
            $css .= "  --secondary-color: #f9f9f9;\n";
            $css .= "  --accent-color: #FF9900;\n";
            $css .= "  --text-color: #000000;\n";
            $css .= "  --background-color: #ffffff;\n";
            $css .= "  --link-color: #0000FF;\n";
            $css .= "  --link-hover-color: #000099;\n";
            $css .= "  --border-color: #dddddd;\n";
            $css .= "  --table-header-bg: #f2f2f2;\n";
            $css .= "  --warning-color: #f39c12;\n";
            $css .= "  --success-color: #27ae60;\n";
        }
        
        $css .= "}\n\n";
        
        # Add special styles if any
        if ($theme_data->{special_styles} && ref $theme_data->{special_styles} eq 'HASH') {
            foreach my $selector (sort keys %{$theme_data->{special_styles}}) {
                $css .= "$selector {\n";
                $css .= "  " . $theme_data->{special_styles}{$selector} . "\n";
                $css .= "}\n\n";
            }
        }
        
        # Write CSS file
        try {
            write_file($theme_file, $css);
            print "Created theme file: $theme_file\n";
        } catch {
            warn "Error creating theme file: $_\n";
        };
    }
    
    # Ensure we have the basic themes
    my @basic_themes = qw(default csc apis usbm);
    foreach my $basic_theme (@basic_themes) {
        my $theme_file = "$theme_dir/$basic_theme.css";
        
        # Skip if the file already exists
        next if -f $theme_file;
        
        print "Creating basic theme file: $theme_file\n";
        
        # Create a minimal CSS file if it doesn't exist
        try {
            my $css = "/* Theme: " . ucfirst($basic_theme) . " */\n";
            $css .= "/* Description: " . ucfirst($basic_theme) . " Theme */\n\n";
            $css .= ":root {\n";
            
            # Add default variables based on theme
            if ($basic_theme eq 'default') {
                $css .= "  --primary-color: #ffffff;\n";
                $css .= "  --secondary-color: #f9f9f9;\n";
                $css .= "  --accent-color: #FF9900;\n";
                $css .= "  --text-color: #000000;\n";
                $css .= "  --link-color: #0000FF;\n";
                $css .= "  --link-hover-color: #000099;\n";
                $css .= "  --background-color: #ffffff;\n";
                $css .= "  --border-color: #dddddd;\n";
                $css .= "  --table-header-bg: #f2f2f2;\n";
                $css .= "  --warning-color: #f39c12;\n";
                $css .= "  --success-color: #27ae60;\n";
            } elsif ($basic_theme eq 'csc') {
                $css .= "  --primary-color: #ccffff;\n";
                $css .= "  --secondary-color: #e6ffff;\n";
                $css .= "  --accent-color: #FF9900;\n";
                $css .= "  --text-color: #000000;\n";
                $css .= "  --link-color: #0000FF;\n";
                $css .= "  --link-hover-color: #000099;\n";
                $css .= "  --background-color: #ffffff;\n";
                $css .= "  --border-color: #99cccc;\n";
                $css .= "  --table-header-bg: #ccffff;\n";
                $css .= "  --warning-color: #f39c12;\n";
                $css .= "  --success-color: #27ae60;\n";
            } elsif ($basic_theme eq 'apis') {
                $css .= "  --primary-color: #FFF8E1;\n";
                $css .= "  --secondary-color: #FFE8B8;\n";
                $css .= "  --accent-color: #FFB900;\n";
                $css .= "  --text-color: #2C2C2C;\n";
                $css .= "  --link-color: #B88A00;\n";
                $css .= "  --link-hover-color: #805F00;\n";
                $css .= "  --background-color: #FFF8E1;\n";
                $css .= "  --border-color: #FFD54F;\n";
                $css .= "  --table-header-bg: #FFE082;\n";
                $css .= "  --warning-color: #f39c12;\n";
                $css .= "  --success-color: #27ae60;\n";
            } elsif ($basic_theme eq 'usbm') {
                $css .= "  --primary-color: #009933;\n";
                $css .= "  --secondary-color: #00cc44;\n";
                $css .= "  --accent-color: #006622;\n";
                $css .= "  --text-color: #333333;\n";
                $css .= "  --link-color: #006622;\n";
                $css .= "  --link-hover-color: #004d1a;\n";
                $css .= "  --background-color: #ffffff;\n";
                $css .= "  --border-color: #00cc44;\n";
                $css .= "  --table-header-bg: #00cc44;\n";
                $css .= "  --warning-color: #f39c12;\n";
                $css .= "  --success-color: #27ae60;\n";
            }
            
            $css .= "}\n\n";
            
            # Add special styles for APIS theme
            if ($basic_theme eq 'apis') {
                $css .= "body {\n";
                $css .= "  background-image: linear-gradient(30deg, #FFF8E1 12%, transparent 12.5%, transparent 87%, #FFF8E1 87.5%, #FFF8E1),\n";
                $css .= "                    linear-gradient(150deg, #FFF8E1 12%, transparent 12.5%, transparent 87%, #FFF8E1 87.5%, #FFF8E1),\n";
                $css .= "                    linear-gradient(30deg, #FFF8E1 12%, transparent 12.5%, transparent 87%, #FFF8E1 87.5%, #FFF8E1),\n";
                $css .= "                    linear-gradient(150deg, #FFF8E1 12%, transparent 12.5%, transparent 87%, #FFF8E1 87.5%, #FFF8E1),\n";
                $css .= "                    linear-gradient(60deg, #FFE8B8 25%, transparent 25.5%, transparent 75%, #FFE8B8 75%, #FFE8B8),\n";
                $css .= "                    linear-gradient(60deg, #FFE8B8 25%, transparent 25.5%, transparent 75%, #FFE8B8 75%, #FFE8B8);\n";
                $css .= "  background-size: 40px 70px;\n";
                $css .= "  background-position: 0 0, 0 0, 20px 35px, 20px 35px, 0 0, 20px 35px;\n";
                $css .= "}\n";
            }
            
            write_file($theme_file, $css);
            print "Created basic theme file: $theme_file\n";
        } catch {
            warn "Error creating basic theme file: $_\n";
        };
    }
    
    print "Done generating CSS files for all themes.\n";
}

__PACKAGE__->meta->make_immutable;
1;#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Comserv::Util::ThemeManager;
use Catalyst::Test 'Comserv';

# Initialize logging
use Comserv::Util::Logging;
Comserv::Util::Logging::init();

# Create a mock context
my $c = Catalyst::Test::get_context();

# Create a theme manager
my $theme_manager = Comserv::Util::ThemeManager->new;

# Generate CSS files for all themes
print "Generating CSS files for all themes...\n";
my $result = $theme_manager->generate_all_theme_css($c);

if ($result) {
    print "Successfully generated CSS files for all themes.\n";
} else {
    print "Error generating CSS files for all themes.\n";
}