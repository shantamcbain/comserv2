#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Comserv::Schema;
use Try::Tiny;
use DBI;
use Config::General;
use Data::Dumper;

# Load configuration
my $config_file = "$FindBin::Bin/../comserv.conf";
my %config = Config::General->new($config_file)->getall;
my $db_config = $config{'Model::DBEncy'};

# Connect to database
my $dsn = $db_config->{connect_info}->{dsn};
my $user = $db_config->{connect_info}->{user};
my $password = $db_config->{connect_info}->{password};

my $schema = Comserv::Schema->connect($dsn, $user, $password);

print "Starting migration to theme system...\n";

# Create theme tables if they don't exist
print "Creating theme tables...\n";
my $dbh = DBI->connect($dsn, $user, $password);
my $sql = do { local $/; open my $fh, '<', "$FindBin::Bin/create_theme_tables.sql"; <$fh> };
my @statements = split /;/, $sql;
foreach my $statement (@statements) {
    next unless $statement =~ /\S/;
    try {
        $dbh->do($statement);
    } catch {
        print "Error executing SQL: $_\n";
    };
}

# Get all sites
print "Migrating sites to theme system...\n";
my @sites = $schema->resultset('Site')->all;

foreach my $site (@sites) {
    print "Processing site: " . $site->name . "\n";
    
    # Determine which theme to use based on site name
    my $theme_name = 'default';
    if (lc($site->name) eq 'usbm') {
        $theme_name = 'usbm';
    } elsif (lc($site->name) eq 'csc') {
        $theme_name = 'csc';
    }
    
    # Get theme ID
    my $theme = $schema->resultset('Theme')->find({ name => $theme_name });
    unless ($theme) {
        print "  Theme $theme_name not found, using default\n";
        $theme = $schema->resultset('Theme')->find({ name => 'default' });
    }
    
    # Check if site already has a theme
    my $site_theme = $schema->resultset('SiteTheme')->find({ site_id => $site->id });
    if ($site_theme) {
        print "  Site already has theme: " . $theme->name . "\n";
    } else {
        # Assign theme to site
        try {
            $schema->resultset('SiteTheme')->create({
                site_id => $site->id,
                theme_id => $theme->id,
                is_customized => 0
            });
            print "  Assigned theme: " . $theme->name . "\n";
        } catch {
            print "  Error assigning theme: $_\n";
        };
    }
}

print "Migration complete!\n";