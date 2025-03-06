#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Comserv::Schema;
use DBI;
use Config::JSON;

# Load the configuration
my $config_file = "$FindBin::Bin/../comserv.json";
my $config = Config::JSON->new($config_file);

# Get database connection details from config
my $dsn = $config->get('Model::DBEncy/connect_info/0');
my $user = $config->get('Model::DBEncy/connect_info/1');
my $pass = $config->get('Model::DBEncy/connect_info/2');

# Connect to the database
my $dbh = DBI->connect($dsn, $user, $pass, { RaiseError => 1, PrintError => 0 });

# Check if the theme column already exists
my $sth = $dbh->prepare("SHOW COLUMNS FROM sites LIKE 'theme'");
$sth->execute();
my $column_exists = $sth->fetchrow_array();

if ($column_exists) {
    print "The 'theme' column already exists in the 'sites' table.\n";
} else {
    # Add the theme column to the sites table
    $dbh->do("ALTER TABLE sites ADD COLUMN theme VARCHAR(50) DEFAULT 'default'");
    print "Added 'theme' column to the 'sites' table with default value 'default'.\n";
}

# Close the database connection
$dbh->disconnect();

print "Script completed successfully.\n";#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use DBI;
use Config::General;
use Try::Tiny;

# Load configuration
my $config_file = "$FindBin::Bin/../comserv.conf";
my %config = Config::General->new($config_file)->getall;

# Database connection details
my $db_name = $config{Model}{DBEncy}{schema_class} || 'ency';
my $db_user = $config{Model}{DBEncy}{connect_info}{user} || 'root';
my $db_pass = $config{Model}{DBEncy}{connect_info}{password} || '';
my $db_host = $config{Model}{DBEncy}{connect_info}{host} || 'localhost';

# Connect to the database
my $dsn = "DBI:mysql:database=$db_name;host=$db_host";
my $dbh = DBI->connect($dsn, $db_user, $db_pass, { RaiseError => 1, PrintError => 0 });

print "Connected to database: $db_name\n";

# Check if the theme column already exists
my $sth = $dbh->prepare("SHOW COLUMNS FROM sites LIKE 'theme'");
$sth->execute();
my $column_exists = $sth->fetchrow_array();

if ($column_exists) {
    print "The 'theme' column already exists in the 'sites' table.\n";
} else {
    # Add the theme column to the sites table
    print "Adding 'theme' column to 'sites' table...\n";
    
    try {
        $dbh->do("ALTER TABLE sites ADD COLUMN theme VARCHAR(50) DEFAULT 'default'");
        print "Successfully added 'theme' column to 'sites' table.\n";
    } catch {
        die "Error adding column: $_\n";
    };
}

# Disconnect from the database
$dbh->disconnect();
print "Database migration completed.\n";