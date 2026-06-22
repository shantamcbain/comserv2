package Comserv::Model::AI::Access;
use Moose;
use namespace::autoclean;

=head1 NAME

Comserv::Model::AI::Access - Role-based access, dev mode checks, editor permissions

=cut

sub can_use_coding {
    my ($self, $c) = @_;
    # Local implementation (replaces old controller _is_dev_mode delegation)
    my $roles = $c->session->{roles} || [];
    $roles = [$roles] unless ref $roles eq 'ARRAY';
    return grep { /admin|developer/i } @$roles ? 1 : 0;
}

sub can_use_template_editor {
    my ($self, $c) = @_;
    my $roles = $c->session->{roles} || [];
    $roles = [$roles] unless ref $roles eq 'ARRAY';
    return grep { /^admin$/i } @$roles ? 1 : 0;
}

1;

__PACKAGE__->meta->make_immutable;