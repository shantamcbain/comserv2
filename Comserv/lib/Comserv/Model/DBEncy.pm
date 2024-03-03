package Comserv::Model::DBEncy;

use strict;
use base 'Catalyst::Model::DBIC::Schema';
use Sys::Hostname;
use Socket;
use JSON;

my $hostname = hostname;
my $is_dev = $hostname eq '0.0.0.0' || inet_aton($hostname) ? 1 : 0;
my $json_text;
{
    local $/; # Enable 'slurp' mode
open my $fh, "<", "db_config.json" or die "Could not open db_config.json: $!";
    $json_text = <$fh>;
    close $fh;
}
my $config = decode_json($json_text);

__PACKAGE__->config(
    schema_class => 'Comserv::Model::Schema::Ency',

          connect_info => {
            dsn => "dbi:mysql:dbname=$config->{shanta_ency}->{database};host=$config->{shanta_ency}->{host};port=$config->{shanta_ency}->{port}",
            user => $config->{shanta_ency}->{username},
            password => $config->{shanta_ency}->{password},
        }
    );



# In your DBEncy.pm file

# Existing code...


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

# Existing code...
1;