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

# Other methods remain unchanged...

__PACKAGE__->meta->make_immutable;  # Make the package immutable for performance
1;
