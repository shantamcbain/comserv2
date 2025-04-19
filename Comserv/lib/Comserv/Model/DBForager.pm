package Comserv::Model::DBForager;

use strict;

use JSON;
use base 'Catalyst::Model::DBIC::Schema';
use Catalyst::Utils;
use Sys::Hostname;
use Socket;
use Data::Dumper;

# Load the database configuration from db_config.json
my $json_text;
{
    local $/; # Enable 'slurp' mode
    
    # Use the absolute path to the db_config.json file
    my $config_path = "/home/shanta/PycharmProjects/comserv2/Comserv/db_config.json";
    warn "DBForager: Loading database config from: $config_path";
    
    # Add logging for debugging
    if (-e $config_path) {
        warn "DBForager: Config file exists at: $config_path";
    } else {
        warn "DBForager: Config file NOT FOUND at: $config_path";
        die "Could not find db_config.json at $config_path";
    }
    
    open my $fh, "<", $config_path or die "Could not open $config_path: $!";
    $json_text = <$fh>;
    close $fh;
}
my $config = decode_json($json_text);
warn "DBForager: Database config loaded. Host: $config->{shanta_forager}->{host}, Database: $config->{shanta_forager}->{database}";

# Add more detailed logging for debugging
warn "DBForager: Database connection details:";
warn "  Host: $config->{shanta_forager}->{host}";
warn "  Database: $config->{shanta_forager}->{database}";
warn "  Username: $config->{shanta_forager}->{username}";
warn "  Port: $config->{shanta_forager}->{port}";

# Create the DSN string explicitly with additional options
my $dsn = "DBI:mysql:database=$config->{shanta_forager}->{database};host=$config->{shanta_forager}->{host};port=$config->{shanta_forager}->{port};mysql_connect_timeout=10;mysql_read_timeout=30;mysql_write_timeout=30;mysql_ssl=0;mysql_local_infile=1";
warn "DBForager: Using DSN: $dsn";

__PACKAGE__->config(
    schema_class => 'Comserv::Model::Schema::Forager',
    connect_info => [
        # Use array form to ensure DSN is used exactly as specified
        $dsn,
        $config->{shanta_forager}->{username},
        $config->{shanta_forager}->{password},
        {
            mysql_enable_utf8 => 1,
            on_connect_do => [
                "SET NAMES 'utf8'",
                "SET CHARACTER SET 'utf8'"
            ],
            # Add connection debugging
            RaiseError => 1,
            PrintError => 1,
            AutoCommit => 1,
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
    return [$herbs_with_apis->all];
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
        $logging->info("DBForager: Connection test from hostname: $hostname ($ip_address) for route: $route");
    }
    
    # Try direct DBI connection first for better error reporting
    eval {
        require DBI;
        # Explicitly specify the host to avoid using localhost
        my $direct_dsn = "DBI:mysql:database=$config->{shanta_forager}->{database};host=$config->{shanta_forager}->{host};port=$config->{shanta_forager}->{port};mysql_connect_timeout=5;mysql_ssl=0";
        
        if ($logging) {
            $logging->info("DBForager: Attempting direct connection with DSN: $direct_dsn");
            $logging->info("DBForager: Using username: $config->{shanta_forager}->{username}");
            $logging->info("DBForager: Using host: $config->{shanta_forager}->{host}");
        }
        
        my $direct_dbh = DBI->connect(
            $direct_dsn,
            $config->{shanta_forager}->{username},
            $config->{shanta_forager}->{password},
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
                $logging->info("DBForager: Direct DBI connection successful for route: $route");
            }
            $direct_dbh->disconnect();
        } else {
            my $dbi_error = $DBI::errstr || 'Unknown error';
            if ($logging) {
                $logging->error("DBForager: Direct DBI connection failed: $dbi_error for route: $route");
            }
            
            # Add to debug_errors if we have a context
            if ($c && ref($c->stash) eq 'HASH') {
                my $debug_errors = $c->stash->{debug_errors} ||= [];
                push @$debug_errors, "DBForager: Direct DBI connection failed: $dbi_error for route: $route";
                push @$debug_errors, "DBForager: Using DSN: $direct_dsn";
                push @$debug_errors, "DBForager: Attempted to connect from: $hostname ($ip_address)";
                push @$debug_errors, "DBForager: Attempted to connect to host: $config->{shanta_forager}->{host}";
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
                $logging->info("DBForager: Database connection test successful for route: $route");
            }
            
            # Add to debug_msg if we have a context
            if ($c && ref($c->stash) eq 'HASH') {
                my $debug_msg = $c->stash->{debug_msg} ||= [];
                push @$debug_msg, "DBForager: Database connection test successful for route: $route";
                push @$debug_msg, "DBForager: Using DSN: $dsn";
                push @$debug_msg, "DBForager: Connected from: $hostname ($ip_address)";
                push @$debug_msg, "DBForager: Connected to host: $config->{shanta_forager}->{host}";
            }
            
            return 1;
        } else {
            # Connection failed
            if ($logging) {
                $logging->error("DBForager: Database connection test failed - no result for route: $route");
                $logging->error("DBForager: Using DSN: $dsn");
                $logging->error("DBForager: Attempted to connect from: $hostname ($ip_address)");
                $logging->error("DBForager: Attempted to connect to host: $config->{shanta_forager}->{host}");
            }
            
            # Add to debug_errors if we have a context
            if ($c && ref($c->stash) eq 'HASH') {
                my $debug_errors = $c->stash->{debug_errors} ||= [];
                push @$debug_errors, "DBForager: Database connection test failed - no result for route: $route";
                push @$debug_errors, "DBForager: Using DSN: $dsn";
                push @$debug_errors, "DBForager: Attempted to connect from: $hostname ($ip_address)";
                push @$debug_errors, "DBForager: Attempted to connect to host: $config->{shanta_forager}->{host}";
            }
            
            return 0;
        }
    };
    
    if ($@) {
        # Connection error
        my $error = $@;
        
        if ($logging) {
            $logging->error("DBForager: Database connection error for route: $route");
            $logging->error("DBForager: Error details: $error");
            $logging->error("DBForager: Using DSN: $dsn");
            $logging->error("DBForager: Attempted to connect from: $hostname ($ip_address)");
            $logging->error("DBForager: Attempted to connect to host: $config->{shanta_forager}->{host}");
        }
        
        # Add to debug_errors if we have a context
        if ($c && ref($c->stash) eq 'HASH') {
            my $debug_errors = $c->stash->{debug_errors} ||= [];
            push @$debug_errors, "DBForager: Database connection error for route: $route";
            push @$debug_errors, "DBForager: Error details: $error";
            push @$debug_errors, "DBForager: Using DSN: $dsn";
            push @$debug_errors, "DBForager: Attempted to connect from: $hostname ($ip_address)";
            push @$debug_errors, "DBForager: Attempted to connect to host: $config->{shanta_forager}->{host}";
            
            # Add to success_msg to ensure it's displayed to the user
            my $success_msg = $c->stash->{success_msg} ||= [];
            push @$success_msg, "Database connection error. Please check the logs for details.";
        }
        
        return 0;
    }
}