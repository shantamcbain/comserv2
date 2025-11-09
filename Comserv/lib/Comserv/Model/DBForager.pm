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
        $logger->log_with_details(undef, 'warn', __FILE__, __LINE__, 'COMPONENT',
            "DBForager: Failed to get connection from RemoteDB: $error");
        $logger->log_with_details(undef, 'warn', __FILE__, __LINE__, 'COMPONENT',
            "DBForager: Falling back to SQLite offline mode");
        
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
        # Use the appropriate driver (mysql or mariadb)
        my $driver = $db_type eq 'mariadb' ? 'MariaDB' : 'mysql';
        $connect_info = {
            dsn => "dbi:$driver:database=" . $conn->{database} . ";host=" . $conn->{host} . ";port=" . $conn->{port},
            user => $conn->{username},
            password => $conn->{password},
            mysql_enable_utf8 => 1,
            # CRITICAL: Add timeouts to prevent workers from hanging indefinitely
            mysql_connect_timeout => 10,     # Connection timeout: 10 seconds
            mysql_read_timeout => 30,        # Query read timeout: 30 seconds
            mysql_write_timeout => 30,       # Query write timeout: 30 seconds
            # Error handling
            RaiseError => 1,
            PrintError => 0,
            AutoCommit => 1,
            on_connect_do => [
                "SET NAMES 'utf8'",
                "SET CHARACTER SET 'utf8'",
                "SET SESSION max_execution_time=60000",  # 60 second max query time (milliseconds)
                "SET SESSION net_read_timeout=30",
                "SET SESSION net_write_timeout=30",
            ],
            quote_char => '`',
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
    
    my $info = {
        # Current runtime connection info
        current_dsn => $connect_info->[0]{dsn} || $connect_info->[0] || 'Unknown',
        current_username => $connect_info->[0]{user} || $connect_info->[1] || 'Unknown',
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
    return [$dbforager->all]

}
# Get herbs with bee forage information
sub get_bee_forage_plants {
    my ($self) = @_;

    # Search for herbs that have apis, nectar, or pollen information
    my $bee_plants = $self->schema->resultset('Herb')->search(
        {
            -or => [
                'apis' => { '!=' => '', '!=' => undef },
                'nectar' => { '!=' => '', '!=' => undef },
                'pollen' => { '!=' => '', '!=' => undef }
            ]
        },
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

# Method to get current connection info for debugging (similar to DBEncy)
sub get_connection_info {
    my ($self) = @_;
    
    my $storage = $self->schema->storage;
    my $connect_info = $storage->connect_info;
    
    my $info = {
        dsn => $connect_info->[0]{dsn} || $connect_info->[0] || 'Unknown',
        username => $connect_info->[0]{user} || $connect_info->[1] || 'Unknown',
        # Don't expose password for security
        connection_type => ref($storage) || 'Unknown'
    };
    
    return $info;
}

1;