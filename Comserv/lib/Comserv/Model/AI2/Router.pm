package Comserv::Model::AI2::Router;

use Moose;
use namespace::autoclean;

use Try::Tiny;
use JSON qw(encode_json decode_json);

use Comserv::Util::Logging;

extends 'Catalyst::Model';

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

# Basic router for now - expand as needed
sub route_request {
    my ($self, $c, %args) = @_;
    # TODO: implement routing logic
    return { success => 1, provider => 'ollama' };
}

# Placeholder for models
sub get_available_models {
    my ($self, $c, %opts) = @_;
    return [];
}

__PACKAGE__->meta->make_immutable;

1;