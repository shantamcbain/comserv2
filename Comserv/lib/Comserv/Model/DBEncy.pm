package Comserv::Model::DBEncy;

use strict;
use base 'Catalyst::Model::DBIC::Schema';
use Sys::Hostname;
use Socket;
use JSON;
use Data::Dumper;
use FindBin;
use File::Spec;

my $json_text;
{
    local $/; # Enable 'slurp' mode
    # Find db_config.json relative to the application root
    my $config_path = File::Spec->catfile($FindBin::Bin, '..', 'db_config.json');
    open my $fh, "<", $config_path or die "Could not open $config_path: $!";
    $json_text = <$fh>;
    close $fh;
}
my $config = decode_json($json_text);

# Function to test database connectivity
sub test_connection {
    my ($dsn, $user, $password) = @_;
    
    my $success = 0;
    eval {
        require DBI;
        my $dbh = DBI->connect($dsn, $user, $password, { 
            RaiseError => 0, 
            PrintError => 0,
            mysql_connect_timeout => 5,
            timeout => 5 
        });
        if ($dbh) {
            $success = 1;
            $dbh->disconnect;
        }
    };
    
    return $success;
}

# Function to select best database connection based on priority
sub get_best_connection {
    my @connections;
    
    # Collect all non-template connections and sort by priority
    for my $key (keys %$config) {
        next if $key =~ /^_/; # Skip template/metadata entries
        my $conn = $config->{$key};
        next unless ref($conn) eq 'HASH' && exists $conn->{priority};
        push @connections, { key => $key, %$conn };
    }
    
    # Sort by priority (lower number = higher priority)
    @connections = sort { $a->{priority} <=> $b->{priority} } @connections;
    
    print "🔍 Testing database connections in priority order...\n";
    
    # Test each connection in priority order
    for my $conn (@connections) {
        my $dsn;
        if ($conn->{db_type} eq 'mysql') {
            $dsn = "dbi:mysql:dbname=$conn->{database};host=$conn->{host};port=$conn->{port}";
        } elsif ($conn->{db_type} eq 'sqlite') {
            $dsn = "dbi:SQLite:dbname=$conn->{database_path}";
        }
        
        print "  Priority $conn->{priority}: Testing $conn->{key} ($conn->{description})... ";
        
        if (test_connection($dsn, $conn->{username}, $conn->{password})) {
            print "✅ Success!\n";
            return {
                dsn => $dsn,
                user => $conn->{username} // '',
                password => $conn->{password} // '',
                connection_name => $conn->{key},
                description => $conn->{description}
            };
        } else {
            print "❌ Failed\n";
        }
    }
    
    # If all connections failed, return the highest priority one anyway
    print "⚠️  All connections failed, using highest priority configuration anyway\n";
    my $fallback = $connections[0];
    my $dsn = $fallback->{db_type} eq 'mysql' 
        ? "dbi:mysql:dbname=$fallback->{database};host=$fallback->{host};port=$fallback->{port}"
        : "dbi:SQLite:dbname=$fallback->{database_path}";
    
    return {
        dsn => $dsn,
        user => $fallback->{username} // '',
        password => $fallback->{password} // '',
        connection_name => $fallback->{key},
        description => $fallback->{description}
    };
}

# Get the best available connection
my $best_conn = get_best_connection();
print "📡 Using database connection: $best_conn->{connection_name} - $best_conn->{description}\n\n";

# Set the schema_class and connect_info attributes
__PACKAGE__->config(
    schema_class => 'Comserv::Model::Schema::Ency',
    connect_info => {
        dsn => $best_conn->{dsn},
        user => $best_conn->{user},
        password => $best_conn->{password},
    }
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

1;
