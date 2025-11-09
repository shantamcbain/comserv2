package Comserv::Model::RemoteDB;

use strict;
use warnings;
use Moose;
use namespace::autoclean;
use List::Util qw(any);
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
        
        # Detect config file location based on runtime environment
        my $config_file;
        
        # Priority 1: Docker/Kubernetes container path
        if (-f '/opt/comserv/db_config.json') {
            $config_file = '/opt/comserv/db_config.json';
        }
        # Priority 2: Environment variable override (for Kubernetes Secrets, etc)
        elsif ($ENV{COMSERV_DB_CONFIG}) {
            $config_file = $ENV{COMSERV_DB_CONFIG};
        }
        # Priority 3: Relative path from FindBin (local development on host)
        else {
            my $relative_path = File::Spec->catfile($FindBin::Bin, '../db_config.json');
            if (-f $relative_path) {
                $config_file = $relative_path;
            }
        }
        
        die "Could not locate db_config.json in any known location" unless $config_file;
        die "db_config.json not readable: $config_file" unless -r $config_file;
        
        # Read and decode the JSON config
        local $/;
        open my $fh, "<", $config_file or die "Could not open $config_file: $!";
        my $json_text = <$fh>;
        close $fh;
        $config = decode_json($json_text);

        # Apply environment variable overrides (for Docker/Kubernetes environments)
        # This allows credentials and hostnames to be set via environment without changing db_config.json
        $config = $self->_apply_env_overrides($config);
        
        # Store the raw config and expose a normalized contract via get_all_connections
        $self->config($config);

        # Lightweight logging
        $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'RemoteDB::_load_config',
            "Loaded config from $config_file with keys: " . join(', ', keys %$config));
        
    } catch {
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'RemoteDB::_load_config',
            "Failed to load database configuration: $_");
        die "RemoteDB: Cannot continue without database configuration";
    };
}

# Apply environment variable overrides to configuration
# Supports Docker/Kubernetes deployments where credentials/hosts come from environment
sub _apply_env_overrides {
    my ($self, $config) = @_;
    return $config unless $config;
    
    # Environment variable pattern: COMSERV_DB_<CONNECTION_NAME>_<FIELD>
    # Example: COMSERV_DB_PRODUCTION_SERVER_HOST=mydbhost
    #          COMSERV_DB_PRODUCTION_SERVER_PORT=3307
    #          COMSERV_DB_PRODUCTION_SERVER_USERNAME=appuser
    
    foreach my $conn_name (keys %$config) {
        next if $conn_name =~ /^_/;
        next unless ref $config->{$conn_name} eq 'HASH';
        
        my $conn = $config->{$conn_name};
        my $env_prefix = 'COMSERV_DB_' . uc($conn_name);
        
        # Check for field overrides
        foreach my $field (qw(host port username password database)) {
            my $env_var = $env_prefix . '_' . uc($field);
            if (defined $ENV{$env_var}) {
                $conn->{$field} = $ENV{$env_var};
                $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_apply_env_overrides',
                    "Override $env_var for connection '$conn_name'");
            }
        }
    }
    
    return $config;
}

