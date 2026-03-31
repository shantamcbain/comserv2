package Comserv::Model::Docker;
use Moose;
use namespace::autoclean;
use Comserv::Util::DockerManager;

extends 'Catalyst::Model';

has 'docker_manager' => (
    is => 'ro',
    isa => 'Comserv::Util::DockerManager',
    lazy => 1,
    default => sub { 
        my $self = shift;
        return Comserv::Util::DockerManager->new(
            environment => $ENV{CATALYST_ENV} || 'development'
        );
    }
);

sub list_containers {
    my ($self) = @_;
    return $self->docker_manager->list_containers();
}

sub restart_containers {
    my ($self, %args) = @_;
    return $self->docker_manager->restart_containers(%args);
}

sub start_container {
    my ($self, $service) = @_;
    return $self->docker_manager->start_container($service);
}

sub up_container {
    my ($self, $service) = @_;
    return $self->docker_manager->up_container($service);
}

sub stop_container {
    my ($self, $service) = @_;
    return $self->docker_manager->stop_container($service);
}

sub down_container {
    my ($self, $service) = @_;
    return $self->docker_manager->down_container($service);
}

sub get_container_logs {
    my ($self, $service, $lines) = @_;
    return $self->docker_manager->get_container_logs($service, $lines);
}

sub check_container_status {
    my ($self, $service) = @_;
    return $self->docker_manager->check_container_status($service);
}

__PACKAGE__->meta->make_immutable;

1;
