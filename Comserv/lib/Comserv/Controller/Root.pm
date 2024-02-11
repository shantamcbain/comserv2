package Comserv::Controller::Root;
use Moose;
use namespace::autoclean;
use Template;
BEGIN { extends 'Catalyst::Controller' }

__PACKAGE__->config(namespace => '');

sub index :Path :Args(0){
    my ($self, $c) = @_;
    $c->stash(template => 'index.tt');
    $c->forward($c->view('TT'));
}
sub auto :Private {
    my ( $self, $c ) = @_;
    # Get the domain name
    my $domain = $c->req->uri->host;

    # Store domain in stash
    $c->stash->{domain} = $domain;
  # Store domain in session
    $c->session->{domain} = $domain;

    # Continue processing the rest of the request
    return 1;
}
sub debug :Path('/debug') {
    my ($self, $c) = @_;
    my $site_name = $c->stash->{SiteName};
    $c->stash(template => 'debug.tt');
    $c->forward($c->view('TT'));

}
sub default :Path {
    my ( $self, $c ) = @_;
    $c->response->body( 'Page not found' );
    $c->response->status(404);
}

sub end : ActionClass('RenderView') {}

__PACKAGE__->meta->make_immutable;

1;