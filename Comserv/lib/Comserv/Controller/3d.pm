package Comserv::Controller::3d;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }

sub index :Path :Args(0) {
    my ( $self, $c ) = @_;
    $c->session->{MailServer} = "http://webmail.usbm.ca";

    my $sitename = $c->session->{SiteName} || '3d';

    $c->stash(
        sitename => $sitename,
        template => '3d/index.tt',
    );
}

__PACKAGE__->meta->make_immutable;

1;
