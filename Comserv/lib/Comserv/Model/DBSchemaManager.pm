package Comserv::Model::DBSchemaManager;

use strict;
use warnings;
use Moose;  # Use Moose for object system
use namespace::autoclean;  # Clean up imported functions
extends 'Catalyst::Model';  # Use extends instead of base
use Comserv::Util::Logging;
use DBI;
use JSON;
use File::Slurp;
use FindBin;
use Try::Tiny;
use Log::Log4perl qw(:easy);
use Comserv::Model::DBEncy;
use Data::Dumper;
use Comserv::Model::DBEncy;

# Define an attribute 'logging' using Moose
has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

print Dumper(\@INC);

# Initialize logger
Log::Log4perl->easy_init($DEBUG);

# Load the database configuration from db_config.json
my $json_text;
{
    local $/;    # Enable 'slurp' mode
    open my $fh, "<", "$FindBin::Bin/../db_config.json" or die "Could not open db_config.json: $!";
    $json_text = <$fh>;
    close $fh;
}
my $config = decode_json($json_text);

# Subroutine to check and create database
# Subroutine to check and create the 'ency' database if it doesn't exist
# Subroutine to check and create the 'ency' database if it doesn't exist
sub check_and_create_database {
    my ($self, $database_name, $c) = @_;

    # Validate arguments
    die "Database name is required" unless $database_name;
    die "Context object (\$c) is required for logging" unless $c;

    # Log the start of the operation
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'schema', "Checking if database '$database_name' exists.");

    # Retrieve DB handle from Catalyst context
    my $schema = $c->model('DBEncy')->schema
        or die "Failed to retrieve database schema from context";
    my $dbh = $schema->storage->dbh;

    # Check if the database exists
    my $query = "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = ?";
    my $sth = $dbh->prepare($query);
    $sth->execute($database_name);

    if ($sth->fetchrow_array) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'schema', "Database '$database_name' already exists.");
    } else {
        # Create the database if it doesn't exist
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'schema', "Database '$database_name' does not exist. Creating it.");
        $dbh->do("CREATE DATABASE `$database_name`")
            or die "Failed to create database '$database_name'";
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'schema', "Database '$database_name' has been created successfully.");
    }

    # Cleanup
    $sth->finish();

    return 1; # Indicate success
}



# Subroutine to list tables for a given database
sub list_tables {
    my ($self, $c, $database) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_tables', "Starting list_tables action for database: $database");

    my $model;

    if ($database eq 'FORAGER') {
        $model = $c->model('DBForager');
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_tables', "Using DBForager model");
    } elsif ($database eq 'ENCY') {
        $model = $c->model('DBEncy');
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_tables', "Using DBEncy model");
    } else {
        my $error_msg = "Unknown database: $database";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'list_tables', $error_msg);
        die $error_msg;
    }

    try {
        my $tables = $model->list_tables();
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_tables', "Successfully listed tables for database: $database");
        return $tables;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'list_tables', "Failed to list tables for database $database: $_");
        die "Error listing tables for database $database: $_";
    };
}

# Subroutine to restore a backup for a given database
sub restore_backup {
    my ($self, $c, $database) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'restore_backup', "Starting restore_backup for database: $database");

    # Ensure model is derived from list_tables
    my $tables = $self->list_tables($c, $database);

    unless ($tables) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'restore_backup', "No tables found to back up");
        die "No tables found for restore process.";
    }

    try {
        my $backup_file = "$FindBin::Bin/../ency.sql";
        my $dsn      = "DBI:mysql:ency;host=$config->{shanta_forager}->{host};port=$config->{shanta_forager}->{port}";
        my $username = $config->{shanta_forager}->{username};
        my $password = $config->{shanta_forager}->{password};

        my $dbh = DBI->connect($dsn, $username, $password, { RaiseError => 1, PrintError => 0 });

        # Read and execute SQL statements
        my $sql = read_file($backup_file);
        my @statements = split /;\s*(?=\S)/, $sql;

        for my $statement (@statements) {
            next if $statement =~ /^\s*$/;
            $statement =~ s/^\s+|\s+$//g;

            eval { $dbh->do($statement) };
            if ($@) {
                my $error_msg = "Error executing statement: $statement\nError: $@";
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'restore_backup', $error_msg);
                $dbh->disconnect;
                die $error_msg;
            }
        }

        # Successfully restored backup
        $self->{backup_success} = "Backup restored successfully.";
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'restore_backup', $self->{backup_success});
        $dbh->disconnect;

        $c->response->redirect($c->uri_for('/'));
    } catch {
        $self->{backup_error} = "Error in restore_backup: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'restore_backup', $self->{backup_error});
        $c->response->redirect($c->uri_for('/error'));
    };
}

__PACKAGE__->meta->make_immutable;
1;