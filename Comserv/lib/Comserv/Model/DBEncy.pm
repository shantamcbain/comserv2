package Comserv::Model::DBEncy;

use strict;
use base 'Catalyst::Model::DBIC::Schema';
use Sys::Hostname;
use Socket;
use JSON;
use Data::Dumper;
use Catalyst::Utils;  # For path_to

# Load the database configuration from db_config.json
my $config_file;
my $json_text;

# Try to load the config file using Catalyst::Utils if the application is initialized
eval {
    $config_file = Catalyst::Utils::path_to('db_config.json');
};

# Check for environment variable configuration path
if ($@ || !defined $config_file) {
    if ($ENV{COMSERV_CONFIG_PATH}) {
        use File::Spec;
        $config_file = File::Spec->catfile($ENV{COMSERV_CONFIG_PATH}, 'db_config.json');
        warn "Using environment variable path for config file: $config_file";
    }
}

# Fallback to FindBin if Catalyst::Utils fails (during application initialization)
if ($@ || !defined $config_file) {
    use FindBin;
    use File::Spec;
    
    # Try multiple possible locations
    my @possible_paths = (
        File::Spec->catfile($FindBin::Bin, 'db_config.json'),         # In the same directory as the script
        File::Spec->catfile($FindBin::Bin, '..', 'db_config.json'),   # One level up from the script
        '/opt/comserv/db_config.json',                                # In the /opt/comserv directory
        '/etc/comserv/db_config.json'                                 # In the /etc/comserv directory
    );
    
    foreach my $path (@possible_paths) {
        if (-f $path) {
            $config_file = $path;
            warn "Found config file at: $config_file";
            last;
        }
    }
    
    # If still not found, use the default path but warn about it
    if (!defined $config_file || !-f $config_file) {
        $config_file = File::Spec->catfile($FindBin::Bin, '..', 'db_config.json');
        warn "Using FindBin fallback for config file: $config_file (file may not exist)";
    }
}

# Load the configuration file
eval {
    local $/; # Enable 'slurp' mode
    open my $fh, "<", $config_file or die "Could not open $config_file: $!";
    $json_text = <$fh>;
    close $fh;
};

if ($@) {
    my $error_message = "Error loading config file $config_file: $@";
    warn $error_message;
    
    # Provide more helpful error message with instructions
    die "$error_message\n\n" .
        "Please ensure db_config.json exists in one of these locations:\n" .
        "1. In the directory specified by COMSERV_CONFIG_PATH environment variable\n" .
        "2. In the Comserv application root directory\n" .
        "3. In /opt/comserv/db_config.json\n" .
        "4. In /etc/comserv/db_config.json\n\n" .
        "You can create the file by copying the example from DB_CONFIG_README.md\n" .
        "or by setting COMSERV_CONFIG_PATH to point to the directory containing your config file.\n";
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

# Function to select the best database connection for ENCY database
sub select_ency_connection {
    my $config = shift;
    
    # Get all connections that serve the ENCY database, sorted by priority
    my @ency_connections = grep { 
        ($config->{$_}->{database} && $config->{$_}->{database} eq 'ency') ||
        ($config->{$_}->{db_type} eq 'sqlite' && $_ =~ /ency/)
    } sort { 
        $config->{$a}->{priority} <=> $config->{$b}->{priority} 
    } keys %$config;
    
    # Check localhost override first if any connection has it enabled
    my @localhost_override = grep { 
        $config->{$_}->{localhost_override} && 
        (($config->{$_}->{database} && $config->{$_}->{database} eq 'ency') ||
         ($config->{$_}->{db_type} eq 'sqlite' && $_ =~ /ency/))
    } @ency_connections;
    
    if (@localhost_override) {
        # Try localhost first for connections with localhost_override
        for my $conn_name (@localhost_override) {
            my $conn = $config->{$conn_name};
            # Create a test connection config for localhost override
            my $test_config = { %$conn };
            $test_config->{host} = 'localhost' if $test_config->{host};
            
            if (test_connection($test_config)) {
                warn "DBEncy: Using localhost override for $conn_name";
                if ($conn->{db_type} eq 'sqlite') {
                    return (undef, undef, $conn->{database_path}, undef, undef, $conn_name, 'sqlite');
                } else {
                    return ('localhost', $conn->{port}, $conn->{database}, $conn->{username}, $conn->{password}, $conn_name, 'mysql');
                }
            }
        }
    }
    
    # Try connections in priority order
    for my $conn_name (@ency_connections) {
        my $conn = $config->{$conn_name};
        
        if (test_connection($conn)) {
            warn "DBEncy: Using connection $conn_name ($conn->{description})";
            if ($conn->{db_type} eq 'sqlite') {
                return (undef, undef, $conn->{database_path}, undef, undef, $conn_name, 'sqlite');
            } else {
                return ($conn->{host}, $conn->{port}, $conn->{database}, $conn->{username}, $conn->{password}, $conn_name, 'mysql');
            }
        }
    }
    
    # If no connection works, fall back to the first available (legacy behavior)
    if (exists $config->{shanta_ency}) {
        my $conn = $config->{shanta_ency};
        warn "DBEncy: Falling back to legacy shanta_ency configuration";
        return ($conn->{host}, $conn->{port}, $conn->{database}, $conn->{username}, $conn->{password}, 'shanta_ency', 'mysql');
    }
    
    die "DBEncy: No working database connection found for ENCY database";
}

# Select the best connection
my ($host, $port, $database, $username, $password, $connection_name, $db_type) = select_ency_connection($config);

# Print the configuration for debugging
print "DBEncy Configuration:\n";
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
    };
} else {
    $connect_info = {
        dsn => "dbi:mysql:database=$database;host=$host;port=$port",
        user => $username,
        password => $password,
        mysql_enable_utf8 => 1,
        on_connect_do => ["SET NAMES 'utf8'", "SET CHARACTER SET 'utf8'"],
    };
}

