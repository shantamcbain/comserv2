package Comserv::Controller::CSC;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }

sub index :Path :Args(0) {
    my ($self, $c) = @_;

    # Set the MailServer in the session
    $c->session->{MailServer} = "http://webmail.computersystemconsulting.ca";

    # Set the template to be rendered
    $c->stash(template => 'CSC/CSC.tt');

    # Forward to the TT view for rendering
    $c->forward($c->view('TT'));
}

sub auto :Private {
    my ( $self, $c ) = @_;
    $c->session->{MailServer} = "http://webmail.computersytemconsulting.ca";

}

sub debug :Path('/voip') {
    my ($self, $c) = @_;
    my $site_name = $c->stash->{SiteName};
    $c->stash(template => 'CSC/voip.tt');
    $c->forward($c->view('TT'));

}
__PACKAGE__->meta->make_immutable;

1;