# Public API: return all configured connections in a stable contract
sub get_all_connections {
    my ($self) = @_;
    $self->_load_config();
    my $config = $self->config or return {};

    # Normalize into a stable contract: servers with databases
    my %servers;
    foreach my $conn_name (keys %$config) {
        next if $conn_name =~ /^_/;

        my $conn = $config->{$conn_name};
        next unless ref $conn eq 'HASH';

        # Skip obviously placeholder/test entries
        if (exists $conn->{host} && defined $conn->{host}) {
            if ($conn->{host} =~ /YOUR_|PLACEHOLDER/i) {
                $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'get_all_connections',
                    "Skipping placeholder connection '$conn_name' (host: $conn->{host})");
                next;
            }
        }
        # End skip

        # Determine server group
        my $server_group = 'other';
        if ($conn_name =~ /^production/) { $server_group = 'production' }
        elsif ($conn_name =~ /^zerotier/) { $server_group = 'zerotier' }
        elsif ($conn_name =~ /^local/) { $server_group = 'local' }
        elsif ($conn_name =~ /^sqlite/) { $server_group = 'sqlite' }
        elsif ($conn_name =~ /^backup/) { $server_group = 'backup' }

        $servers{$server_group}->{display_name} ||= ucfirst($server_group) . " Server";
        $servers{$server_group}->{host} ||= $conn->{host} || 'localhost';
        $servers{$server_group}->{connection_type} ||= $conn->{db_type} || 'mysql';
        $servers{$server_group}->{priority} ||= $conn->{priority} || 999;
        $servers{$server_group}->{databases} ||= {};

        my $database_name = $conn->{database} || $conn->{database_path} || $conn_name;
        $servers{$server_group}->{databases}{$conn_name} = {
            display_name => $conn->{description} || ucfirst($conn_name),
            database_name => $database_name,
            connected => 0,
            table_count => 0,
            table_comparisons => [],
            connection_info => {
                host => $conn->{host} || 'localhost',
                port => $conn->{port} || '',
                database => $database_name,
                username => $conn->{username} || '',
                priority => $conn->{priority} || 999,
                db_type => $conn->{db_type} || 'mysql'
            },
        };
    }

    return { %servers };
}

# Test database connectivity
sub test_connection {
    my ($self, $connection_config) = @_;
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'test_connection', 
        "Testing connection: " . ($connection_config->{description} || 'Unknown'));
    
    my $success = 0;
    
    eval {
        require DBI;
        my $dsn;
        my $dbh;
        
        if (defined $connection_config->{db_type} && $connection_config->{db_type} eq 'sqlite') {
            # SQLite connection
            $dsn = "dbi:SQLite:dbname=" . $connection_config->{database_path};
            $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'test_connection',
                "SQLite DSN: $dsn");
            $dbh = DBI->connect($dsn, "", "", {
                RaiseError => 0,
                PrintError => 0,
                sqlite_timeout => 5000,
            });
        } else {
            # MySQL/MariaDB connection
            my $driver = 'mysql';
            $dsn = "dbi:$driver:database=" . $connection_config->{database} . 
                   ";host=" . $connection_config->{host} . 
                   ";port=" . $connection_config->{port};
            $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'test_connection',
                "DB DSN ($driver): $dsn with user: " . $connection_config->{username});
            
            # Use driver-appropriate attributes
            my $connect_attrs = {
                RaiseError => 0,
                PrintError => 0,
            };
            # Only add mysql_connect_timeout for mysql driver
            if ($driver eq 'mysql' || $driver eq 'MariaDB') {
                $connect_attrs->{mysql_connect_timeout} = 5;
            }
            
            $dbh = DBI->connect($dsn, $connection_config->{username}, $connection_config->{password}, $connect_attrs);
        }
        
        if ($dbh) {
            $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'test_connection',
                "Connection SUCCESSFUL for: " . ($connection_config->{description} || 'Unknown'));
            $dbh->disconnect();
            $success = 1;
        } else {
            $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'test_connection',
                "Connection FAILED for: " . ($connection_config->{description} || 'Unknown') . " - Error: " . ($DBI::errstr || 'Unknown error'));
        }
    };
    if ($@) {
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'test_connection',
            "Exception during connection test: $@");
    }
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'test_connection',
        "Connection test result for " . ($connection_config->{description} || 'Unknown') . ": " . ($success ? 'SUCCESS' : 'FAILED'));
    
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
         ((defined $conn->{db_type} && $conn->{db_type} eq 'sqlite') && $_ =~ /\Q$database_name\E/))
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
        my $host = $conn->{host} || 'N/A';
        my $port = $conn->{port} || 'N/A';

        # Skip if required fields are missing, empty, or contain placeholders
        my $skip = 0;
        
        # Check localhost_override flag - skip localhost connections unless explicitly enabled
        if ($conn->{localhost_override}) {
            unless ($ENV{COMSERV_ALLOW_LOCALHOST_OVERRIDE}) {
                $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'select_connection',
                    "SKIPPED $conn_name ($host:$port): localhost_override=true and COMSERV_ALLOW_LOCALHOST_OVERRIDE not set");
                next;
            }
        }
        
        # Different required fields for different database types
        my @required_fields;
        if (defined $conn->{db_type} && $conn->{db_type} eq 'sqlite') {
            @required_fields = qw/database_path/;
        } else {
            @required_fields = qw/host port username database/;
        }
        
        foreach my $field (@required_fields) {
            if (!exists $conn->{$field} ||
                !defined $conn->{$field} ||
                $conn->{$field} =~ /^\s*$/) {
                $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'select_connection',
                    "SKIPPED $conn_name ($host:$port): Missing required field '$field'");
                $skip = 1;
                last;
            }
            if ($conn->{$field} =~ /YOUR_|PLACEHOLDER/i) {
                $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'select_connection',
                    "SKIPPED $conn_name ($host:$port): Field '$field' contains placeholder value");
                $skip = 1;
                last;
            }
        }
        next if $skip;

        # Try the connection
        $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'select_connection',
            "ATTEMPTING connection $conn_name at $host:$port for database '$database_name'");
        
        if ($self->test_connection($conn)) {
            $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'select_connection',
                "✓ SUCCESS: Connected to $conn_name ($host:$port) - Database: '$database_name' (" . 
                ($conn->{description} || 'no description') . ")");

            # Store the selected connection info
            my $connection_info = {
                connection_name => $conn_name,
                config => $conn,
                database_name => $database_name,
                host => $host,
                port => $port
            };
            $self->selected_connection->{$database_name} = $connection_info;
            
            return $connection_info;
        } else {
            $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'select_connection',
                "✗ FAILED: Could not connect to $conn_name at $host:$port - will try next priority");
        }
    }

    # If we get here, no connection worked
    my $error_msg = "RemoteDB: No working database connection found for '$database_name' database after trying " .
        scalar(@matching_connections) . " connections:\n";
    foreach my $conn_name (@matching_connections) {
        my $conn = $config->{$conn_name};
        my $host = $conn->{host} || 'N/A';
        my $port = $conn->{port} || 'N/A';
        my $desc = $conn->{description} || 'no description';
        $error_msg .= "  - $conn_name ($host:$port): $desc\n";
    }
    
    $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'select_connection', $error_msg);
    die $error_msg;
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

