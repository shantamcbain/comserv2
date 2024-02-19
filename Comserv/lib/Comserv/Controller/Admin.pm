package Comserv::Controller::Admin;
use Moose;
use namespace::autoclean;
use Data::Dumper;
BEGIN { extends 'Catalyst::Controller'; }

sub begin : Private {
    my ( $self, $c ) = @_;

    # Check if the user is logged in
    if (!$c->user_exists) {
        $c->response->redirect($c->uri_for('/user/login'));
        $c->detach();
    }
    # Fetch the roles from the session
    my $roles = $c->session->{roles};
    # Log the roles
    $c->log->info("admin begin Roles: " . Dumper($roles));  # Change this line
    # Check if roles is defined and is an array reference
    if (defined $roles && ref $roles eq 'ARRAY') {
        # Check if the user has the 'admin' role
        if (grep { $_ eq 'admin' } @$roles) {
            # User is an admin, proceed with the request
        } else {
            # User is not an admin, redirect to error page
        #    $c->response->redirect($c->uri_for('/error'));
            $c->detach();
        }
    } else {
        # Roles is not defined or not an array, redirect to error page
       # $c->response->redirect($c->uri_for('/index'));
        $c->detach();
    }
}

sub index :Path :Args(0) {
    my ( $self, $c ) = @_;

    # Log the application's configured template path
    $c->log->debug("Template path: " . $c->path_to('root'));

    # Set the TT template to use.
    $c->stash(template => 'Admin/index.tt');

    # Forward to the view
    $c->forward($c->view('TT'));
}

__PACKAGE__->meta->make_immutable;

1;
