package Comserv::Model::AI2::ModelManager;

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)

use Try::Tiny;
use JSON qw(encode_json decode_json);

use Comserv::Util::Logging;

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

# ===================================================================
# AI2::ModelManager — unified model + provider discovery.
#
# Thin coordinator: the actual selection logic lives in AI2::Router; the
# provider descriptor list reuses v1 Model::AI::Provider::list_available.
# Keeps this class focused on "what models/providers can the current
# user reach" without duplicating Router's selection brain.
# ===================================================================

# Delegated merged model catalog (Ollama + external keys).
sub get_available_models {
    my ($self, $c, %opts) = @_;
    my $router = try { $c->model('AI2::Router') } catch { undef };
    return $router ? $router->get_available_models($c, %opts) : [];
}

# Provider descriptors the current user/context can use.
# Reuses v1 Model::AI::Provider::list_available (Ollama always; external
# providers from active UserApiKeys). Avoids re-implementing key lookup.
sub list_available_providers {
    my ($self, $c) = @_;

    my $prov = try { $c->model('AI::Provider') } catch { undef };
    return $prov ? $prov->list_available($c) : [
        { id => 'ollama', label => 'Local (Ollama)', type => 'local', requires_key => 0 },
    ];
}

# Lightweight catalog grouped by provider for UI dropdowns.
sub get_models_by_provider {
    my ($self, $c, %opts) = @_;

    my $models = $self->get_available_models($c, %opts) || [];
    my %by;
    for my $m (@$models) {
        my $p = $m->{provider} || 'unknown';
        push @{$by{$p}}, $m;
    }
    return \%by;
}

__PACKAGE__->meta->make_immutable;

1;
