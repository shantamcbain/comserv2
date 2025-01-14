package Comserv::Model::ENCYModel;
use Moose;
use namespace::autoclean;

extends 'Catalyst::Model';

has 'ency_schema' => (
    is => 'ro',
    required => 1,
);

has 'forager_schema' => (
    is => 'ro',
    required => 1,
);

sub COMPONENT {
    my ($class, $app, $args) = @_;

    my $ency_schema = $app->model('DBEncy');
    my $forager_schema = $app->model('DBForager');
    return $class->new({ %$args, ency_schema => $ency_schema, forager_schema => $forager_schema });
}

# Method to add a new herb record
sub add_herb {
    my ($self, $herb_data) = @_;
    my $herb_rs = $self->forager_schema->resultset('Herb');
    return $herb_rs->create($herb_data);
}

sub get_reference_by_id {
    my ($self, $id) = @_;
    my $reference = $self->ency_schema->resultset('Reference')->find($id);
    return $reference;
}

sub create_reference {
    my ($self, $data) = @_;
    my $reference = $self->ency_schema->resultset('Reference')->create($data);
    return $reference;
}

sub get_category_by_id {
    my ($self, $id) = @_;
    my $category = $self->ency_schema->resultset('Category')->find($id);
    return $category;
}

sub create_category {
    my ($self, $data) = @_;
    my $category = $self->ency_schema->resultset('Category')->create($data);
    return $category;
}

__PACKAGE__->meta->make_immutable;
1;