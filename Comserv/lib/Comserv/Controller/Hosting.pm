package Comserv::Controller::Hosting;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Hosting controller auto method called");
    return 1; # Allow the request to proceed
}

# Default action for the base path
sub index :Path :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Hosting controller index method called");
    $c->stash(template => 'CSC/hosting_via_voip.tt');
    $c->forward($c->view('TT'));
}

__PACKAGE__->meta->make_immutable;

1;