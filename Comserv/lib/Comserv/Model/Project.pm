package Comserv::Model::Project;
use Moose;
use namespace::autoclean;

use Comserv::Util::Logging;
use strict;
use warnings;
use Data::Dumper;
has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);
sub get_projects {
    my ($self, $schema, $sitename) = @_;

    # Get the Project resultset
    my $project_rs = $schema->resultset('Project');

    my @projects;
    if (lc($sitename) eq 'csc') {
        # Fetch all projects if the site is 'csc'
        @projects = $project_rs->search(
            {
                status => { '!=' => 3 }
            }
        )->all;
    } else {
        # Fetch projects for the specific site
        @projects = $project_rs->search(
            {
                sitename => $sitename,
                status   => { '!=' => 3 }
            }
        )->all;
    }

    Comserv::Util::Logging->instance->log_with_details($self, __FILE__, __LINE__, 'get_projects', Dumper(@projects));

    return \@projects;
}

sub get_project {
    my ($self, $schema, $project_id) = @_;

    # Get the Project resultset
    my $project_rs = $schema->resultset('Project');

    # Prepare the DBIx::Class query
    my $project = $project_rs->find($project_id);

    return $project;
}

__PACKAGE__->meta->make_immutable;

1;
