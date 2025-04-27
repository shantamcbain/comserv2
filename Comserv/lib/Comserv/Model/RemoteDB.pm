package Comserv::Model::RemoteDB;

use strict;
use warnings;
use Moose;
use namespace::autoclean;
use DBI;
use DBIx::Class::Schema::Loader qw(make_schema_at);
use Try::Tiny;
use Data::Dumper;
use JSON;
use Comserv::Util::Logging;

extends 'Catalyst::Model';

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has 'connections' => (
    is      => 'rw',
    isa     => 'HashRef',
    default => sub { {} },
);

use FindBin;
use File::Spec;

# Initialize remote database connections from config
sub BUILD {
    my ($self) = @_;

    # Load the database configuration
    my $config;
    try {
        my $config_file = File::Spec->catfile($FindBin::Bin, '..', 'db_config.json');
        local $/;
        open my $fh, "<", $config_file or die "Could not open $config_file: $!";
        my $json_text = <$fh>;
        close $fh;
        $config = decode_json($json_text);

        # Print the configuration for debugging
        print "RemoteDB Configuration loaded from: $config_file\n";
        if ($config->{remote_connections}) {
            print "Found remote connections: " . join(", ", keys %{$config->{remote_connections}}) . "\n";
        } else {
            print "No remote connections found in configuration\n";
        }
    } catch {
        warn "Failed to load database configuration: $_";
        return;
    };
    
    # Initialize remote connections if they exist in config
    if ($config && $config->{remote_connections}) {
        foreach my $conn_name (keys %{$config->{remote_connections}}) {
            my $conn_config = $config->{remote_connections}{$conn_name};
            $self->add_connection($conn_name, $conn_config);
        }
    }
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