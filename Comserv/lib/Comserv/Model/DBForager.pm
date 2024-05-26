package Comserv::Model::DBForager;

use strict;

use JSON;  # Add this line-*`
use base 'Catalyst::Model::DBIC::Schema';

# Load the database configuration from db_config.json
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
    schema_class => 'Comserv::Model::Schema::Forager',
    connect_info => {
        dsn => "dbi:mysql:dbname=$config->{shanta_forager}->{database};host=$config->{shanta_forager}->{host};port=$config->{shanta_forager}->{port}",
        user => $config->{shanta_forager}->{username},
        password => $config->{shanta_forager}->{password},
    }
);
sub get_herbal_data {
    my ($self) = @_;
    my $dbforager = $self->schema->resultset('Herb')->search(
        { 'botanical_name' => { '!=' => '' } },
        { order_by => 'botanical_name' }
    );
    return [$dbforager->all]

}
# In Comserv::Model::DBForager
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
