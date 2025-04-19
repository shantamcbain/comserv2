package Comserv::Model::DBEncy;

use strict;
use base 'Catalyst::Model::DBIC::Schema';
use Sys::Hostname;
use Socket;
use JSON;
use Data::Dumper;
use Catalyst::Utils;

my $json_text;
{
    local $/; # Enable 'slurp' mode
    
    # Use the absolute path to the db_config.json file
    my $config_path = "/home/shanta/PycharmProjects/comserv2/Comserv/db_config.json";
    warn "DBEncy: Loading database config from: $config_path";
    
    # Add logging for debugging
    if (-e $config_path) {
        warn "DBEncy: Config file exists at: $config_path";
    } else {
        warn "DBEncy: Config file NOT FOUND at: $config_path";
        die "Could not find db_config.json at $config_path";
    }
    
    open my $fh, "<", $config_path or die "Could not open $config_path: $!";
    $json_text = <$fh>;
    close $fh;
}
my $config = decode_json($json_text);
warn "DBEncy: Database config loaded. Host: $config->{shanta_ency}->{host}, Database: $config->{shanta_ency}->{database}";

# Add more detailed logging for debugging
warn "DBEncy: Database connection details:";
warn "  Host: $config->{shanta_ency}->{host}";
warn "  Database: $config->{shanta_ency}->{database}";
warn "  Username: $config->{shanta_ency}->{username}";
warn "  Port: $config->{shanta_ency}->{port}";

# Create the DSN string explicitly with additional options
my $dsn = "DBI:mysql:database=$config->{shanta_ency}->{database};host=$config->{shanta_ency}->{host};port=$config->{shanta_ency}->{port};mysql_connect_timeout=10;mysql_read_timeout=30;mysql_write_timeout=30;mysql_ssl=0;mysql_local_infile=1";
warn "DBEncy: Using DSN: $dsn";

