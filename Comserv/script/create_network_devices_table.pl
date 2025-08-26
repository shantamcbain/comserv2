#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Comserv::Model::Schema::Ency;
use DBI;
use JSON;
use File::Spec;

# Load database configuration
my $config_file = File::Spec->catfile($FindBin::Bin, '..', 'db_config.json');
my $json_text;
{
    local $/; # Enable 'slurp' mode
    open my $fh, "<", $config_file or die "Could not open $config_file: $!";
    $json_text = <$fh>;
    close $fh;
}
my $config = decode_json($json_text);

# Connect to the database
my $dsn = "dbi:mysql:database=$config->{shanta_ency}->{database};host=$config->{shanta_ency}->{host};port=$config->{shanta_ency}->{port}";
my $dbh = DBI->connect(
    $dsn,
    $config->{shanta_ency}->{username},
    $config->{shanta_ency}->{password},
    { RaiseError => 1, mysql_enable_utf8 => 1 }
) or die "Could not connect to database: $DBI::errstr";

print "Connected to database successfully.\n";

# Check if the table already exists
my $table_exists = $dbh->selectrow_array("SHOW TABLES LIKE 'network_devices'");
if ($table_exists) {
    print "Table 'network_devices' already exists. Skipping creation.\n";
} else {
    # Create the network_devices table
    print "Creating 'network_devices' table...\n";
    
    my $create_table_sql = q{
        CREATE TABLE network_devices (
            id INT AUTO_INCREMENT PRIMARY KEY,
            device_name VARCHAR(255) NOT NULL,
            ip_address VARCHAR(45) NOT NULL,
            mac_address VARCHAR(45),
            device_type VARCHAR(100),
            location VARCHAR(255),
            purpose VARCHAR(255),
            notes TEXT,
            site_name VARCHAR(100) NOT NULL,
            created_at DATETIME,
            updated_at DATETIME
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    };
    
    $dbh->do($create_table_sql) or die "Could not create table: $DBI::errstr";
    print "Table 'network_devices' created successfully.\n";
    
    # Insert sample data
    print "Inserting sample data...\n";
    
    my $insert_sql = q{
        INSERT INTO network_devices 
        (device_name, ip_address, mac_address, device_type, location, purpose, notes, site_name, created_at)
        VALUES 
        (?, ?, ?, ?, ?, ?, ?, ?, NOW())
    };
    
    my $sth = $dbh->prepare($insert_sql);
    
    # Sample data
    my @sample_devices = (
        ['Main Router', '192.168.1.1', '00:11:22:33:44:55', 'Router', 'Server Room', 'Main internet gateway', 'Cisco router providing internet access and firewall', 'CSC'],
        ['Core Switch', '192.168.1.2', '00:11:22:33:44:56', 'Switch', 'Server Room', 'Core network switch', 'Cisco Catalyst 9300 Series', 'CSC'],
        ['Office AP', '192.168.1.3', '00:11:22:33:44:57', 'Access Point', 'Main Office', 'Wireless access', 'Cisco Meraki MR Series', 'CSC'],
        ['MCOOP Router', '10.0.0.1', '00:11:22:33:44:58', 'Router', 'MCOOP Office', 'Main router for MCOOP', 'Ubiquiti EdgeRouter', 'MCOOP'],
        ['MCOOP Switch', '10.0.0.2', '00:11:22:33:44:59', 'Switch', 'MCOOP Office', 'Network switch for MCOOP', 'Ubiquiti EdgeSwitch', 'MCOOP'],
        ['BMaster Server', '172.16.0.10', '00:11:22:33:44:60', 'Server', 'BMaster Office', 'Main server for BMaster', 'Dell PowerEdge R740', 'BMaster']
    );
    
    foreach my $device (@sample_devices) {
        $sth->execute(@$device) or die "Could not insert sample data: $DBI::errstr";
    }
    
    print "Sample data inserted successfully.\n";
}

# Disconnect from the database
$dbh->disconnect();
print "Disconnected from database.\n";
print "Script completed successfully.\n";