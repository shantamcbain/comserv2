#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Path qw(make_path);

# Path to the theme_mappings.json file
my $json_path = "$FindBin::Bin/../root/static/config/theme_mappings.json";
my $config_dir = "$FindBin::Bin/../root/static/config";
my $themes_dir = "$FindBin::Bin/../root/static/css/themes";

# Make sure the directories exist
unless (-d $config_dir) {
    print "Creating config directory: $config_dir\n";
    make_path($config_dir) or die "Cannot create directory: $!";
}

unless (-d $themes_dir) {
    print "Creating themes directory: $themes_dir\n";
    make_path($themes_dir) or die "Cannot create directory: $!";
}

# Set permissions on directories
print "Setting permissions on config directory\n";
chmod(0777, $config_dir) or warn "Cannot set permissions on config directory: $!";

print "Setting permissions on themes directory\n";
chmod(0777, $themes_dir) or warn "Cannot set permissions on themes directory: $!";

# Check if the file exists
if (-f $json_path) {
    print "Setting permissions on theme_mappings.json\n";
    chmod(0666, $json_path) or die "Cannot set permissions on file: $!";
    print "Permissions set successfully on $json_path\n";
} else {
    # Create a default mapping file
    print "Creating default theme_mappings.json file\n";
    
    my $default_json = <<'JSON';
{
    "sites": {
        "CSC": "csc",
        "USBM": "usbm",
        "APIS": "apis",
        "DEFAULT": "default"
    },
    "metadata": {
        "version": "1.0",
        "last_updated": "2024-06-01T12:00:00Z",
        "description": "Centralized theme mapping for Comserv sites"
    }
}
JSON
    
    open(my $fh, '>', $json_path) or die "Cannot open file for writing: $!";
    print $fh $default_json;
    close($fh);
    
    print "Default theme_mappings.json file created\n";
    
    # Set permissions on the new file
    chmod(0666, $json_path) or die "Cannot set permissions on file: $!";
    print "Permissions set successfully on $json_path\n";
}

print "Done!\n";