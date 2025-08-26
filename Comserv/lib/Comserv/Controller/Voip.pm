package Comserv::Controller::Voip;
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
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Voip controller auto method called");
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Request path: " . $c->req->uri->path);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Request method: " . $c->req->method);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Controller: " . __PACKAGE__);
    return 1; # Allow the request to proceed
}

# Default action for the base path
sub index :Global :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Voip controller index method called");
    $c->stash(template => 'CSC/voip.tt');
    $c->forward($c->view('TT'));
}

# Alternative action with a different name
sub voip :Global :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'voip', "Voip controller voip method called");
    $c->stash(template => 'CSC/voip.tt');
    $c->forward($c->view('TT'));
}

__PACKAGE__->meta->make_immutable;

1;