# ============================================================================
# DATABASE SELECTION INFRASTRUCTURE - Future User-Configurable Capability
# ============================================================================
# The following methods provide infrastructure for implementing user-selectable
# database connections in the future. Currently, automatic selection based on
# priority is used. These methods allow for override capability when needed.
# ============================================================================

# Get user's preferred database connection from session
# FUTURE: Call this from get_connection_info to support user preferences
sub get_user_preferred_connection {
    my ($self, $c, $database_name) = @_;
    
    # Not yet implemented - prepared for future use
    return undef;
    
    # Planned implementation:
    # return $c->session->{preferred_connection}->{$database_name}
    #     if exists $c->session->{preferred_connection}->{$database_name};
}

# Set user's preferred database connection in session
# FUTURE: Call from admin interface to store user database preference
sub set_user_preferred_connection {
    my ($self, $c, $database_name, $connection_name) = @_;
    
    # Validate connection exists
    $self->_load_config();
    my $config = $self->config;
    
    unless (exists $config->{$connection_name}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'set_user_preferred_connection',
            "Attempted to set invalid connection preference: $connection_name");
        return 0;
    }
    
    # Store in session
    $c->session->{preferred_connection} ||= {};
    $c->session->{preferred_connection}->{$database_name} = $connection_name;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'set_user_preferred_connection',
        "Set user preference for $database_name to $connection_name");
    
    return 1;
}

