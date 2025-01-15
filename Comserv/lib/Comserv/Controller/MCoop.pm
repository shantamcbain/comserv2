package Comserv::Controller::MCoop;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }

sub index :Path :Args(0) {
    my ( $self, $c ) = @_;
   $c->session->{MailServer} = "http://webmail.computersystemconsulting.ca";

    # Set the template to coop/index.tt
    $c->stash(template => 'coop/index.tt');

    # Forward to the TT view to render the template
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
