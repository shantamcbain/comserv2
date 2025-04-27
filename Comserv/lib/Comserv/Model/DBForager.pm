package Comserv::Model::DBForager;

use strict;

use JSON;  # Add this line-*`
use base 'Catalyst::Model::DBIC::Schema';

use FindBin;
use File::Spec;

# Load the database configuration from db_config.json
my $config_file = File::Spec->catfile($FindBin::Bin, '..', 'db_config.json');
my $json_text;
{
    local $/; # Enable 'slurp' mode
    open my $fh, "<", $config_file or die "Could not open $config_file: $!";
    $json_text = <$fh>;
    close $fh;
}
my $config = decode_json($json_text);

# Print the configuration for debugging
print "DBForager Configuration:\n";
print "Host: $config->{shanta_forager}->{host}\n";
print "Database: $config->{shanta_forager}->{database}\n";
print "Username: $config->{shanta_forager}->{username}\n";

# Set the schema_class and connect_info attributes
__PACKAGE__->config(
    schema_class => 'Comserv::Model::Schema::Forager',
    connect_info => {
        # Fixed DSN format for MySQL - most common format
        dsn => "dbi:mysql:database=$config->{shanta_forager}->{database};host=$config->{shanta_forager}->{host};port=$config->{shanta_forager}->{port}",
        user => $config->{shanta_forager}->{username},
        password => $config->{shanta_forager}->{password},
        mysql_enable_utf8 => 1,
        on_connect_do => ["SET NAMES 'utf8'", "SET CHARACTER SET 'utf8'"],
        quote_char => '`',
    }
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
    return [$dbforager->all]

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
    return [$herbs_with_apis->all]
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