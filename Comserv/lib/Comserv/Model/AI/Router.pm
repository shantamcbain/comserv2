package Comserv::Model::AI::ModelManager;

use Moose;
use namespace::autoclean;
use Try::Tiny;
use JSON;

extends 'Catalyst::Model';

has 'logging' => (
    is => 'ro',
    lazy => 1,
    default => sub { Comserv::Util::Logging->instance },
);

sub get_available_models {
    my ($self, $c) = @_;

    my @models = ();

    try {
        # Ollama models
        my $ollama = $c->model('Ollama');
        if ($ollama) {
            my ($host, $port) = $c->controller('AI')->_get_current_ollama_config($c, 1);
            $ollama->host($host) if $host;
            $ollama->port($port) if $port;

            my $installed = eval { $ollama->list_models() } || [];
            foreach my $m (@$installed) {
                my $name = ref($m) ? ($m->{name} || $m->{model} || '') : $m;
                next unless $name;
                push @models, {
                    name     => $name,
                    provider => 'ollama',
                    label    => $name,
                    type     => 'local'
                };
            }
        }

        # Grok / external
        if ($c->session->{user_id}) {
            push @models, {
                name => 'grok-4-fast-reasoning',
                provider => 'grok',
                label => 'Grok 4 Fast Reasoning (xAI)',
                type => 'cloud'
            };
            push @models, {
                name => 'grok-3',
                provider => 'grok',
                label => 'Grok 3 (xAI)',
                type => 'cloud'
            };
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'get_available_models', "Error: $_");
    };

    return \@models;
}

__PACKAGE__->meta->make_immutable;

1;