#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON;
use File::Slurp;
use DBI;
use Try::Tiny;
use Data::Dumper;

# Load the database configuration from db_config.json
my $json_text;
{
    local $/;    # Enable 'slurp' mode
    open my $fh, "<", "$FindBin::Bin/../db_config.json" or die "Could not open db_config.json: $!";
    $json_text = <$fh>;
    close $fh;
}
my $config = decode_json($json_text);

# Connect to the database
my $dsn = "DBI:mysql:database=$config->{shanta_ency}->{database};host=$config->{shanta_ency}->{host};port=$config->{shanta_ency}->{port}";
my $dbh = DBI->connect($dsn, $config->{shanta_ency}->{username}, $config->{shanta_ency}->{password}, 
    { RaiseError => 1, AutoCommit => 1, mysql_enable_utf8 => 1 });

print "Connected to database: $config->{shanta_ency}->{database}\n";

# Function to create a table from SQL file
sub create_table_from_sql {
    my ($dbh, $sql_file) = @_;
    
    print "Creating table from SQL file: $sql_file\n";
    
    my $sql = read_file($sql_file);
    
    # Split SQL into statements
    my @statements = split /;/, $sql;
    
    foreach my $statement (@statements) {
        $statement =~ s/^\s+|\s+$//g;  # Trim whitespace
        next unless $statement;  # Skip empty statements
        
        try {
            $dbh->do($statement);
            print "Executed SQL statement successfully\n";
        } catch {
            print "Error executing SQL statement: $_\n";
        };
    }
}

# Create the internal_links_tb table
create_table_from_sql($dbh, "$FindBin::Bin/../sql/internal_links_tb.sql");

# Create the page_tb table
create_table_from_sql($dbh, "$FindBin::Bin/../sql/page_tb.sql");

print "Navigation tables created successfully\n";

# Disconnect from the database
$dbh->disconnect();