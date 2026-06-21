package Comserv::Model::AI::Router;

use Moose;
use namespace::autoclean;
use Try::Tiny;

extends 'Catalyst::Model';

=head1 NAME

Comserv::Model::AI::Router - Routes AI chat requests to appropriate backend (local KB, Ollama, Grok)

=cut

# All dependencies optional for safe Catalyst startup
has 'membership' => ( is => 'ro', required => 0 );
has 'ollama'     => ( is => 'ro', required => 0 );
has 'grok'       => ( is => 'ro', required => 0 );
has 'logging'    => ( is => 'ro', lazy => 1, default => sub { Comserv::Util::Logging->instance } );

sub COMPONENT {
    my ($class, $c, $config) = @_;
    my $self = $class->SUPER::COMPONENT($c, $config);
    return $self;
}

sub route_request {
    my ($self, $query, $context) = @_;
    $context ||= {};

    my $user_roles = $context->{user_roles} || [];
    my $is_privileged = grep { $_ =~ /^(admin|developer|editor)$/i } @$user_roles;

    # Local KB fast path
    if ($self->ollama) {
        my $kb_result = eval { $self->ollama->quick_kb_lookup($query) };
        if ($kb_result && $kb_result->{found}) {
            $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__,
                'route_request', "KB hit for query");
            return {
                backend => 'local_kb',
                result => $kb_result,
                reason => 'kb_hit'
            };
        }
    }

    # Tier-based routing
    my $tier = eval { $self->ollama ? $self->ollama->classify_query_tier($query) : 'simple' } || 'simple';

    if (!$is_privileged || $tier eq 'simple') {
        return {
            backend => 'ollama',
            model   => ($tier eq 'complex' ? 'qwen3-coder' : 'phi4'),
            use_search => 0,
            reason => 'local_default'
        };
    }

    return {
        backend => 'grok',
        model   => 'grok-4-fast-reasoning',
        use_search => 1,
        reason => 'grok_escalation'
    };
}

__PACKAGE__->meta->make_immutable;

1;