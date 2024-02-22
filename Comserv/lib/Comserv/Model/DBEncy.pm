package Comserv::Model::DBEncy;

use strict;
use base 'Catalyst::Model::DBIC::Schema';
use Sys::Hostname;
use Socket;

my $hostname = hostname;
my $is_dev = $hostname eq '0.0.0.0' || inet_aton($hostname) ? 1 : 0;

__PACKAGE__->config(
    schema_class => 'Comserv::Model::Schema::Ency',

    connect_info => {
        dsn => $is_dev ? 'dbi:mysql:dbname=ency' : 'dbi:mysql:dbname=shanta_ency;host=remote_server_ip',
        user => $is_dev ? 'shanta_forager' : 'remote_username',
        password => $is_dev ? 'UA=nPF8*m+T#' : 'remote_password',
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