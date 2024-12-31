package Comserv::Controller::Forager;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);
BEGIN { extends 'Catalyst::Controller'; }

sub index :Path :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details($c, __FILE__, __LINE__, 'index', "Starting index action");
       $c->session->{MailServer} = "http://webmail.forager.com";

    $c->stash(template => 'Forager/index.tt');
        $c->forward($c->view('TT'));
}

__PACKAGE__->meta->make_immutable;

1;
