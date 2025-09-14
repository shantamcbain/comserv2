package Comserv::Model::DBForager;

use strict;
use JSON;
use base 'Catalyst::Model::DBIC::Schema';
use Catalyst::Utils;  # For path_to
use Data::Dumper;

# Load the database configuration from db_config.json
my $config_file;
my $json_text;

# Try to load the config file using Catalyst::Utils if the application is initialized
eval {
    $config_file = Catalyst::Utils::path_to('db_config.json');
};

# Fallback to FindBin if Catalyst::Utils fails (during application initialization)
if ($@ || !defined $config_file) {
    use FindBin;
    use File::Basename;
    use Cwd 'abs_path';
    
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
    
    $config_file = "$app_root/db_config.json";
    warn "Using FindBin fallback for config file: $config_file";
}

# Load the configuration file
eval {
    local $/; # Enable 'slurp' mode
    open my $fh, "<", $config_file or die "Could not open $config_file: $!";
    $json_text = <$fh>;
    close $fh;
};

if ($@) {
    die "Error loading config file $config_file: $@";
}

my $config = decode_json($json_text);

# Function to test database connectivity
sub test_connection {
    my ($connection_config) = @_;
    
    eval {
        require DBI;
        my $dsn;
        my $dbh;
        
        if ($connection_config->{db_type} eq 'sqlite') {
            # SQLite connection
            $dsn = "dbi:SQLite:dbname=" . $connection_config->{database_path};
            $dbh = DBI->connect($dsn, "", "", {
                RaiseError => 0,
                PrintError => 0,
                sqlite_timeout => 5000,
            });
        } else {
            # MySQL connection
            $dsn = "dbi:mysql:database=" . $connection_config->{database} . 
                   ";host=" . $connection_config->{host} . 
                   ";port=" . $connection_config->{port};
            $dbh = DBI->connect($dsn, $connection_config->{username}, $connection_config->{password}, {
                RaiseError => 0,
                PrintError => 0,
                mysql_connect_timeout => 5,
            });
        }
        
        if ($dbh) {
            $dbh->disconnect();
            return 1;
        }
    };
    return 0;
}

# Function to select the best database connection for Forager database
sub select_forager_connection {
    my $config = shift;
    
    # Get all connections that serve the Forager database, sorted by priority
    my @forager_connections = grep { 
        ($config->{$_}->{database} && $config->{$_}->{database} eq 'shanta_forager') ||
        ($config->{$_}->{db_type} eq 'sqlite' && $_ =~ /forager/)
    } sort { 
        $config->{$a}->{priority} <=> $config->{$b}->{priority} 
    } keys %$config;
    
    # Check localhost override first if any connection has it enabled
    my @localhost_override = grep { 
        $config->{$_}->{localhost_override} && 
        (($config->{$_}->{database} && $config->{$_}->{database} eq 'shanta_forager') ||
         ($config->{$_}->{db_type} eq 'sqlite' && $_ =~ /forager/))
    } @forager_connections;
    
    if (@localhost_override) {
        # Try localhost first for connections with localhost_override
        for my $conn_name (@localhost_override) {
            my $conn = $config->{$conn_name};
            # Create a test connection config for localhost override
            my $test_config = { %$conn };
            $test_config->{host} = 'localhost' if $test_config->{host};
            
            if (test_connection($test_config)) {
                warn "DBForager: Using localhost override for $conn_name";
                if ($conn->{db_type} eq 'sqlite') {
                    return (undef, undef, $conn->{database_path}, undef, undef, $conn_name, 'sqlite');
                } else {
                    return ('localhost', $conn->{port}, $conn->{database}, $conn->{username}, $conn->{password}, $conn_name, 'mysql');
                }
            }
        }
    }
    
    # Try connections in priority order
    for my $conn_name (@forager_connections) {
        my $conn = $config->{$conn_name};
        
        if (test_connection($conn)) {
            warn "DBForager: Using connection $conn_name ($conn->{description})";
            if ($conn->{db_type} eq 'sqlite') {
                return (undef, undef, $conn->{database_path}, undef, undef, $conn_name, 'sqlite');
            } else {
                return ($conn->{host}, $conn->{port}, $conn->{database}, $conn->{username}, $conn->{password}, $conn_name, 'mysql');
            }
        }
    }
    
    # If no connection works, fall back to the first available (legacy behavior)
    if (exists $config->{shanta_forager}) {
        my $conn = $config->{shanta_forager};
        warn "DBForager: Falling back to legacy shanta_forager configuration";
        return ($conn->{host}, $conn->{port}, $conn->{database}, $conn->{username}, $conn->{password}, 'shanta_forager', 'mysql');
    }
    
    die "DBForager: No working database connection found for Forager database";
}

# Select the best connection
my ($host, $port, $database, $username, $password, $connection_name, $db_type) = select_forager_connection($config);

# Print the configuration for debugging
print "DBForager Configuration:\n";
print "Selected Connection: $connection_name\n";
print "Database Type: $db_type\n";
if ($db_type eq 'sqlite') {
    print "Database Path: $database\n";
} else {
    print "Host: $host\n";
    print "Database: $database\n";
    print "Username: $username\n";
}

# Set the schema_class and connect_info attributes
my $connect_info;
if ($db_type eq 'sqlite') {
    $connect_info = {
        dsn => "dbi:SQLite:dbname=$database",
        user => "",
        password => "",
        sqlite_unicode => 1,
        on_connect_do => ["PRAGMA foreign_keys = ON"],
        quote_char => '`',
    };
} else {
    $connect_info = {
        dsn => "dbi:mysql:database=$database;host=$host;port=$port",
        user => $username,
        password => $password,
        mysql_enable_utf8 => 1,
        on_connect_do => ["SET NAMES 'utf8'", "SET CHARACTER SET 'utf8'"],
        quote_char => '`',
    };
}

__PACKAGE__->config(
    schema_class => 'Comserv::Model::Schema::Forager',
    connect_info => $connect_info
);
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