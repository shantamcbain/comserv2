package Comserv::Controller::WeaverBeck;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# Set the namespace for this controller
__PACKAGE__->config(namespace => 'WeaverBeck');
# Set the default view for this controller
sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "WeaverBeck controller auto method called");
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Request path: " . $c->req->uri->path);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Request method: " . $c->req->method);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Controller: " . __PACKAGE__);

    # Initialize debug_errors array if needed
    $c->stash->{debug_errors} = [] unless (defined $c->stash->{debug_errors} && ref $c->stash->{debug_errors} eq 'ARRAY');

    # Initialize debug_msg array if needed
    $c->stash->{debug_msg} = [] unless (defined $c->stash->{debug_msg} && ref $c->stash->{debug_msg} eq 'ARRAY');

    return 1; # Allow the request to proceed
}

# Main index page
sub index :Path :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Entered WeaverBeck index method");

    # Ensure debug_errors is an array reference
    $c->stash->{debug_errors} = [] unless ref $c->stash->{debug_errors} eq 'ARRAY';
    push @{$c->stash->{debug_errors}}, "Entered WeaverBeck index method";

    # Add debug message
    # Ensure debug_msg is an array reference
    $c->stash->{debug_msg} = [] unless ref $c->stash->{debug_msg} eq 'ARRAY';
    push @{$c->stash->{debug_msg}}, "Weaver Beck Family Home Page";

    # Set the template
    $c->stash(
        template => 'WeaverBeck/index.tt',
        title => 'Weaver Beck Family',
        # debug_msg is already set as an array above
    );
}

__PACKAGE__->meta->make_immutable;

1;