# Set the schema_class and connect_info attributes
__PACKAGE__->config(
    schema_class => 'Comserv::Model::Schema::Ency',
    connect_info => [
        # Use array form to ensure DSN is used exactly as specified
        $dsn,
        $config->{shanta_ency}->{username},
        $config->{shanta_ency}->{password},
        {
            # Add connection debugging
            RaiseError => 1,
            PrintError => 1,
            AutoCommit => 1,
            mysql_enable_utf8 => 1,
            on_connect_do => [
                "SET NAMES 'utf8'",
                "SET CHARACTER SET 'utf8'"
            ],
            # Add MySQL-specific connection options
            mysql_local_infile => 1,
            mysql_enable_utf8mb4 => 1,
            # Force using TCP/IP instead of socket
            mysql_socket => '',
            # Disable hostname resolution
            mysql_host_is_ip => 1
        }
    ]
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

# Test the database connection and log any errors
sub test_connection {
    my ($self, $c) = @_;
    
    # Get the logging utility
    my $logging = $c ? $c->log : undef;
    
    # Get the current route if available
    my $route = $c && $c->request ? $c->request->path : 'unknown_route';
    
    # Get hostname information for debugging
    my $hostname = eval { Sys::Hostname::hostname() } || 'unknown';
    my $ip_address = eval {
        my $host = Sys::Hostname::hostname();
        my $packed_ip = gethostbyname($host);
        if ($packed_ip) {
            return inet_ntoa($packed_ip);
        }
        return 'unknown';
    } || 'unknown';
    
    # Log hostname information
    if ($logging) {
        $logging->info("DBEncy: Connection test from hostname: $hostname ($ip_address) for route: $route");
    }
    
    # Try direct DBI connection first for better error reporting
    eval {
        require DBI;
        # Explicitly specify the host to avoid using localhost
        my $direct_dsn = "DBI:mysql:database=$config->{shanta_ency}->{database};host=$config->{shanta_ency}->{host};port=$config->{shanta_ency}->{port};mysql_connect_timeout=5;mysql_ssl=0";
        
        if ($logging) {
            $logging->info("DBEncy: Attempting direct connection with DSN: $direct_dsn");
            $logging->info("DBEncy: Using username: $config->{shanta_ency}->{username}");
            $logging->info("DBEncy: Using host: $config->{shanta_ency}->{host}");
        }
        
        my $direct_dbh = DBI->connect(
            $direct_dsn,
            $config->{shanta_ency}->{username},
            $config->{shanta_ency}->{password},
            { 
                RaiseError => 0, 
                PrintError => 0, 
                AutoCommit => 1,
                # Force TCP/IP connection
                mysql_socket => '',
                # Disable hostname resolution
                mysql_host_is_ip => 1
            }
        );
        
        if ($direct_dbh) {
            if ($logging) {
                $logging->info("DBEncy: Direct DBI connection successful for route: $route");
            }
            $direct_dbh->disconnect();
        } else {
            my $dbi_error = $DBI::errstr || 'Unknown error';
            if ($logging) {
                $logging->error("DBEncy: Direct DBI connection failed: $dbi_error for route: $route");
            }
            
            # Add to debug_errors if we have a context
            if ($c && ref($c->stash) eq 'HASH') {
                my $debug_errors = $c->stash->{debug_errors} ||= [];
                push @$debug_errors, "DBEncy: Direct DBI connection failed: $dbi_error for route: $route";
                push @$debug_errors, "DBEncy: Using DSN: $direct_dsn";
                push @$debug_errors, "DBEncy: Attempted to connect from: $hostname ($ip_address)";
                push @$debug_errors, "DBEncy: Attempted to connect to host: $config->{shanta_ency}->{host}";
            }
        }
    };
    
    # Now try the standard DBIC connection
    eval {
        my $dbh = $self->schema->storage->dbh;
        my $result = $dbh->selectrow_arrayref("SELECT 1");
        
        if ($result && $result->[0] == 1) {
            # Connection successful
            if ($logging) {
                $logging->info("DBEncy: Database connection test successful for route: $route");
            }
            
            # Add to debug_msg if we have a context
            if ($c && ref($c->stash) eq 'HASH') {
                my $debug_msg = $c->stash->{debug_msg} ||= [];
                push @$debug_msg, "DBEncy: Database connection test successful for route: $route";
                push @$debug_msg, "DBEncy: Using DSN: $dsn";
                push @$debug_msg, "DBEncy: Connected from: $hostname ($ip_address)";
                push @$debug_msg, "DBEncy: Connected to host: $config->{shanta_ency}->{host}";
            }
            
            return 1;
        } else {
            # Connection failed
            if ($logging) {
                $logging->error("DBEncy: Database connection test failed - no result for route: $route");
                $logging->error("DBEncy: Using DSN: $dsn");
                $logging->error("DBEncy: Attempted to connect from: $hostname ($ip_address)");
                $logging->error("DBEncy: Attempted to connect to host: $config->{shanta_ency}->{host}");
            }
            
            # Add to debug_errors if we have a context
            if ($c && ref($c->stash) eq 'HASH') {
                my $debug_errors = $c->stash->{debug_errors} ||= [];
                push @$debug_errors, "DBEncy: Database connection test failed - no result for route: $route";
                push @$debug_errors, "DBEncy: Using DSN: $dsn";
                push @$debug_errors, "DBEncy: Attempted to connect from: $hostname ($ip_address)";
                push @$debug_errors, "DBEncy: Attempted to connect to host: $config->{shanta_ency}->{host}";
            }
            
            return 0;
        }
    };
    
    if ($@) {
        # Connection error
        my $error = $@;
        
        if ($logging) {
            $logging->error("DBEncy: Database connection error for route: $route");
            $logging->error("DBEncy: Error details: $error");
            $logging->error("DBEncy: Using DSN: $dsn");
            $logging->error("DBEncy: Attempted to connect from: $hostname ($ip_address)");
            $logging->error("DBEncy: Attempted to connect to host: $config->{shanta_ency}->{host}");
        }
        
        # Add to debug_errors if we have a context
        if ($c && ref($c->stash) eq 'HASH') {
            my $debug_errors = $c->stash->{debug_errors} ||= [];
            push @$debug_errors, "DBEncy: Database connection error for route: $route";
            push @$debug_errors, "DBEncy: Error details: $error";
            push @$debug_errors, "DBEncy: Using DSN: $dsn";
            push @$debug_errors, "DBEncy: Attempted to connect from: $hostname ($ip_address)";
            push @$debug_errors, "DBEncy: Attempted to connect to host: $config->{shanta_ency}->{host}";
            
            # Add to success_msg to ensure it's displayed to the user
            my $success_msg = $c->stash->{success_msg} ||= [];
            push @$success_msg, "Database connection error. Please check the logs for details.";
        }
        
        return 0;
    }
}

1;