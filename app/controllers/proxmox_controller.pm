package app::controllers::proxmox_controller;
use Mojo::Base 'Mojolicious::Controller';

sub base : Chained('/') PathPrefix('proxmox') CaptureArgs(0) {
    my $self = shift;
    # Set up base functionality for Proxmox controller
}

sub get_virtual_machines {
    my $self = shift;

    # Fetch virtual machine data from Proxmox API
    my $virtual_machines = [
        { id => 100, name => 'VM 1', status => 'running' },
        { id => 101, name => 'VM 2', status => 'stopped' },
        { id => 102, name => 'VM 3', status => 'running' },
    ];

    return $virtual_machines;
}

sub index : Chained('/proxmox/base') PathPart('') Args(0) {
    my $self = shift;

    my $virtual_machines = $self->get_virtual_machines();
    return $self->render(json => { virtual_machines => $virtual_machines });
}

sub virtual_machines : Chained('/proxmox/base') PathPart('virtual_machines') Args(0) {
    my $self = shift;

    my $virtual_machines = $self->get_virtual_machines();
    return $self->render(json => { virtual_machines => $virtual_machines });
}

sub create_vm : Chained('/proxmox/base') PathPart('create_vm') Args(0) {
    my $self = shift;

    # Handle VM creation logic
    return $self->render(json => { success => 1 });
}
