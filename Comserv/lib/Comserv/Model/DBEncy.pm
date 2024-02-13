package Comserv::Model::DBEncy;

use strict;
use base 'Catalyst::Model::DBIC::Schema';

__PACKAGE__->config(
    schema_class => 'Comserv::Model::Schema::Ency',
    
    connect_info => {
        dsn => 'dbi:mysql:dbname=ency',
        user => 'shanta_forager',
        password => 'UA=nPF8*m+T#',
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