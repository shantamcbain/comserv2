#!/usr/bin/perl
use strict;
use warnings;
use DBI;
use JSON;
use File::Spec;
use FindBin;

print "FindBin::Bin: $FindBin::Bin\n";
print "Script directory: " . $0 . "\n\n";

# Test config loading like RemoteDB does
my $config_file;

if (-f '/opt/comserv/db_config.json') {
    $config_file = '/opt/comserv/db_config.json';
    print "Using Docker path: $config_file\n";
} elsif ($ENV{COMSERV_DB_CONFIG}) {
    $config_file = $ENV{COMSERV_DB_CONFIG};
    print "Using ENV var: $config_file\n";
} else {
    my $relative_path = File::Spec->catfile($FindBin::Bin, '../db_config.json');
    if (-f $relative_path) {
        $config_file = $relative_path;
        print "Using FindBin fallback: $config_file\n";
    }
}

unless ($config_file) {
    print "ERROR: Could not locate db_config.json\n";
    exit 1;
}

unless (-r $config_file) {
    print "ERROR: db_config.json not readable\n";
    exit 1;
}

print "Config file resolved to: $config_file\n\n";

# Load and parse config
open my $fh, '<', $config_file or die "Cannot open: $!";
local $/;
my $json_text = <$fh>;
close $fh;
my $config = decode_json($json_text);

print "Config loaded. Testing connection selection for 'ency' database:\n\n";

# Simulate select_connection('ency')
my $database_name = 'ency';
my @matching_connections = grep {
    my $conn = $config->{$_};
    $conn && ref $conn eq 'HASH' &&
    (($conn->{database} && $conn->{database} eq $database_name) ||
     ((defined $conn->{db_type} && $conn->{db_type} eq 'sqlite') && $_ =~ /\Q$database_name\E/))
} keys %$config;

print "Matching connections for '$database_name':\n";
foreach my $conn_name (@matching_connections) {
    my $priority = $config->{$conn_name}{priority} // 999;
    my $desc = $config->{$conn_name}{description} || 'No description';
    print "  Priority $priority: $conn_name - $desc\n";
}

# Sort by priority
@matching_connections = sort {
    ($config->{$a}{priority} // 999) <=> ($config->{$b}{priority} // 999)
} @matching_connections;

print "\nSorted priority order:\n";
foreach (@matching_connections) {
    my $priority = $config->{$_}{priority} // 999;
    print "  $priority: $_\n";
}

print "\nAttempting connections in order:\n";

foreach my $conn_name (@matching_connections) {
    my $conn = $config->{$conn_name};
    my $host = $conn->{host} || 'N/A';
    my $port = $conn->{port} || 'N/A';
    my $desc = $conn->{description} || 'no description';
    
    # Check for localhost_override
    if ($conn->{localhost_override}) {
        unless ($ENV{COMSERV_ALLOW_LOCALHOST_OVERRIDE}) {
            print "\n  SKIP: $conn_name (localhost_override=true, env not set)\n";
            next;
        }
    }
    
    # Check required fields
    my @required_fields;
    if (defined $conn->{db_type} && $conn->{db_type} eq 'sqlite') {
        @required_fields = qw/database_path/;
    } else {
        @required_fields = qw/host port username database/;
    }
    
    my $skip = 0;
    foreach my $field (@required_fields) {
        if (!exists $conn->{$field} ||
            !defined $conn->{$field} ||
            $conn->{$field} =~ /^\s*$/) {
            print "\n  SKIP: $conn_name (missing field '$field')\n";
            $skip = 1;
            last;
        }
        if ($conn->{$field} =~ /YOUR_|PLACEHOLDER/i) {
            print "\n  SKIP: $conn_name (placeholder in '$field')\n";
            $skip = 1;
            last;
        }
    }
    next if $skip;
    
    print "\n  TESTING: $conn_name at $host:$port ($desc)\n";
    
    # Build DSN like RemoteDB does
    my $db_type = $conn->{db_type} || 'mysql';
    my $driver = $db_type;
    if ($driver eq 'mariadb') { $driver = 'MariaDB'; }
    
    # Check driver availability
    if ($driver eq 'MariaDB') {
        my $available = 0;
        eval { require DBD::MariaDB; $available = 1; };
        if (!$available) {
            eval { require DBD::mysql; $driver = 'mysql'; };
        }
    }
    
    print "    Driver: $driver\n";
    
    if ($db_type eq 'sqlite') {
        my $dsn = "dbi:SQLite:dbname=" . $conn->{database_path};
        print "    DSN: $dsn\n";
        my $dbh = DBI->connect($dsn, "", "", {
            RaiseError => 0,
            PrintError => 0,
            sqlite_timeout => 5000,
        });
        if ($dbh) {
            print "    ✓ SUCCESS\n";
            $dbh->disconnect();
            last;
        } else {
            print "    ✗ FAILED: $DBI::errstr\n";
        }
    } else {
        my $dsn = "dbi:$driver:database=" . $conn->{database} . 
                  ";host=" . $conn->{host} . 
                  ";port=" . $conn->{port};
        print "    DSN: $dsn\n";
        print "    User: " . $conn->{username} . "\n";
        
        my $dbh = DBI->connect($dsn, $conn->{username}, $conn->{password}, {
            RaiseError => 0,
            PrintError => 0,
            mysql_connect_timeout => 5,
        });
        if ($dbh) {
            print "    ✓ SUCCESS\n";
            $dbh->disconnect();
            last;
        } else {
            print "    ✗ FAILED: $DBI::errstr\n";
        }
    }
}

print "\nDone.\n";
