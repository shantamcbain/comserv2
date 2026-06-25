package Comserv::Model::AI::KnowledgeBase;
use Moose;
use namespace::autoclean;

=head1 NAME

Comserv::Model::AI::KnowledgeBase - Documentation search, shared history, and KB integration

=cut

sub search_shared {
    my ($self, $c, $query, $site) = @_;
    # TODO: implement real shared history / KB search here
    # (previously delegated to controller _search_shared_history)
    return '';
}

1;

__PACKAGE__->meta->make_immutable;