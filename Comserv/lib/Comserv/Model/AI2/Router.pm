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

    try {
        my $project_root = $c->path_to('')->stringify;
        chdir $project_root or die "Cannot chdir to $project_root: $!";

        my @branches = `git branch --format='%(refname:short)' 2>&1`;
        chdir $ENV{'PWD'};  # restore

        if ($? != 0) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_available_branches', "Git failed: @branches");
            return ['main'];  # fallback
        }

        chomp @branches;
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'get_available_branches', "Found branches: " . join(', ', @branches));

        return \@branches || ['main'];
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_available_branches', "Exception: $_");
        return ['main'];  # safe fallback
    };
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