package Comserv::Model::User;
use Moose;
use namespace::autoclean;

extends 'Catalyst::Model';
extends  'Catalyst::Authentication::User';

has '_user' => (
    is => 'ro',
     is => 'ro',
    lazy => 1,
    default => sub {
        die "_user attribute must be set before it's used";
    },
);

sub get_object {
    my $self = shift;
    return $self->_user;
}

sub for_session {
    my $self = shift;
    return $self->_user->id;
}

sub from_session {
    my ($self, $c, $id) = @_;
    return $self->new(_user => $c->model('DBEncy::User')->find($id));
}

sub supports {
    my ($self, $feature) = @_;
    return 1 if $feature eq 'session';
    return 0;
}
sub roles {
    my $self = shift;
    return [ map $_->role, $self->_user->roles->all ];
}


__PACKAGE__->meta->make_immutable;

1;
