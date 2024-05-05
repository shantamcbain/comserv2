package Comserv::Controller::CSC;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }

sub index :Path :Args(0) {
    my ($self, $c) = @_;


    # Handle the case when the controller name doesn't exist

    $c->stash(template => 'CSC/CSC.tt');

    $c->forward($c->view('TT'));
}
sub debug :Path('/voip') {
    my ($self, $c) = @_;
    my $site_name = $c->stash->{SiteName};
    $c->stash(template => 'CSC/voip.tt');
    $c->forward($c->view('TT'));

}
__PACKAGE__->meta->make_immutable;

1;
