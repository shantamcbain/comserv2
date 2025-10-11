package Comserv::Model::RemoteDB;

use strict;
use warnings;
use Moose;
use namespace::autoclean;
use DBI;
use Try::Tiny;
use Data::Dumper;
use JSON;
use Comserv::Util::Logging;

# Don't extend Catalyst::Model - make this a standalone utility class

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has 'connections' => (
    is      => 'rw',
    isa     => 'HashRef',
    default => sub { {} },
);

has 'config' => (
    is      => 'rw',
    isa     => 'HashRef',
    default => sub { {} },
    lazy    => 1,
);

has 'selected_connection' => (
    is      => 'rw',
    isa     => 'HashRef',
    default => sub { {} },
);

use FindBin;
use File::Spec;

# Load configuration lazily when first needed
sub _load_config {
    my ($self) = @_;
    
    return if keys %{$self->config}; # Already loaded
    
    # Load the database configuration
    my $config;
    try {
        use File::Basename;
        
        # Get the application root directory (one level up from script or lib)
        my $bin_dir = $FindBin::Bin;
        my $app_root;
        
        # If we're in a script directory, go up one level to find app root
        if ($bin_dir =~ /\/script$/) {
            $app_root = dirname($bin_dir);
        }
        # If we're somewhere else, try to find the app root
        else {
            # Check if we're already in the app root
            if (-f "$bin_dir/db_config.json") {
                $app_root = $bin_dir;
            }
            # Otherwise, try one level up
            elsif (-f dirname($bin_dir) . "/db_config.json") {
                $app_root = dirname($bin_dir);
            }
            # If all else fails, assume we're in lib and need to go up one level
            else {
                $app_root = dirname($bin_dir);
            }
        }
        
        my $config_file = "$app_root/db_config.json";
        # Removed the warning since this is now the standard behavior
        
        local $/;
        open my $fh, "<", $config_file or die "Could not open $config_file: $!";
        my $json_text = <$fh>;
        close $fh;
        $config = decode_json($json_text);

        # Store the config for later use by other methods
        $self->config($config);

        # Print the configuration for debugging
        print "RemoteDB Configuration loaded from: $config_file\n";
        print "Found database configurations: " . join(", ", keys %{$config}) . "\n";
        
    } catch {
        warn "Failed to load database configuration: $_";
        die "RemoteDB: Cannot continue without database configuration";
    };
}

# Test database connectivity
sub test_connection {
    my ($self, $connection_config) = @_;
    
    $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'test_connection', 
        "Testing connection: " . ($connection_config->{description} || 'Unknown'));
    
    my $success = 0;
    
    eval {
        require DBI;
        my $dsn;
        my $dbh;
        
        if ($connection_config->{db_type} eq 'sqlite') {
            # SQLite connection
            $dsn = "dbi:SQLite:dbname=" . $connection_config->{database_path};
            warn "SQLite DSN: $dsn";
            $dbh = DBI->connect($dsn, "", "", {
                RaiseError => 0,
                PrintError => 1,
                sqlite_timeout => 5000,
            });
        } else {
            # MySQL connection
            $dsn = "dbi:mysql:database=" . $connection_config->{database} . 
                   ";host=" . $connection_config->{host} . 
                   ";port=" . $connection_config->{port};
            warn "MySQL DSN: $dsn with user: " . $connection_config->{username};
            $dbh = DBI->connect($dsn, $connection_config->{username}, $connection_config->{password}, {
                RaiseError => 0,
                PrintError => 1,
                mysql_connect_timeout => 5,
            });
        }
        
        if ($dbh) {
            warn "Connection successful for: " . ($connection_config->{description} || 'Unknown');
            $dbh->disconnect();
            $success = 1;
        } else {
            warn "Connection failed for: " . ($connection_config->{description} || 'Unknown') . " - Error: " . ($DBI::errstr || 'Unknown error');
        }
    };
    if ($@) {
        warn "Exception during connection test: $@";
    }
    
    return $success;
}