# Clear user's database connection preference
sub clear_user_preferred_connection {
    my ($self, $c, $database_name) = @_;
    
    if ($c->session->{preferred_connection} && 
        exists $c->session->{preferred_connection}->{$database_name}) {
        delete $c->session->{preferred_connection}->{$database_name};
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'clear_user_preferred_connection',
            "Cleared user preference for $database_name - will use automatic selection");
        return 1;
    }
    
    return 0;
}

# Select connection with optional user preference override
# FUTURE: Replace select_connection calls with this to support user preferences
sub select_connection_with_preference {
    my ($self, $c, $database_name) = @_;
    
    # Check for user preference (when fully implemented)
    my $preferred_connection = $self->get_user_preferred_connection($c, $database_name);
    
    if ($preferred_connection) {
        $self->_load_config();
        my $config = $self->config;
        
        # Try the preferred connection first
        if (exists $config->{$preferred_connection}) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'select_connection_with_preference',
                "Attempting to use user-preferred connection: $preferred_connection for $database_name");
            
            my $preferred_config = $config->{$preferred_connection};
            
            # Verify it's for the right database
            if (($preferred_config->{database} && $preferred_config->{database} eq $database_name) ||
                ($preferred_config->{db_type} eq 'sqlite' && $preferred_connection =~ /\Q$database_name\E/)) {
                
                if ($self->test_connection($preferred_config)) {
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'select_connection_with_preference',
                        "Successfully using preferred connection: $preferred_connection");
                    
                    my $connection_info = {
                        connection_name => $preferred_connection,
                        config => $preferred_config,
                        database_name => $database_name
                    };
                    $self->selected_connection->{$database_name} = $connection_info;
                    return $connection_info;
                }
            }
            
            # Preferred connection failed, log and fall through to automatic selection
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'select_connection_with_preference',
                "Preferred connection $preferred_connection failed. Falling back to automatic selection.");
        }
    }
    
    # No preference or preferred connection failed - use automatic selection
    return $self->select_connection($database_name);
}

# Get all available connections for a database (for future UI/selection)
# Useful for building a UI dropdown to let users choose
sub get_available_connections_for_database {
    my ($self, $database_name) = @_;
    
    $self->_load_config();
    my $config = $self->config;
    
    my @available = ();
    
    foreach my $conn_name (keys %$config) {
        next if $conn_name =~ /^_/;
        my $conn = $config->{$conn_name};
        next unless ref $conn eq 'HASH';
        
        # Check if this connection serves the database
        if (($conn->{database} && $conn->{database} eq $database_name) ||
            ($conn->{db_type} eq 'sqlite' && $conn_name =~ /\Q$database_name\E/)) {
            
            # Test the connection to get current status
            my $is_available = $self->test_connection($conn);
            
            push @available, {
                connection_name => $conn_name,
                description => $conn->{description} || $conn_name,
                host => $conn->{host} || 'SQLite',
                priority => $conn->{priority} || 999,
                is_available => $is_available,
                db_type => $conn->{db_type} || 'mysql'
            };
        }
    }
    
    # Sort by priority
    @available = sort { $a->{priority} <=> $b->{priority} } @available;
    
    return \@available;
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
    
    my $start_time = time();
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'get_connection', 
        "[TIMING] get_connection START for '$conn_name' at " . scalar(localtime($start_time)));
    
    # Check if the connection exists
    unless (exists $self->connections->{$conn_name}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_connection', 
            "Remote connection '$conn_name' does not exist. Available connections: " . join(', ', keys %{$self->connections}));
        return;
    }
    
    my $conn = $self->connections->{$conn_name};
    
    # Check existing connection status
    if ($conn->{dbh}) {
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'get_connection', 
            "[PING] Testing existing connection for '$conn_name'");
        
        my $ping_result;
        eval {
            $ping_result = $conn->{dbh}->ping;
        };
        
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_connection', 
                "[PING_ERROR] Ping failed for '$conn_name': $@");
        } elsif ($ping_result) {
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'get_connection', 
                "[PING_OK] Connection '$conn_name' is active, returning existing handle");
            return $conn->{dbh};
        } else {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_connection', 
                "[PING_FAILED] Connection '$conn_name' failed ping, will reconnect");
        }
    } else {
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'get_connection', 
            "[NEW_CONN] No existing connection for '$conn_name', will create new");
    }
    
    # Create a new connection
    my $config = $conn->{config};
    my $db_type = 'mysql';
    my $dsn = "dbi:$db_type:database=$config->{database};host=$config->{host};port=$config->{port}";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_connection', 
        "[CONNECT] Attempting to connect to DSN: dbi:$db_type:database=$config->{database};host=$config->{host};port=$config->{port} as user '$config->{username}'");
    
    try {
        my $connect_start = time();
        $conn->{dbh} = DBI->connect($dsn, $config->{username}, $config->{password}, {
            RaiseError => 1,
            AutoCommit => 1,
            PrintError => 0,
        });
        my $connect_time = time() - $connect_start;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_connection', 
            "[CONNECT_OK] Successfully connected to remote database '$conn_name' in ${connect_time}s");
        
        my $total_time = time() - $start_time;
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'get_connection', 
            "[TIMING] get_connection COMPLETE for '$conn_name' in ${total_time}s");
        
        return $conn->{dbh};
    } catch {
        my $total_time = time() - $start_time;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_connection', 
            "[CONNECT_FAILED] Failed to connect to remote database '$conn_name' after ${total_time}s: $_");
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

