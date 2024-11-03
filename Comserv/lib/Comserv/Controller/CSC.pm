package Comserv::Controller::CSC;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }
has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);
sub index :Path('/CSC/index') :Args(0) {
    my ($self, $c) = @_;

    Comserv::Util::Logging->log_with_details($c, __FILE__, __LINE__,
        (caller(0))[3], "Entered Index Method");

    $self->logging->log_with_details($c, __FILE__, __LINE__, "Rendering CSC template");
    $c->stash(template => 'CSC/CSC.tt');
    $c->forward($c->view('TT'));
}

sub debug :Action :Path('/voip') :Args(0) {
    my ($self, $c) = @_;

    Comserv::Util::Logging->log_with_details($c, __FILE__, __LINE__,
        (caller(0))[3], "Entered Debug Method");

    my $site_name = $c->stash->{SiteName};
    $c->stash(template => 'CSC/voip.tt');
    $c->forward($c->view('TT'));
}

__PACKAGE__->meta->make_immutable;

1;
