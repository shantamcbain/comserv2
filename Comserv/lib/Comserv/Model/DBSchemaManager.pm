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

sub check_and_create_database {
    my ($self) = @_;

    try {
        # Connect to MySQL without specifying a database
        my $dsn = "DBI:mysql:;host=$config->{shanta_forager}->{host};port=$config->{shanta_forager}->{port}";
        my $username = $config->{shanta_forager}->{username};
        my $password = $config->{shanta_forager}->{password};

        my $dbh = DBI->connect($dsn, $username, $password, { RaiseError => 1, PrintError => 0 });

        # Check if the 'ency' database exists
        my $database_exists = $dbh->selectrow_array("SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = 'ency'");
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

sub restore_backup {
    my ($self, $c) = @_;  # Ensure context is passed

    my $tables;
    eval {
        $tables = $model->list_tables();
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'list_tables', "Error listing tables: $@");
        die "Failed to list tables: $@";
    }
    try {
        my $backup_file = "$FindBin::Bin/../ency.sql";
        my $dsn = "DBI:mysql:ency;host=$config->{shanta_forager}->{host};port=$config->{shanta_forager}->{port}";
        my $username = $config->{shanta_forager}->{username};
        my $password = $config->{shanta_forager}->{password};

        my $dbh = DBI->connect($dsn, $username, $password, { RaiseError => 1, PrintError => 0 });

        # Read and execute SQL statements
        my $sql = read_file($backup_file);
        my @statements = split /;\s*(?=\S)/, $sql;

        foreach my $statement (@statements) {
            next if $statement =~ /^\s*$/;
            $statement =~ s/^\s+|\s+$//g;
            eval {
                $dbh->do($statement);
            };
            if ($@) {
                $self->{backup_error} = "Error executing statement: $statement\nError: $@";
                $dbh->disconnect;
                return; # Stop processing on error
            }
        }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_tables', "Successfully listed tables for database: $database");
    return $tables;
        $self->{backup_success} = "Backup restored successfully.";
        $dbh->disconnect;

        # Redirect to the default home page
        $c->response->redirect($c->uri_for('/'));

    } catch {
        $self->{backup_error} = "Error in restore_backup: $_";
        $c->response->redirect($c->uri_for('/error')); # Redirect to an error page
    };
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

sub get_redirect_info {
    my ($self) = @_;
    return ($self->{redirect_to}, $self->{error_msg});
}

sub deploy_schema {
    my ($self) = @_;

    try {
        my $schema = Comserv::Model::DBEncy->new->schema;
        $schema->deploy;
        DEBUG("Schema deployed successfully.");
    } catch {
        ERROR("Error in deploy_schema: $_");
    };
}



sub check_and_update_schema {
    my ($self) = @_;

    try {
        my $schema = Comserv::Model::DBEncy->new->schema;
        my $dbh = $schema->storage->dbh;

        # Check if the schema is up-to-date
        my $tables_exist = $dbh->selectrow_array("SHOW TABLES LIKE 'sitedomain'");

        if ($tables_exist) {
            $self->compare_schemas();
        } else {
            $self->deploy_schema();
        }
    } catch {
        ERROR("Error in check_and_update_schema: $_");
    };
}

sub compare_schemas {
    my ($self) = @_;

    try {
        my $schema = Comserv::Model::DBEncy->new->schema;
        my $dbh = $schema->storage->dbh;

        # Compare the current schema with the application schema
        my $current_schema = $dbh->selectall_hashref("SHOW TABLES", 'Tables_in_ency');
        my $app_schema = $schema->source_registrations;

        my @differences;
        foreach my $table (keys %$app_schema) {
            unless (exists $current_schema->{$table}) {
                push @differences, "Table $table is missing in the database.";
            }
        }

        if (@differences) {
            return \@differences;
        } else {
            DEBUG("Schema is up-to-date.");
            return [];
        }
    } catch {
        ERROR("Error in compare_schemas: $_");
        return ["Error comparing schemas: $_"];
    };
}

__PACKAGE__->meta->make_immutable;  # Make the package immutable for performance
1;