# Schema Comparison Specific Methods
# ===================================

# Get schema comparison database status - checks both ency and forager databases
sub get_schema_comparison_status {
    my ($self) = @_;
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'get_schema_comparison_status',
        "Checking schema comparison database requirements (ency + forager)");
    
    my $status = {
        ency_status => 'disconnected',
        forager_status => 'disconnected',
        both_connected => 0,
        ency_connection => undef,
        forager_connection => undef,
        error_messages => []
    };
    
    try {
        # Check for ency database connection
        $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'get_schema_comparison_status',
            "About to search for ENCY database connection");
        my $ency_conn = $self->find_database_connection('ency');
        if ($ency_conn) {
            $status->{ency_status} = 'connected';
            $status->{ency_connection} = $ency_conn;
            $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'get_schema_comparison_status',
                "ENCY database connection found: " . $ency_conn->{connection_name});
        } else {
            $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'get_schema_comparison_status',
                "ENCY database connection NOT found - will be marked as disconnected");
            push @{$status->{error_messages}}, "ENCY database connection not found or not accessible";
        }
        
        # Check for forager database connection  
        $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'get_schema_comparison_status',
            "About to search for Forager database connection");
        my $forager_conn = $self->find_database_connection('shanta_forager');
        if ($forager_conn) {
            $status->{forager_status} = 'connected';
            $status->{forager_connection} = $forager_conn;
            $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'get_schema_comparison_status',
                "Forager database connection found: " . $forager_conn->{connection_name});
        } else {
            $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'get_schema_comparison_status',
                "Forager database connection NOT found - will be marked as disconnected");
            push @{$status->{error_messages}}, "Forager database connection not found or not accessible";
        }
        
        # Set overall status
        $status->{both_connected} = ($status->{ency_status} eq 'connected' && $status->{forager_status} eq 'connected');
        
        $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'get_schema_comparison_status',
            sprintf("Schema comparison status: ENCY=%s, Forager=%s, Both=%s", 
                   $status->{ency_status}, $status->{forager_status}, 
                   $status->{both_connected} ? 'YES' : 'NO'));
        
    } catch {
        my $error = "Exception in schema comparison status check: $_";
        push @{$status->{error_messages}}, $error;
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'get_schema_comparison_status', $error);
    };
    
    return $status;
}

