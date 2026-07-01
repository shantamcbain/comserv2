package Comserv::Model::AI2::ModelManager;

use Moose;
use namespace::autoclean;

use Comserv::Util::Logging;

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

sub get_available_models {
    my ($self, $c, %opts) = @_;
    # TODO: implement
    return [];
}

__PACKAGE__->meta->make_immutable;

1;