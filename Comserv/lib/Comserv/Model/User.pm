package Comserv::Model::User;
use Moose;
use namespace::autoclean;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTP qw();
use Email::Simple;
use Email::Simple::Creator;
use Comserv::Util::Logging;
extends 'Catalyst::Model', 'Catalyst::Authentication::User';

has '_user' => (
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

    # Fetch the role from the user object directly
    my $role = $self->_user->role;

    # Return it as an array reference (since the session expects an array)
    return [ $role ];
}

# Ensured correct database connection and user creation
sub create_user {
    my ($self, $user_data) = @_;

    # Use the existing database connection from Comserv::Model::DBEncy
    my $schema = Comserv::Model::DBEncy->new->schema;

    # Check if the username already exists
    my $existing_user = $schema->resultset('User')->find({ username => $user_data->{username} });
    if ($existing_user) {
        return "Username already exists";
    }

    # Create a new user, ensuring 'roles' field is provided
    my $new_user = $schema->resultset('User')->create({
        %$user_data,
        roles => $user_data->{roles} // 'default_role',  # Provide a default role if not specified
    });

    return $new_user;
}



__PACKAGE__->meta->make_immutable;

1;
