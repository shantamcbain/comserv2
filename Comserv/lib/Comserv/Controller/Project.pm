package Comserv::Controller::Project;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }

sub index :Path :Args(0) {
    my ( $self, $c ) = @_;
   print "add_project action called\n";
    $c->response->body('Matched Comserv::Controller::Project in Project.');
}


sub add_project :Path('addproject') :Args(0) {
    my ( $self, $c ) = @_;
   print "add_project action called\n";
    # Add the SiteName to the stash
    $c->stash(
        sitename => $c->session->{SiteName},
        template => 'todo/add_project.tt'
    );

    $c->forward($c->view('TT'));
}

__PACKAGE__->meta->make_immutable;

1;
