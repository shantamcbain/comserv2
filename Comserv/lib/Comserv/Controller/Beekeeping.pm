package Comserv::Controller::Beekeeping;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

BEGIN { extends 'Catalyst::Controller'; }

sub base :Chained('/') :PathPart('Beekeeping') :CaptureArgs(0) {
    my ($self, $c) = @_;
}

sub index :Chained('base') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Beekeeping index called");
    $c->stash(template => 'BMaster/BMaster.tt');
}

sub bee_pasture :Path('/Beekeeping/bee_pasture') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'bee_pasture', "Beekeeping bee_pasture called");
    $c->response->redirect('/ENCY/BeePastureView');
}

sub apiary :Path('/Beekeeping/apiary') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'apiary', "Beekeeping apiary called");
    if ($c->session->{user_id}) {
        $c->response->redirect($c->uri_for('/Apiary'));
    } else {
        $c->stash(template => 'Beekeeping/apiary.tt');
    }
}

sub queens :Path('/Beekeeping/Queens') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'queens', "Beekeeping queens called");
    $c->response->redirect('/Apiary/QueenRearing');
}

sub hive :Path('/Beekeeping/hive') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'hive', "Beekeeping hive called");
    $c->response->redirect('/Apiary/HiveManagement');
}

sub environment :Path('/Beekeeping/environment') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'environment', "Beekeeping environment called");
    $c->stash(
        template  => 'Beekeeping/environment.tt',
        debug_msg => 'Environmental Considerations',
    );
}

sub education :Path('/Beekeeping/education') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'education', "Beekeeping education called");
    $c->stash(
        template  => 'Beekeeping/education.tt',
        debug_msg => 'Education and Collaboration',
    );
}

sub products :Path('/Beekeeping/products') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'products', "Beekeeping products called");
    $c->stash(
        template  => 'Beekeeping/products.tt',
        debug_msg => 'Bee Products and Services',
    );
}

1;