# Find a working database connection for a specific database name
sub find_database_connection {
    my ($self, $database_name) = @_;
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'find_database_connection',
        "Searching for database connection: $database_name");
    
    my $connection_info;
    my $error_msg;
    
    try {
        # Use the existing select_connection method which handles priority and connection testing
        $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'find_database_connection',
            "Calling select_connection for database: $database_name");
        $connection_info = $self->select_connection($database_name);
        
    } catch {
        $error_msg = $_;
        $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'find_database_connection',
            "Exception in find_database_connection for '$database_name': $_");
    };
    
    if ($connection_info) {
        $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'find_database_connection',
            "Found working connection for '$database_name': " . $connection_info->{connection_name});
        return $connection_info;
    } else {
        $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'find_database_connection',
            "No working connection found for '$database_name'" . ($error_msg ? " (error: $error_msg)" : ""));
        return undef;
    }
}

# Get enhanced connection info with schema comparison context
sub get_schema_comparison_connections {
    my ($self) = @_;
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'get_schema_comparison_connections',
        "Building schema comparison connection info");
    
    my $comparison_status = $self->get_schema_comparison_status();
    my $connections = {};
    
    # Build connection info for schema comparison system
    if ($comparison_status->{ency_connection}) {
        my $conn = $comparison_status->{ency_connection};
        
        # Get actual table list for ENCY database
        my ($tables, $table_count) = $self->_get_table_list($conn);
        
        $connections->{$conn->{connection_name}} = {
            connected => 1,
            display_name => "ENCY Database",
            database_name => 'ency',
            config_key => $conn->{connection_name},
            host => $conn->{config}->{host} || 'localhost',
            port => $conn->{config}->{port} || 3306,
            tables => $tables,
            table_count => $table_count,
            table_comparisons => $self->_build_table_comparisons($tables, 'ency'),
            connection_info => {
                host => $conn->{config}->{host} || 'localhost',
                port => $conn->{config}->{port} || 3306,
                database => 'ency',
                username => $conn->{config}->{username} || '',
                priority => $conn->{config}->{priority} || 999,
                db_type => $conn->{config}->{db_type} || 'mysql'
            }
        };
        
        $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'get_schema_comparison_connections',
            "ENCY database: found $table_count tables");
    }
    
    if ($comparison_status->{forager_connection}) {
        my $conn = $comparison_status->{forager_connection};
        
        # Get actual table list for Forager database
        my ($tables, $table_count) = $self->_get_table_list($conn);
        
        $connections->{$conn->{connection_name}} = {
            connected => 1,
            display_name => "Forager Database",
            database_name => 'shanta_forager',
            config_key => $conn->{connection_name},
            host => $conn->{config}->{host} || 'localhost',
            port => $conn->{config}->{port} || 3306,
            tables => $tables,
            table_count => $table_count,
            table_comparisons => $self->_build_table_comparisons($tables, 'shanta_forager'),
            connection_info => {
                host => $conn->{config}->{host} || 'localhost',
                port => $conn->{config}->{port} || 3306,
                database => 'shanta_forager',
                username => $conn->{config}->{username} || '',
                priority => $conn->{config}->{priority} || 999,
                db_type => $conn->{config}->{db_type} || 'mysql'
            }
        };
        
        $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'get_schema_comparison_connections',
            "Forager database: found $table_count tables");
    }
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'get_schema_comparison_connections',
        "Schema comparison connections built: " . scalar(keys %$connections) . " databases available");
    
    return {
        connections => $connections,
        status => $comparison_status
    };
}

# Get table list from a database connection
sub _get_table_list {
    my ($self, $conn) = @_;
    
    my $tables = [];
    my $table_count = 0;
    
    try {
        my $dbh = $self->_connect_to_database($conn);
        if ($dbh) {
            # Query to get all tables from the database
            my $sth = $dbh->prepare("SHOW TABLES");
            $sth->execute();
            
            while (my ($table_name) = $sth->fetchrow_array()) {
                push @$tables, $table_name;
                $table_count++;
            }
            
            $sth->finish();
            $dbh->disconnect();
            
            $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_table_list',
                "Successfully retrieved $table_count tables from database " . ($conn->{database_name} || $conn->{connection_name}));
        } else {
            $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_get_table_list',
                "Failed to connect to database " . ($conn->{database_name} || $conn->{connection_name}));
        }
    } catch {
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_get_table_list',
            "Error getting table list from " . ($conn->{database_name} || $conn->{connection_name}) . ": $_");
    };
    
    return ($tables, $table_count);
}

