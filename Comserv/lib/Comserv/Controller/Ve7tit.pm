package Comserv::Controller::Ve7tit;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }

sub index :Path :Args(0) {
    my ( $self, $c ) = @_;
     $c->stash(template => 've7tit/index.tt');
}

__PACKAGE__->meta->make_immutable;

1;