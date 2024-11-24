package Comserv::Controller::MCoop;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }

=head1 NAME

Comserv::Controller::MCoop - Catalyst Controller

=head1 DESCRIPTION

Catalyst Controller for Monashee Coop in Lumby BC.

=head1 METHODS

=cut

=head2 index

=cut

sub index :Path :Args(0) {
    my ( $self, $c ) = @_;

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
