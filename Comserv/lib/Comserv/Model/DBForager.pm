package Comserv::Model::DBForager;

use strict;
use base 'Catalyst::Model::DBIC::Schema';
use Comserv::Util::Logging;

# Store connection details for debugging
my $startup_connection_info;



# Set default schema_class - connect_info will be set at runtime
__PACKAGE__->config(
    schema_class => 'Comserv::Model::Schema::Forager'
);

# COMPONENT method runs at application startup, not module compile time
sub COMPONENT {
    my ($self, $app, $args) = @_;

    my $logger = Comserv::Util::Logging->instance();
    
    # Create a RemoteDB instance directly instead of relying on Catalyst's model()
    # This avoids circular dependency issues during component initialization
    my $remote_db;
    eval {
        require Comserv::Model::RemoteDB;
        $remote_db = Comserv::Model::RemoteDB->new();
    };
    
    if ($@ || !$remote_db) {
        my $error = $@ || "Failed to create RemoteDB instance";
        $logger->log_with_details(undef, 'error', __FILE__, __LINE__, 'COMPONENT',
            "DBForager: Failed to create RemoteDB instance: $error");
        die "DBForager: Cannot proceed without RemoteDB: $error";
    }

    # Use RemoteDB to select the best connection for 'shanta_forager' database
    my $connection_info;
    eval {
        $connection_info = $remote_db->get_connection_info('shanta_forager');
    };

    # Fallback to SQLite if primary connections fail
    if ($@ || !$connection_info) {
        my $error = $@ || "No connection info returned from RemoteDB";
        
        # Write error to STDERR for debugging  (bypasses logging system if broken)
        warn "\n=== DBForager CRITICAL ERROR ===\n";
        warn "Failed to get connection from RemoteDB\n";
        warn "Error: $error\n";
        warn "===============================\n\n";
        
        $logger->log_with_details(undef, 'error', __FILE__, __LINE__, 'COMPONENT',
            "DBForager CRITICAL: Failed to get connection from RemoteDB: $error");
        $logger->log_with_details(undef, 'error', __FILE__, __LINE__, 'COMPONENT',
            "DBForager CRITICAL: Falling back to SQLite offline mode - APPLICATION WILL HAVE LIMITED FUNCTIONALITY");
        
        # Create a fallback SQLite connection
        $connection_info = {
            connection_name => 'sqlite_forager_fallback',
            config => {
                db_type => 'sqlite',
                database_path => 'data/forager_offline.db',
                description => 'SQLite Fallback - Forager Database (offline mode)',
                priority => 999
            },
            database_name => 'shanta_forager'
        };
    }

    # Extract connection details from RemoteDB
    my $conn = $connection_info->{config};
    my $connection_name = $connection_info->{connection_name};
    my $db_type = $conn->{db_type} || 'mysql';
    
    # Enhanced startup logging to show which connection is being used
    $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'COMPONENT',
        "============================================");
    $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'COMPONENT',
        "DBForager MODEL STARTUP - CONNECTION FROM RemoteDB:");
    $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'COMPONENT',
        "Connection Name: $connection_name");
    $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'COMPONENT',
        "Database Type: $db_type");
    if ($db_type eq 'sqlite') {
        $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'COMPONENT',
            "Database Path: " . $conn->{database_path});
    } else {
        $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'COMPONENT',
            "Host: " . $conn->{host} . ":" . $conn->{port});
        $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'COMPONENT',
            "Database: " . $conn->{database});
        $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'COMPONENT',
            "Username: " . $conn->{username});
    }
    $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'COMPONENT',
        "Description: " . ($conn->{description} || 'No description'));
    $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'COMPONENT',
        "Priority: " . ($conn->{priority} || 'Not set'));
    $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'COMPONENT',
        "============================================");

    # Store connection info for debugging
    $startup_connection_info = {
        connection_name => $connection_name,
        db_type => $db_type,
        host => $conn->{host},
        port => $conn->{port},
        database => $conn->{database} || $conn->{database_path},
        username => $conn->{username},
        description => $conn->{description} || 'No description',
        priority => $conn->{priority} || 'Not set',
        timestamp => scalar(localtime())
    };
        
    # Set up the DBIx::Class connection
    my $connect_info;
    if ($db_type eq 'sqlite') {
        $connect_info = {
            dsn => "dbi:SQLite:dbname=" . $conn->{database_path},
            user => "",
            password => "",
            sqlite_unicode => 1,
            on_connect_do => ["PRAGMA foreign_keys = ON"],
            quote_char => '`',
        };
    } else {
        # CRITICAL FIX (November 2025): Select available database driver
        # Try MariaDB first (preferred), fall back to mysql if not installed
        my $driver = $db_type eq 'mariadb' ? 'MariaDB' : 'mysql';
        my $driver_available = 0;
        
        # Check if preferred driver is available
        if ($driver eq 'MariaDB') {
            eval {
                require DBD::MariaDB;
                $driver_available = 1;
            };
            # Fall back to mysql if MariaDB not available
            if (!$driver_available) {
                eval {
                    require DBD::mysql;
                    $driver = 'mysql';
                    $driver_available = 1;
                };
            }
        } else {
            # If already set to mysql, check it's available
            eval {
                require DBD::mysql;
                $driver_available = 1;
            };
        }
        
        $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'COMPONENT',
            "DBForager: Using database driver: $driver (available: $driver_available)");
        
        my %driver_attrs = $driver eq 'MariaDB'
            ? (mariadb_connect_timeout => 10, mariadb_read_timeout => 30, mariadb_write_timeout => 30)
            : (mysql_enable_utf8       => 1, mysql_connect_timeout => 10, mysql_read_timeout   => 30, mysql_write_timeout   => 30);
        $connect_info = {
            dsn => "dbi:$driver:database=" . $conn->{database} . ";host=" . $conn->{host} . ";port=" . $conn->{port},
            user => $conn->{username},
            password => $conn->{password},
            %driver_attrs,
            RaiseError => 1,
            PrintError => 0,
            AutoCommit => 1,
            quote_names => 1,
            quote_char => '`',
            name_sep => '.',
            limit_dialect => 'LimitXY',
            on_connect_do => [
                "SET NAMES 'utf8mb4'",
                "SET CHARACTER SET 'utf8mb4'",
                ($driver eq 'MariaDB'
                    ? "SET SESSION max_statement_time=60"
                    : "SET SESSION max_execution_time=60000"),
                "SET SESSION net_read_timeout=30",
                "SET SESSION net_write_timeout=30",
            ],
        };
    }
    
    $args->{connect_info} = $connect_info;
    
    return $self->next::method($app, $args);
}

