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

sub get_recommended_models {
    my ($self, $c) = @_;
    # Placeholder - integrate real router logic later
    return [
        { name => 'grok-beta', label => 'Grok Beta (Recommended)' },
        { name => 'llama3.2', label => 'Llama 3.2 (Local)' },
        { name => 'grok-4-fast-reasoning', label => 'Grok 4 Fast' },
    ];
}
sub get_available_branches {
    my ($self, $c) = @_;
    return ['main', 'develop', 'feature/ai2-editor'];
}
# Placeholder for models
sub get_available_models {
    my ($self, $c, %opts) = @_;
    return [];
}
sub select_best_model {
    my ($self, $c, %opts) = @_;
    # Simple for now - expand with real scoring
    return ['grok-beta', 'ollama-llama3.2', 'grok-4-fast-reasoning'];
}
__PACKAGE__->meta->make_immutable;

1;