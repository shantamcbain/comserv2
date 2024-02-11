package Comserv::Controller::Todo;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }

sub index :Path :Args(0) {
    my ( $self, $c ) = @_;

    # Retrieve all of the todo records as todo model objects and store in the stash
 #   $c->stash(todos => [$c->model('DB::Todo')->all]);

    # Set the TT template to use.
    $c->stash(template => 'todo/todo.tt');
   $c->forward($c->view('TT'));
}
sub todo :Path('/todo') :Args(0) {
    my ( $self, $c ) = @_;

    # Retrieve all of the todo records as todo model objects and store in the stash
   # $c->stash(todos => [$c->model('DB::Todo')->all]);

    # Set the TT template to use.
    $c->stash(template => 'todo/todo.tt');
   $c->forward($c->view('TT'));
}

sub addtodo :Path('/todo/addtodo') :Args(0) {
    my ( $self, $c ) = @_;

    # Set the TT template to use.
    $c->stash(template => 'todo/addtodo.tt');
    $c->forward($c->view('TT'));
}

__PACKAGE__->meta->make_immutable;

1;