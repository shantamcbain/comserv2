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

# Safe method to get username that handles undefined user objects
sub get_safe_username {
    my ($self, $c, $default) = @_;
    $default ||= 'Guest';
    
    # First try to get username from authenticated user
    if ($c->user_exists && $c->user) {
        eval {
            my $username = $c->user->username;
            return $username if defined $username && $username ne '';
        };
        # If user object exists but username method fails, continue to session check
    }
    
    # Fall back to session username
    if ($c->session->{username}) {
        return $c->session->{username};
    }
    
    # Final fallback
    return $default;
}



__PACKAGE__->meta->make_immutable;

1;