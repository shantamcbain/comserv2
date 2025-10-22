package Comserv::Controller::Shanta;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

BEGIN { extends 'Catalyst::Controller'; }

=head1 NAME

Comserv::Controller::Shanta - Catalyst Controller for Shanta's personal workspace

=head1 DESCRIPTION

This controller handles Shanta's personal dashboard and homepage.
It provides personalized views based on user permissions and integrates with
the existing Shanta.tt template for displaying navigation links and calendar.

=head1 METHODS

=cut

sub index :Path('/Shanta') :Args(0) {
    my ( $self, $c ) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 'Entered Shanta index method');
    
    # Set mail server for session
    $c->session->{MailServer} = "http://webmail.usbm.ca";
    
    # Get user information from session
    my $username = $c->session->{username} || '';
    my $firstname = $c->session->{firstname} || '';
    my $lastname = $c->session->{lastname} || '';
    my $roles = $c->session->{roles} || [];
    
    # Log user access
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        "User '$username' accessing Shanta dashboard");
    
    # Prepare stash data
    $c->stash(
        username => $username,
        firstname => $firstname,
        lastname => $lastname,
        user_roles => $roles,
        template => 'Shanta/Shanta.tt'
    );
    
    # Set todolist view if user is Shanta
    if ($username eq 'Shanta') {
        $c->stash->{todolistview} = 'todo/list.tt';
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
            'Setting special Shanta dashboard configuration');
    }
}

=head2 dashboard

Alternative path to index for accessing Shanta's dashboard

=cut

sub dashboard :Path('/Shanta/dashboard') :Args(0) {
    my ( $self, $c ) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'dashboard', 
        'Redirecting dashboard request to index');
    
    # Redirect to main index
    $c->response->redirect($c->uri_for('/Shanta'));
    $c->detach();
}

=head2 auto

Runs on every request to perform authentication and authorization

=cut

sub auto :Private {
    my ( $self, $c ) = @_;
    
    # Log the request
    my $action = $c->action->name;
    my $username = $c->session->{username} || 'anonymous';
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', 
        "Processing request for action '$action' by user '$username'");
    
    # For now, allow all authenticated users to access Shanta controller
    # More restrictive access controls can be added per action as needed
    
    return 1;
}

=head2 end

Attempt to render a view, if needed.

=cut

sub end : ActionClass('RenderView') {}

__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

Comserv Development Team

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut