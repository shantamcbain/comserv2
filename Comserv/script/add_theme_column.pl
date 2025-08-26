#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Comserv::Schema;
use Try::Tiny;
use DBI;
use Config::General;

# Load configuration
my $config_file = "$FindBin::Bin/../comserv.conf";
my %config = Config::General->new($config_file)->getall;
my $db_config = $config{'Model::DBEncy'};

# Connect to database
my $dsn = $db_config->{connect_info}->{dsn};
my $user = $db_config->{connect_info}->{user};
my $password = $db_config->{connect_info}->{password};

my $dbh = DBI->connect($dsn, $user, $password);

print "Checking if theme column exists in sites table...\n";

# Check if the theme column already exists
my $sth = $dbh->prepare("SHOW COLUMNS FROM sites LIKE 'theme'");
$sth->execute();
my $column_exists = $sth->fetchrow_array();

if ($column_exists) {
    print "Theme column already exists in sites table.\n";
} else {
    print "Adding theme column to sites table...\n";

    # Add the theme column
    try {
        $dbh->do("ALTER TABLE sites ADD COLUMN theme VARCHAR(50) DEFAULT 'default'");
        print "Theme column added successfully.\n";
    } catch {
        die "Error adding theme column: $_\n";
    };
}

# Initialize themes for existing sites
print "Initializing themes for existing sites...\n";

# Read theme mappings from JSON file
my $json_path = "$FindBin::Bin/../root/static/config/theme_mappings.json";
my $theme_mappings = {};

if (-f $json_path) {
    require JSON;
    my $json_text = do {
        open my $fh, '<', $json_path or die "Cannot open $json_path: $!";
        local $/;
        <$fh>;
    };
    $theme_mappings = JSON::decode_json($json_text);
}

# Get all sites
my $sites_sth = $dbh->prepare("SELECT id, name FROM sites");
$sites_sth->execute();

while (my ($id, $name) = $sites_sth->fetchrow_array()) {
    # Determine theme based on site name
    my $theme = 'default';

    # Check if site exists in JSON mappings
    if ($theme_mappings && $theme_mappings->{sites} && $theme_mappings->{sites}{uc($name)}) {
        $theme = $theme_mappings->{sites}{uc($name)};
    } else {
        # Default mappings based on site name
        if (lc($name) eq 'usbm') {
            $theme = 'usbm';
        } elsif (lc($name) eq 'csc') {
            $theme = 'csc';
        } elsif (lc($name) eq 'apis') {
            $theme = 'apis';
        }
    }

    # Update the site's theme
    my $update_sth = $dbh->prepare("UPDATE sites SET theme = ? WHERE id = ?");
    $update_sth->execute($theme, $id);

    print "Set theme for site '$name' to '$theme'\n";
}

print "Theme initialization complete.\n";