# Method to get current connection info for debugging
sub get_connection_info {
    my ($self) = @_;
    
    my $storage = $self->schema->storage;
    my $connect_info = $storage->connect_info;
    
    # Handle both hash ref and string formats for connect_info
    # DBIx::Class may store as [ { dsn => "...", user => "...", password => "..." } ]
    # OR as [ "dbi:mysql:...", "user", "password" ]
    my $current_dsn = 'Unknown';
    my $current_username = 'Unknown';
    
    if ($connect_info && ref($connect_info) eq 'ARRAY' && @$connect_info) {
        # First element is a hash ref with keys (dsn, user, password)
        if (ref($connect_info->[0]) eq 'HASH') {
            $current_dsn = $connect_info->[0]{dsn} if $connect_info->[0]{dsn};
            $current_username = $connect_info->[0]{user} if $connect_info->[0]{user};
        }
        # First element is the DSN string, second is username
        elsif (defined $connect_info->[0] && $connect_info->[0] ne '') {
            $current_dsn = $connect_info->[0];
            $current_username = $connect_info->[1] if defined $connect_info->[1] && $connect_info->[1] ne '';
        }
    }
    
    my $info = {
        # Current runtime connection info
        current_dsn => $current_dsn,
        current_username => $current_username,
        connection_type => ref($storage) || 'Unknown',
        
        # Startup connection selection info
        startup_info => $startup_connection_info || 'Not available'
    };
    
    return $info;
}

# Method to get detailed startup connection info
sub get_startup_connection_info {
    return $startup_connection_info;
}

