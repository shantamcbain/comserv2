package Comserv::Controller::Beekeeping::Harvest;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

BEGIN { extends 'Catalyst::Controller'; }

sub honey :Path('/Beekeeping/harvest') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'honey', "Beekeeping::Harvest honey called");
    $c->stash(
        template  => 'Beekeeping/harvest.tt',
        debug_msg => 'Honey Production',
    );
}

1;
