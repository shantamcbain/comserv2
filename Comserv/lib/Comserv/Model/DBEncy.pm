package Comserv::Model::DBEncy;

use strict;
use base 'Catalyst::Model::DBIC::Schema';
use warnings FATAL => 'all';
use Sub::Util 'subname';
use Sys::Hostname;
use Socket;
use JSON;
use Data::Dumper;

my $json_text;
{
    local $/; # Enable 'slurp' mode
    open my $fh, "<", "db_config.json" or die "Could not open db_config.json: $!";
    $json_text = <$fh>;
    close $fh;
}
my $config = decode_json($json_text);

# Set the schema_class and connect_info attributes
__PACKAGE__->config(
    schema_class => 'Comserv::Model::Schema::Ency',
    connect_info => {
        dsn => "dbi:mysql:dbname=$config->{shanta_ency}->{database};host=$config->{shanta_ency}->{host};port=$config->{shanta_ency}->{port}",
        user => $config->{shanta_ency}->{username},
        password => $config->{shanta_ency}->{password},
    }
);

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