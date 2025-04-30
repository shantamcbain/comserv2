package Comserv::Model::DBSchemaManager;

use strict;
use warnings;
use Moose;
use namespace::autoclean;
extends 'Catalyst::Model';
use Comserv::Util::Logging;
use JSON;
use File::Slurp;
use FindBin;
use DBI;
use Try::Tiny;
use Log::Log4perl qw(:easy);
use Comserv::Model::DBEncy;
use Data::Dumper;
use Catalyst::Utils;  # For path_to

# Define an attribute 'logging' using Moose
has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# Initialize logger
Log::Log4perl->easy_init($DEBUG);

# Load the database configuration from db_config.json
my $config_file;
my $json_text;

# Try to load the config file using Catalyst::Utils if the application is initialized
eval {
    $config_file = Catalyst::Utils::path_to('db_config.json');
};

# Fallback to FindBin if Catalyst::Utils fails (during application initialization)
if ($@ || !defined $config_file) {
    $config_file = "$FindBin::Bin/../db_config.json";
    warn "Using FindBin fallback for config file: $config_file";
}

# Load the configuration file
eval {
    local $/;    # Enable 'slurp' mode
    open my $fh, "<", $config_file or die "Could not open $config_file: $!";
    $json_text = <$fh>;
    close $fh;
};

if ($@) {
    die "Error loading config file $config_file: $@";
}

my $config = decode_json($json_text);

# List tables in the appropriate database
sub list_tables {
    my ($self, $c, $database) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_tables', "Starting list_tables action for database: $database");

    my $model;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_tables', "Accessing model for database: $database Model: $model");
    if ($database eq 'FORAGER') {
        $model = $c->model('DBForager');
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_tables', "Accessing DBForager model");
    } elsif ($database eq 'ENCY') {
        $model = $c->model('DBEncy');
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_tables', "Accessing DBEncy model");
    } else {
        die "Unknown database: $database";
    }
    if ($database eq 'FORAGER') {
        $model = $c->model('DBForager');
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_tables', "Accessing DBForager model");
    } elsif ($database eq 'ENCY') {
        $model = $c->model('DBEncy');
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_tables', "Accessing DBEncy model");
    } else {
        die "Unknown database: $database";
    }


    my $tables;
    eval {
        $tables = $model->list_tables();
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'list_tables', "Error listing tables: $@");
        die "Failed to list tables: $@";
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_tables', "Successfully listed tables for database: $database");
    return $tables;
}


# Fetch column metadata for a given table
sub get_table_columns {
    my ($self, $database, $table) = @_;
    my $dbh = $self->get_dbh($database);
    my $sth = $dbh->column_info(undef, undef, $table, undef);
    my @columns;
    while (my $row = $sth->fetchrow_hashref) {
        push @columns, {
            name     => $row->{COLUMN_NAME},
            type     => $row->{TYPE_NAME},
            size     => $row->{COLUMN_SIZE},
            nullable => $row->{NULLABLE},
        };
    }
    $sth->finish;
    return \@columns;
}

# New method to initialize schema based on config
sub initialize_schema {
    my ($self, $config) = @_;

    # Fixed DSN format for MySQL - most common format
    my $data_source_name = "DBI:mysql:database=$config->{database};host=$config->{host};port=$config->{port}";

    my $database_handle = DBI->connect($data_source_name, $config->{username}, $config->{password},
        { RaiseError => 1, AutoCommit => 1 });

    # Load appropriate schema file based on database type
    my $schema_file = $self->get_schema_file($config->{db_type});

    # Execute schema creation
    my @statements = split /;/, read_file($schema_file);

    for my $statement (@statements) {
        next unless $statement =~ /\S/;
        $database_handle->do($statement) or die $database_handle->errstr;
    }
}

# Helper to get appropriate schema file
sub get_schema_file {
    my ($self, $database_type) = @_;
    
    my $schema_file;
    
    # Try to use Catalyst::Utils first
    eval {
        if ($database_type eq 'mysql') {
            $schema_file = Catalyst::Utils::path_to('sql', 'schema_mysql.sql');
        } elsif ($database_type eq 'SQLite') {
            $schema_file = Catalyst::Utils::path_to('sql', 'schema_sqlite.sql');
        } else {
            die "Unsupported database type: $database_type";
        }
    };
    
    # Fallback to FindBin if Catalyst::Utils fails
    if ($@ || !defined $schema_file) {
        if ($database_type eq 'mysql') {
            $schema_file = $FindBin::Bin . "/../sql/schema_mysql.sql";
        } elsif ($database_type eq 'SQLite') {
            $schema_file = $FindBin::Bin . "/../sql/schema_sqlite.sql";
        } else {
            die "Unsupported database type: $database_type";
        }
        warn "Using FindBin fallback for schema file: $schema_file";
    }
    
    return $schema_file;
}

# Other methods remain unchanged...

__PACKAGE__->meta->make_immutable;  # Make the package immutable for performance
1;