# Select the best database connection for a specific database name
sub select_connection {
    my ($self, $database_name) = @_;
    
    $self->_load_config(); # Ensure config is loaded
    my $config = $self->config;
    
    # Get all connections that serve the specified database
    my @matching_connections = grep {
        my $conn = $config->{$_};
        $conn && ref $conn eq 'HASH' &&
        (($conn->{database} && $conn->{database} eq $database_name) ||
         ($conn->{db_type} eq 'sqlite' && $_ =~ /\Q$database_name\E/))
    } keys %$config;

    # Sort by priority
    @matching_connections = sort {
        ($config->{$a}{priority} // 999) <=> ($config->{$b}{priority} // 999)
    } @matching_connections;
    
    # Debug: Show the connection priority order
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'select_connection',
        "RemoteDB Connection Selection for '$database_name' - Testing in priority order:");
    foreach my $conn_name (@matching_connections) {
        my $priority = $config->{$conn_name}{priority} // 999;
        my $desc = $config->{$conn_name}{description} || 'No description';
        $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'select_connection',
            "  Priority $priority: $conn_name - $desc");
    }

    # Try connections in priority order
    foreach my $conn_name (@matching_connections) {
        my $conn = $config->{$conn_name};

        # Skip if required fields are missing, empty, or contain placeholders
        my $skip = 0;
        
        # Different required fields for different database types
        my @required_fields;
        if ($conn->{db_type} eq 'sqlite') {
            @required_fields = qw/database_path/;
        } else {
            @required_fields = qw/host port username database/;
        }
        
        foreach my $field (@required_fields) {
            if (!exists $conn->{$field} ||
                !defined $conn->{$field} ||
                $conn->{$field} =~ /^\s*$/) {
                warn "Skipping $conn_name: Missing required field '$field'";
                $skip = 1;
                last;
            }
            if ($conn->{$field} =~ /YOUR_|PLACEHOLDER/i) {
                warn "Skipping $conn_name: Field '$field' contains placeholder value";
                $skip = 1;
                last;
            }
        }
        next if $skip;

        # Try the connection
        if ($self->test_connection($conn)) {
            $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'select_connection',
                "RemoteDB: Selected connection $conn_name for database '$database_name' (" . 
                ($conn->{description} || 'no description') . ")");

            # Store the selected connection info
            my $connection_info = {
                connection_name => $conn_name,
                config => $conn,
                database_name => $database_name
            };
            $self->selected_connection->{$database_name} = $connection_info;
            
            return $connection_info;
        }
    }

    # If we get here, no connection worked
    die "RemoteDB: No working database connection found for '$database_name' database after trying " .
        scalar(@matching_connections) . " connections";
}

# Get connection info for a database (select if not already selected)
sub get_connection_info {
    my ($self, $database_name) = @_;
    
    # Return cached connection if available
    if (exists $self->selected_connection->{$database_name}) {
        return $self->selected_connection->{$database_name};
    }
    
    # Otherwise select a new connection
    return $self->select_connection($database_name);
}

# Add a new remote database connection
sub add_connection {
    my ($self, $conn_name, $conn_config) = @_;
    
    # Store the connection config
    $self->connections->{$conn_name} = {
        config => $conn_config,
        dbh    => undef,
    };
    
    return 1;
}

# Get a database handle for a remote connection
sub get_connection {
    my ($self, $c, $conn_name) = @_;
    
    # Check if the connection exists
    unless (exists $self->connections->{$conn_name}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_connection', 
            "Remote connection '$conn_name' does not exist");
        return;
    }
    
    my $conn = $self->connections->{$conn_name};
    
    # If we already have an active connection, return it
    if ($conn->{dbh} && $conn->{dbh}->ping) {
        return $conn->{dbh};
    }
    
    # Otherwise, create a new connection
    my $config = $conn->{config};
    # Fixed DSN format for MySQL - most common format
    my $dsn = "DBI:mysql:database=$config->{database};host=$config->{host};port=$config->{port}";
    
    try {
        $conn->{dbh} = DBI->connect($dsn, $config->{username}, $config->{password}, {
            RaiseError => 1,
            AutoCommit => 1,
            PrintError => 0,
        });
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_connection', 
            "Successfully connected to remote database '$conn_name'");
        
        return $conn->{dbh};
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_connection', 
            "Failed to connect to remote database '$conn_name': $_");
        return;
    };
}

# Execute a query on a remote database
sub execute_query {
    my ($self, $c, $conn_name, $query, $params) = @_;
    
    my $dbh = $self->get_connection($c, $conn_name);
    unless ($dbh) {
        return;
    }
    
    try {
        my $sth = $dbh->prepare($query);
        $sth->execute(@$params);
        
        # For SELECT queries, fetch and return the results
        if ($query =~ /^\s*SELECT/i) {
            my @results;
            while (my $row = $sth->fetchrow_hashref) {
                push @results, $row;
            }
            return \@results;
        }
        
        # For non-SELECT queries, return success
        return { success => 1, rows_affected => $sth->rows };
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'execute_query', 
            "Query execution failed on '$conn_name': $_");
        return { error => $_ };
    };
}

# List tables in a remote database
sub list_tables {
    my ($self, $c, $conn_name) = @_;
    
    my $dbh = $self->get_connection($c, $conn_name);
    unless ($dbh) {
        return;
    }
    
    try {
        my $tables = $dbh->tables(undef, undef, '%', 'TABLE');
        return [map { s/^.*\.//; $_ } @$tables];
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'list_tables', 
            "Failed to list tables for '$conn_name': $_");
        return;
    };
}

# Get table schema for a remote database table
sub get_table_schema {
    my ($self, $c, $conn_name, $table_name) = @_;
    
    my $dbh = $self->get_connection($c, $conn_name);
    unless ($dbh) {
        return;
    }
    
    try {
        my $sth = $dbh->column_info(undef, undef, $table_name, '%');
        my @columns;
        while (my $info = $sth->fetchrow_hashref) {
            push @columns, {
                name     => $info->{COLUMN_NAME},
                type     => $info->{TYPE_NAME},
                nullable => $info->{NULLABLE},
                size     => $info->{COLUMN_SIZE},
            };
        }
        return \@columns;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_table_schema', 
            "Failed to get schema for table '$table_name' in '$conn_name': $_");
        return;
    };
}

__PACKAGE__->meta->make_immutable;
1;