#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use DBI;
use JSON;
use File::Slurp;

# Load database configuration
my $config_file = "$FindBin::Bin/../db_config.json";
unless (-f $config_file) {
    die "Database configuration file not found: $config_file\n";
}

my $config_json = read_file($config_file);
my $config = decode_json($config_json);
my $db_config = $config->{shanta_ency};

# Connect to database
my $dsn = "DBI:mysql:database=$db_config->{database};host=$db_config->{host};port=$db_config->{port}";
my $dbh = DBI->connect($dsn, $db_config->{username}, $db_config->{password}, {
    RaiseError => 1,
    AutoCommit => 1,
    mysql_enable_utf8 => 1,
}) or die "Cannot connect to database: $DBI::errstr\n";

print "Connected to database: $db_config->{database}\n";

# Read and execute the SQL migration script
my $sql_file = "$FindBin::Bin/fix_herb_column_sizes.sql";
unless (-f $sql_file) {
    die "SQL migration file not found: $sql_file\n";
}

my $sql_content = read_file($sql_file);

# Split SQL statements and execute them
my @statements = split /;/, $sql_content;

foreach my $statement (@statements) {
    $statement =~ s/^\s+|\s+$//g; # Trim whitespace
    next if $statement =~ /^--/ || $statement eq '' || $statement =~ /^USE\s+/i; # Skip comments, empty lines, and USE statements
    
    print "Executing: " . substr($statement, 0, 80) . "...\n";
    
    eval {
        $dbh->do($statement);
        print "Success!\n";
    };
    if ($@) {
        print "Error: $@\n";
    }
}

# Show the updated table structure
print "\nUpdated table structure:\n";
my $sth = $dbh->prepare("DESCRIBE ency_herb_tb");
$sth->execute();

while (my $row = $sth->fetchrow_hashref()) {
    if ($row->{Field} =~ /^(distribution|flowers|contra_indications|preparation|odour|solvents|sister_plants|pollinator|apis)$/) {
        print "$row->{Field}: $row->{Type}\n";
    }
}

$dbh->disconnect();
print "\nDatabase migration completed!\n";