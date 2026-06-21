package Comserv::Model::AI::Router;

use Moose;
use namespace::autoclean;
use Try::Tiny;

extends 'Catalyst::Model';

=head1 NAME
Comserv::Model::AI::Router
=cut

has 'membership' => ( is => 'ro', required => 0 );
has 'ollama'     => ( is => 'ro', required => 1 );
has 'grok'       => ( is => 'ro', required => 0 );

sub route_request {
    my ($self, $query, $context) = @_;
    $context ||= {};

    my $roles = $context->{user_roles} || [];
    my $is_privileged = grep { $_ =~ /^(admin|developer|editor)$/i } @$roles;

    # Quick local KB
    my $kb_result = try { $self->ollama->quick_kb_lookup($query) };
    if ($kb_result && $kb_result->{found}) {
        return { backend => 'local_kb', result => $kb_result, reason => 'kb_hit' };
    }

    # Classify
    my $tier = try { $self->ollama->classify_query_tier($query) } || 'simple';

    if (!$is_privileged || $tier eq 'simple') {
        return {
            backend => 'ollama',
            model   => $tier eq 'complex' ? 'qwen3-coder' : 'phi4',
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