__PACKAGE__->config(
    schema_class => 'Comserv::Model::Schema::Ency',
    connect_info => $connect_info
);
sub list_tables {
    my $self = shift;

    return $self->schema->storage->dbh->selectcol_arrayref(
        "SHOW TABLES"  # Adjust if the database uses a different query for metadata
    );
}

sub get_active_projects {
    my ($self, $site_name) = @_;

    # Get a DBIx::Class::ResultSet object for the 'Project' table
    my $rs = $self->resultset('Project');

    # Fetch the projects for the given site where status is not 'none'
    my @projects = $rs->search({ sitename => $site_name, status => { '!=' => 'none' } });

    # If no projects were found, add a default project
    if (@projects == 0) {
        push @projects, { id => 1, name => 'Not Found 1' };
    }

    return \@projects;
}
sub get_table_info {
    my ($self, $table_name) = @_;

    # Get the DBIx::Class::Schema object
    my $schema = $self->schema;

    # Check if the table exists
    if ($schema->source($table_name)) {
        # The table exists, get its schema
        my $source = $schema->source($table_name);
        my $columns_info = $source->columns_info;

        # Return the schema
        return $columns_info;
    } else {
        # The table does not exist
        return;
    }
}

sub create_table_from_result {
    my ($self, $table_name, $schema, $c) = @_;

    # Log the table name at the beginning of the method
    $c->controller('Base')->stash_message($c, "Package " . __PACKAGE__ . " Sub " . ((caller(1))[3]) . " Line " . __LINE__ . ": Starting method for table: $table_name");

    # Check if the required fields are present and in the correct format
    unless ($schema && $schema->isa('DBIx::Class::Schema')) {
        $c->controller('Base')->stash_message($c, "Package " . __PACKAGE__ . " Sub " . ((caller(1))[3]) . " Line " . __LINE__ . ": Schema is not a DBIx::Class::Schema object. Table name: $table_name");
        return;
    }

    # Get a DBI database handle
    my $dbh = $schema->storage->dbh;

    # Execute a SHOW TABLES LIKE 'table_name' SQL statement
    my $sth = $dbh->prepare("SHOW TABLES LIKE ?");
    $sth->execute($table_name);

    # Fetch the result
    my $result = $sth->fetch;

    # Check if the table exists
    if (!$result) {
        # The table does not exist, create it
        my $result_class = "Comserv::Model::Schema::Ency::Result::$table_name";
        eval "require $result_class";
        if ($@) {
            $c->controller('Base')->stash_message($c, "Package " . __PACKAGE__ . " Sub " . ((caller(1))[3]) . " Line " . __LINE__ . ": Could not load $result_class: $@. Table name: $table_name");
            return;
        }

        # Get the columns from the result class
        my $columns_info = $result_class->columns_info;
        my %columns = %$columns_info if ref $columns_info eq 'HASH';

        # Log the table properties before the table creation process starts
        $c->controller('Base')->stash_message($c, "Package " . __PACKAGE__ . " Sub " . ((caller(1))[3]) . " Line " . __LINE__ . ": Table properties for $table_name: " . Dumper($columns_info));

        # Define the structure of the table
        my $source = $schema->source($table_name);
        $source->add_columns(%columns);
        $source->set_primary_key($result_class->primary_columns);

        # Deploy the table
        my $deploy_result = $schema->deploy({ sources => [$table_name] });

        if ($deploy_result) {
            $c->controller('Base')->stash_message($c, "Package " . __PACKAGE__ . " Sub " . ((caller(1))[3]) . " Line " . __LINE__ . ": Table $table_name deployed successfully.");
            return 1;  # Return 1 to indicate that the table creation was successful
        } else {
            $c->controller('Base')->stash_message($c, "Package " . __PACKAGE__ . " Sub " . ((caller(1))[3]) . " Line " . __LINE__ . ": Failed to deploy table $table_name.");
            $c->controller('Base')->stash_message($c, "Package " . __PACKAGE__ . " Sub " . ((caller(1))[3]) . " Line " . __LINE__ . ": Deployment details: " . Dumper($deploy_result) . ". Table name: $table_name");
            return 0;  # Return 0 to indicate that the table creation failed but didn't raise an exception
        }
    } else {
        $c->controller('Base')->stash_message($c, "Package " . __PACKAGE__ . " Sub " . ((caller(1))[3]) . " Line " . __LINE__ . ": Table $table_name already exists.");
        return 1;  # Return 1 to indicate that the table already exists
    }
}
1;
