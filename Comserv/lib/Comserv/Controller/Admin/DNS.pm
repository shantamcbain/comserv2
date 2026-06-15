package Comserv::Controller::Admin::DNS;

use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }

# Alias /admin/dns/* → CloudflareAPI (Application DNS). Templates and nav use this path.

sub index :Path('/admin/dns') :Args(0) {
    my ($self, $c) = @_;
    $c->forward('CloudflareAPI', 'index');
}

sub zone :Path('/admin/dns/zone') :Args(1) {
    my ($self, $c, $zone_name) = @_;
    $c->forward('CloudflareAPI', 'zone', [$zone_name]);
}

sub add_record :Path('/admin/dns/add_record') :Args(1) {
    my ($self, $c, $zone_name) = @_;
    $c->forward('CloudflareAPI', 'add_record', [$zone_name]);
}

sub edit_record :Path('/admin/dns/edit_record') :Args(2) {
    my ($self, $c, $zone_name, $record_id) = @_;
    $c->forward('CloudflareAPI', 'edit_record', [$zone_name, $record_id]);
}

sub delete_record :Path('/admin/dns/delete_record') :Args(2) {
    my ($self, $c, $zone_name, $record_id) = @_;
    $c->forward('CloudflareAPI', 'delete_record', [$zone_name, $record_id]);
}

__PACKAGE__->meta->make_immutable;

1;