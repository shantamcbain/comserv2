package Comserv::Controller::3d;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }

=head1 NAME

Comserv::Controller::3d - Catalyst Controller for 3D feature

=head1 DESCRIPTION

Catalyst Controller for handling the 3D feature landing page.

=head1 METHODS

=cut

=head2 index

The landing page for the 3D feature.

=cut

sub index :Path :Args(0) {
    my ( $self, $c ) = @_;

    # Set the template for the 3D feature landing page
    $c->stash(template => '3d/index.tt');
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