# Build table comparisons with result file status
sub _build_table_comparisons {
    my ($self, $tables, $database_name) = @_;
    
    my @table_comparisons = ();
    
    # For each table, check if there's a corresponding Result file
    foreach my $table_name (@$tables) {
        my $result_file_exists = $self->_check_result_file_exists($table_name, $database_name);
        
        push @table_comparisons, {
            name => $table_name,
            has_result_file => $result_file_exists,
            daname => $database_name,
            # These will be populated when doing detailed comparisons
            differences_count => 0,
            sync_status => $result_file_exists ? 'unknown' : 'missing_result'
        };
    }
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_build_table_comparisons',
        "Built " . scalar(@table_comparisons) . " table comparisons for $database_name");
    
    return \@table_comparisons;
}

# Check if a result file exists for a given table
sub _check_result_file_exists {
    my ($self, $table_name, $database_name) = @_;
    
    # Determine which database directory to check
    my $db_dir;
    if ($database_name eq 'ency') {
        $db_dir = 'Ency';
    } elsif ($database_name eq 'shanta_forager') {
        $db_dir = 'Forager';
    } else {
        # Default fallback
        $db_dir = 'Ency';
    }
    
    my $result_dir = "/home/shanta/PycharmProjects/comserv2/Comserv/lib/Comserv/Model/Schema/$db_dir/Result/";
    
    # Get all .pm files in the result directory
    opendir(my $dh, $result_dir) or return 0;
    my @result_files = grep { /\.pm$/ && -f "$result_dir$_" } readdir($dh);
    closedir($dh);
    
    # Create mappings from Result class names to possible table names
    my %table_mappings = ();
    foreach my $file (@result_files) {
        my $class_name = $file;
        $class_name =~ s/\.pm$//;
        
        # Direct lowercase match
        $table_mappings{lc($class_name)} = 1;
        
        # Convert PascalCase to snake_case
        my $snake_case = $class_name;
        $snake_case =~ s/([A-Z])/_$1/g;
        $snake_case =~ s/^_//;
        $snake_case = lc($snake_case);
        $table_mappings{$snake_case} = 1;
        
        # Try pluralized versions (e.g. Category -> categories)
        my $plural = lc($class_name) . 's';
        $table_mappings{$plural} = 1;
        
        # Try singular version (e.g. Files -> file)  
        my $singular = lc($class_name);
        $singular =~ s/s$// if $singular =~ /[^s]s$/;
        $table_mappings{$singular} = 1;
    }
    
    return exists $table_mappings{$table_name} ? 1 : 0;
}

# Convert table name to Result class name (e.g. user_profiles -> UserProfiles)
sub _table_name_to_result_class {
    my ($self, $table_name) = @_;
    
    # Convert snake_case to PascalCase
    my @words = split /_/, $table_name;
    my $class_name = join('', map { ucfirst(lc($_)) } @words);
    
    return $class_name;
}

# Connect to database using connection info
sub _connect_to_database {
    my ($self, $conn) = @_;
    
    my $config = $conn->{config};
    my $host = $config->{host};
    my $port = $config->{port} || 3306;
    my $database = $config->{database};
    my $username = $config->{username};
    my $password = $config->{password};
    my $db_type = $config->{db_type} || 'mysql';
    
    my $dsn;
    if ($db_type eq 'sqlite') {
        $dsn = "dbi:SQLite:dbname=$database";
    } else {
        my $driver = 'mysql';
        $dsn = "dbi:$driver:database=$database;host=$host;port=$port";
    }
    
    try {
        my $dbh = DBI->connect($dsn, $username, $password, {
            RaiseError => 1,
            PrintError => 0,
            AutoCommit => 1,
        });
        
        return $dbh;
    } catch {
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_connect_to_database',
            "Failed to connect to database $database: $_");
        return undef;
    };
}

__PACKAGE__->meta->make_immutable;
1;
