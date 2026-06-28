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

# === New methods for Container Status Overview ===

sub delete_container {
    my ($self, $name, $force) = @_;
    my $cmd = $force ? "docker rm -f \"$name\" 2>&1" : "docker rm \"$name\" 2>&1";
    my $output = `\$cmd`;
    my $exit = $? >> 8;
    return {
        success => $exit == 0,
        output  => $output,
        message => $exit == 0 ? "Container $name removed" : "Failed to remove $name"
    };
}

sub create_dated_backup {
    my ($self, $container_name) = @_;
    my $date_tag = `date +%Y%m%d_%H%M%S`;
    chomp $date_tag;
    my $backup_name = "${container_name}-bk-${date_tag}";

    my $stop = `docker stop "$container_name" 2>&1 || true`;
    my $rename = `docker rename "$container_name" "$backup_name" 2>&1 || true`;

    return {
        success => 1,
        backup_name => $backup_name,
        output => "Stopped and renamed to $backup_name"
    };
}

sub get_image_created {
    my ($self, $image) = @_;
    my $out = `docker inspect --format='{{.Created}}' "$image" 2>/dev/null | head -1`;
    chomp $out if $out;
    return $out || '';
}

__PACKAGE__->meta->make_immutable;

1;
