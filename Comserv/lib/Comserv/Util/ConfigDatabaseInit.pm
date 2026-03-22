package Comserv::Util::ConfigDatabaseInit;

use strict;
use warnings;
use DBI;
use Try::Tiny;
use Data::Dumper;

=head1 NAME

Comserv::Util::ConfigDatabaseInit - Initialize configuration database on app startup

=head1 DESCRIPTION

Manages the initialization of the local MySQL config database that stores database connection configurations.
Called during application startup to ensure the database and required tables exist.

=head1 METHODS

=head2 initialize()

Initialize config database connection and create tables if needed.

  Comserv::Util::ConfigDatabaseInit->initialize();

=cut

sub initialize {
    my ($class) = @_;
    
    my $host = $ENV{CONFIG_DB_HOST} || 'config-db';
    my $port = $ENV{CONFIG_DB_PORT} || 3306;
    my $user = $ENV{CONFIG_DB_USER} || 'comserv_config';
    my $pass = $ENV{CONFIG_DB_PASSWORD} || 'config_dev_password';
    my $db = $ENV{CONFIG_DB_NAME} || 'comserv_config';
    
    my $dsn = "DBI:mysql:database=$db;host=$host;port=$port";
    
    try {
        my $dbh = DBI->connect($dsn, $user, $pass, { 
            RaiseError => 1, 
            PrintError => 0,
            mysql_enable_utf8mb4 => 1,
        }) or die "Failed to connect to config database: $DBI::errstr";
        
        $class->_create_tables($dbh);
        $class->_import_dbi_config($dbh);
        $dbh->disconnect;
        
        warn "ConfigDatabaseInit: Initialization successful";
        return 1;
    }
    catch {
        warn "ConfigDatabaseInit: Error during initialization: $_";
        return 0;
    };
}

sub _create_tables {
    my ($class, $dbh) = @_;
    
    my $create_connections_table = q{
        CREATE TABLE IF NOT EXISTS database_connections (
            id INT AUTO_INCREMENT PRIMARY KEY,
            connection_name VARCHAR(255) NOT NULL UNIQUE,
            db_host VARCHAR(255) NOT NULL,
            db_port INT NOT NULL DEFAULT 3306,
            db_username VARCHAR(255) NOT NULL,
            db_password VARCHAR(255) NOT NULL,
            db_database VARCHAR(255) NOT NULL,
            is_default TINYINT NOT NULL DEFAULT 0,
            is_active TINYINT NOT NULL DEFAULT 1,
            notes TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            INDEX idx_is_default (is_default),
            INDEX idx_is_active (is_active)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    };
    
    try {
        $dbh->do($create_connections_table);
        warn "ConfigDatabaseInit: database_connections table ready";
    }
    catch {
        warn "ConfigDatabaseInit: Error creating database_connections table: $_";
        die $_;
    };
}

sub _import_dbi_config {
    my ($class, $dbh) = @_;
    
    my $dbi_config_file;
    
    # Check multiple locations for dbi_config.json
    foreach my $path ('/opt/comserv/dbi_config.json', './dbi_config.json', 
                      '/opt/comserv/Comserv/dbi_config.json') {
        if (-f $path && -r $path) {
            $dbi_config_file = $path;
            last;
        }
    }
    
    return unless $dbi_config_file;
    
    try {
        use JSON;
        use File::Slurp qw(read_file write_file);
        
        warn "ConfigDatabaseInit: Found dbi_config.json at $dbi_config_file, importing...";
        
        my $json_text = read_file($dbi_config_file);
        my $config = decode_json($json_text);
        
        foreach my $conn_name (keys %$config) {
            next if $conn_name =~ /^_/;
            next unless ref $config->{$conn_name} eq 'HASH';
            
            my $conn = $config->{$conn_name};
            my $host = $conn->{host} || $conn->{db_host} || 'localhost';
            my $port = $conn->{port} || $conn->{db_port} || 3306;
            my $user = $conn->{username} || $conn->{db_username} || '';
            my $pass = $conn->{password} || $conn->{db_password} || '';
            my $database = $conn->{database} || $conn->{db_database} || '';
            
            my $check_sql = q{
                SELECT COUNT(*) FROM database_connections 
                WHERE connection_name = ?
            };
            my $check_sth = $dbh->prepare($check_sql);
            $check_sth->execute($conn_name);
            my ($count) = $check_sth->fetchrow_array;
            $check_sth->finish;
            
            if ($count == 0) {
                my $insert_sql = q{
                    INSERT INTO database_connections 
                    (connection_name, db_host, db_port, db_username, db_password, db_database, is_active)
                    VALUES (?, ?, ?, ?, ?, ?, 1)
                };
                my $sth = $dbh->prepare($insert_sql);
                $sth->execute($conn_name, $host, $port, $user, $pass, $database);
                $sth->finish;
                
                warn "ConfigDatabaseInit: Imported connection '$conn_name'";
            } else {
                warn "ConfigDatabaseInit: Connection '$conn_name' already exists, skipping";
            }
        }
        
        unlink $dbi_config_file;
        warn "ConfigDatabaseInit: Deleted dbi_config.json after import";
    }
    catch {
        warn "ConfigDatabaseInit: Error importing dbi_config.json: $_";
    };
}

1;
