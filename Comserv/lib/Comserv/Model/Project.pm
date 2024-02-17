package Comserv::Model::Project;
use Moose;
use namespace::autoclean;

extends 'Catalyst::Model';


use strict;
use warnings;
use Data::Dumper;

sub get_projects {
    my ($self, $schema, $sitename) = @_;
   # Get a DBIx::Class::Schema object


    # Get the Project resultset
    my $project_rs = $schema->resultset('Project');

    # Prepare the DBIx::Class query
    my @projects = $project_rs->search(
        {
            sitename => $sitename,
            status    => { '!=' => 3 }
        }
    )->all;

print "Projects: ", Dumper(@projects);

    return \@projects;
}
__PACKAGE__->meta->make_immutable;

1;
