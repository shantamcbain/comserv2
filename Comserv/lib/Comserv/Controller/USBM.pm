package Comserv::Controller::USBM;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

# Set the namespace for this controller
__PACKAGE__->config(namespace => 'USBM');

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "USBM controller auto method called");
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Request path: " . $c->req->uri->path);
    return 1; # Allow the request to proceed
}

sub index :Path :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "USBM index method called");

    $c->session->{MailServer} = "http://webmail.usbm.ca";

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Setting template to USBM/USBM.tt");
    $c->stash(template => 'USBM/USBM.tt');
    $c->forward($c->view('TT'));
}



=encoding utf8

=head1 AUTHOR

Shanta McBain

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;
