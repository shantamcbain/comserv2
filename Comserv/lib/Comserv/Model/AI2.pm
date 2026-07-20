package Comserv::Model::AI2;

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

# -------------------------------------------------------------------
# Thin dispatcher for the AI2 namespace.
#
# AI2.pm (Controller) calls $c->model('AI2')->get_available_models($c).
# Rather than duplicating provider logic here, this delegates to the
# permanent AI2 model classes (Router, ModelManager, Provider::*). This
# keeps the controller's single entry point stable and gives us one
# place to fan out aggregate calls (e.g. "all models across all
# providers") as the v2 migration lands.
# -------------------------------------------------------------------

sub get_available_models {
    my ($self, $c, %opts) = @_;
    my $router = try { $c->model('AI2::Router') } catch { undef };
    return $router
        ? $router->get_available_models($c, %opts)
        : [];
}

sub select_best_model {
    my ($self, $c, %opts) = @_;
    my $router = try { $c->model('AI2::Router') } catch { undef };
    return $router
        ? $router->select_best_model($c, %opts)
        : ['grok-beta'];
}

__PACKAGE__->meta->make_immutable;

1;
