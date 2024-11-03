package Comserv::Model::DBSchemaManager;

use strict;
use warnings;
use base 'Catalyst::Model';
use DBI;
use JSON;
use File::Slurp;
use FindBin;
use Try::Tiny;
use Log::Log4perl qw(:easy);
use Comserv::Model::DBEncy;
use Data::Dumper;
print Dumper(\@INC);
# Initialize logging
Log::Log4perl->easy_init($DEBUG);

# Load the database configuration from db_config.json
my $json_text;
{
    local $/; # Enable 'slurp' mode
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

        unless ($database_exists) {
            $dbh->do("CREATE DATABASE ency");
            $self->deploy_schema();
            $self->restore_backup();
            $self->{redirect_to} = 'admin/index.tt';
            $self->{error_msg} = 'Database created and schema deployed.';
        } else {
            # Connect to the 'ency' databasea
            $dsn = "DBI:mysql:ency;host=$config->{shanta_forager}->{host};port=$config->{shanta_forager}->{port}";
            $dbh = DBI->connect($dsn, $username, $password, { RaiseError => 1, PrintError => 0 });

            $self->check_and_update_schema();
            my $tables_exist = $dbh->selectrow_array("SHOW TABLES LIKE 'sitedomain'");
            if (!$tables_exist) {
                $self->{redirect_to} = 'admin/add_schema.tt';
                $self->{error_msg} = 'No tables found. Please add the schema.';
            } else {
                my $tables_empty = $dbh->selectrow_array("SELECT COUNT(*) FROM sitedomain") == 0;
                if ($tables_empty) {
                    $self->restore_backup();
                    $self->{redirect_to} = 'admin/restore.tt';
                    $self->{error_msg} = 'Tables are empty. Please restore from backup.';
                } else {
                    $self->{redirect_to} = undef;
                }
            }
        }

        $dbh->disconnect;
    } catch {
        ERROR("Error in check_and_create_database: $_");
        $self->{redirect_to} = 'admin/index.tt';
        $self->{error_msg} = "Error: $_";
    };
}

sub restore_backup {
    my ($self, $c) = @_;  # Ensure context is passed

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

        $self->{backup_success} = "Backup restored successfully.";
        $dbh->disconnect;

        # Redirect to the default home page
        $c->response->redirect($c->uri_for('/'));

    } catch {
        $self->{backup_error} = "Error in restore_backup: $_";
        $c->response->redirect($c->uri_for('/error')); # Redirect to an error page
    };
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

1;