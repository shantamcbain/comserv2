package Comserv::Model::AI::Coding;
use Moose;
use namespace::autoclean;

=head1 NAME

Comserv::Model::AI::Coding - Coding widget, file browser, apply_fix, template editor support

=cut

# Real logic (list_dir, read_file, apply_fix, etc.) will be moved here
# from the old controller in a later step.

sub list_dir {
    my ($self, $c, %args) = @_;
    return { success => 0, error => 'Coding::list_dir not yet extracted' };
}

sub read_file {
    my ($self, $c, %args) = @_;
    return { success => 0, error => 'Coding::read_file not yet extracted' };
}

sub apply_fix {
    my ($self, $c, %args) = @_;
    return { success => 0, error => 'Coding::apply_fix not yet extracted' };
}

1;

__PACKAGE__->meta->make_immutable;