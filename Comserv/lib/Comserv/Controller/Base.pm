package Comserv::Controller::Base;
use Moose;
use namespace::autoclean;
BEGIN { extends 'Catalyst::Controller'; }

sub stash_message {
    my ($self, $c, $message) = @_;

    # Get the current array of error messages
    my $current_error_messages = $c->stash->{error_messages} || [];

    # Append the new message
    push @$current_error_messages, $message;

    # Stash the updated array
    $c->stash(error_messages => $current_error_messages);
}

__PACKAGE__->meta->make_immutable;

1;