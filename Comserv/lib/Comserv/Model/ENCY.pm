package Comserv::Model::ENCY;
use Moose;
use namespace::autoclean;

extends 'Catalyst::Model';

has 'schema' => (
    is => 'ro',
    required => 1,
);
sub COMPONENT {
    my ($class, $app, $args) = @_;

    my $schema = $app->model('DBEncy');
    return $class->new({ %$args, schema => $schema });
}


# In ENCY.pm
sub get_reference_by_id {
    my ($self, $c, $id) = @_;
    my $dbency = $c->model('DBEncy');
    my $reference = $dbency->resultset('Reference')->find($id);
    return $reference;
}

sub create_reference {
    my ($self, $data) = @_;
    # Implement the logic to create a new reference
    my $reference = $self->resultset('Reference')->create($data);
    return $reference;
}

sub get_category_by_id {
    my ($self, $id) = @_;
    # Implement the logic to get a category by its id
    my $category = $self->resultset('Category')->find($id);
    return $category;
}

sub create_category {
    my ($self, $data) = @_;
    # Implement the logic to create a new category
    my $category = $self->resultset('Category')->create($data);
    return $category;
}

__PACKAGE__->meta->make_immutable;
1;