sub list_tables {
    my $self = shift;

    # Perform a database-specific query to get the list of tables
    return $self->schema->storage->dbh->selectcol_arrayref(
        "SHOW TABLES"  # MySQL-specific; adapt for other databases
    );
}
sub get_herbal_data {
    my ($self) = @_;
    my $dbforager = $self->schema->resultset('Herb')->search(
        { 'botanical_name' => { '!=' => '' } },
        { order_by => 'botanical_name' }
    );
    return [$dbforager->all];
}
# Get herbs with bee forage information
sub get_bee_forage_plants {
    my ($self) = @_;

    # Only return herbs with a forage category (apis) or non-zero nectar or pollen.
    # Uses literal SQL to avoid DBIC/SQL::Abstract duplicate-hash-key issues and
    # to work correctly with both MySQL and SQLite backends.
    my $bee_plants = $self->schema->resultset('Herb')->search(
        \[ "( apis IS NOT NULL AND apis <> '' AND apis <> '0' )
             OR ( nectar IS NOT NULL AND nectar <> '' AND nectar <> '0' AND nectar > 0 )
             OR ( pollen IS NOT NULL AND pollen <> '' AND pollen <> '0' AND pollen > 0 )" ],
        {
            order_by => 'botanical_name',
            columns => [qw(record_id botanical_name common_names apis nectar pollen image)]
        }
    );

    return [$bee_plants->all];
}

# In Comserv::Model::DBForager
sub get_herbs_with_apis {
    my ($self) = @_;
    my $herbs_with_apis = $self->schema->resultset('Herb')->search(
        { 'apis' => { '!=' => undef, '!=' => '' } },  # Check for non-empty apis field
        { order_by => 'botanical_name' }
    );
    return [$herbs_with_apis->all]
}
sub get_herb_by_id {
    my ($self, $id) = @_;
    print "Fetching herb with ID: $id\n";  # Add logging
    my $herb = $self->schema->resultset('Herb')->find($id);
    if ($herb) {
        print "Fetched herb: ", $herb->botanical_name, "\n";  # Add logging
    } else {
        print "No herb found with ID: $id\n";  # Add logging
    }
    return $herb;
}
sub searchHerbs {
    my ($self, $c, $search_string) = @_;

    # Remove leading and trailing whitespaces
    $search_string =~ s/^\s+|\s+$//g;

    # Convert to lowercase
    $search_string = lc($search_string);

    # Initialize an array to hold the debug messages
    my @debug_messages;

    # Log the search string and add it to the debug messages
    push @debug_messages, __PACKAGE__ . " " . __LINE__ . ": Search string: $search_string";

    # Get a ResultSet object for the 'Herb' table
    my $rs = $self->schema->resultset('Herb');

    # Split the search string into individual words
    my @search_words = split(' ', $search_string);

    # Initialize an array to hold the search conditions
    my @search_conditions;

    # For each search word, add a condition for each field
    foreach my $word (@search_words) {
        push @search_conditions, (
            botanical_name  => { 'like', "%" . $word . "%" },
            common_names    => { 'like', "%" . $word . "%" },
            apis            => { 'like', "%" . $word . "%" },
            nectar          => { 'like', "%" . $word . "%" },
            pollen          => { 'like', "%" . $word . "%" },
            key_name        => { 'like', "%" . $word . "%" },
            ident_character => { 'like', "%" . $word . "%" },
            stem            => { 'like', "%" . $word . "%" },
            leaves          => { 'like', "%" . $word . "%" },
            flowers         => { 'like', "%" . $word . "%" },
            fruit           => { 'like', "%" . $word . "%" },
            taste           => { 'like', "%" . $word . "%" },
            odour           => { 'like', "%" . $word . "%" },
            root            => { 'like', "%" . $word . "%" },
            distribution    => { 'like', "%" . $word . "%" },
            constituents    => { 'like', "%" . $word . "%" },
            solvents        => { 'like', "%" . $word . "%" },
            dosage          => { 'like', "%" . $word . "%" },
            administration  => { 'like', "%" . $word . "%" },
            formulas        => { 'like', "%" . $word . "%" },
            contra_indications => { 'like', "%" . $word . "%" },
            chinese         => { 'like', "%" . $word . "%" },
            non_med         => { 'like', "%" . $word . "%" },
            harvest         => { 'like', "%" . $word . "%" },
            reference       => { 'like', "%" . $word . "%" },
        );
    }

    # Perform the search in the database
    my @results;
    eval {
        @results = $rs->search({ -or => \@search_conditions });
    };
    if ($@) {
        my $error = $@;
        push @debug_messages, __PACKAGE__ . " " . __LINE__ . ": Error searching herbs: $error";
        $c->stash(error_msg => "Error searching herbs: $error");
        return;
    }

    # Log the number of results and add it to the debug messages
    push @debug_messages, __PACKAGE__ . " " . __LINE__ . ": Number of results: " . scalar @results;

    # Add the debug messages to the stash
    $c->stash(debug_msg => \@debug_messages);

    return \@results;
}

sub trim {
    my $s = shift;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

1;