package Comserv::Controller::Jobs;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

__PACKAGE__->config(namespace => 'jobs');

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub auto :Private {
    my ($self, $c) = @_;
    $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto',
        'Jobs controller loaded');
    return 1;
}

sub index :Path :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        'Jobs index accessed by: ' . ($c->session->{username} || 'guest'));
    $c->stash(
        template     => 'jobs/index.tt',
        current_view => 'TT',
        title        => 'Jobs & Employment',
    );
}

__PACKAGE__->meta->make_immutable;
1;
