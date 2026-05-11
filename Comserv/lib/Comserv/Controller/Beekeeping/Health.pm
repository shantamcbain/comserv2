package Comserv::Controller::Beekeeping::Health;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

BEGIN { extends 'Catalyst::Controller'; }

sub beehealth :Path('/Beekeeping/health') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'beehealth', "Beekeeping::Health beehealth called");
    $c->stash(
        template  => 'Beekeeping/health.tt',
        debug_msg => 'Bee Health',
    );
}

1;
