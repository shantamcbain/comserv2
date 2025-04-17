package Comserv::Controller::IT;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

=head1 NAME

Comserv::Controller::IT - IT Controller for Comserv

=head1 DESCRIPTION

Controller for IT-related functionality in the Comserv application.
Provides access to IT resources, documentation, and tools.

=head1 METHODS

=head2 index

Main entry point for the IT section

=cut

sub index :Path :Args(0) {
    my ($self, $c) = @_;
    
    my $logger = $self->logging;
    $logger->log_to_file("IT controller index action called", undef, 'INFO');
    
    # Push debug messages to stash if in debug mode
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "IT controller index action called";
    }
    
    # Set up the stash for the template
    $c->stash(
        template => 'it/index.tt',
        current_view => 'TT',
        title => 'IT Resources',
        section => 'it',
    );
    
    # Log with details
    $c->log->info("IT index page accessed by user: " . ($c->user ? $c->user->username : 'guest'));
}

=head2 resources

Display IT resources

=cut

sub resources :Local :Args(0) {
    my ($self, $c) = @_;
    
    my $logger = $self->logging;
    $logger->log_to_file("IT resources action called", undef, 'INFO');
    
    # Push debug messages to stash if in debug mode
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "IT resources action called";
    }
    
    # Set up the stash for the template
    $c->stash(
        template => 'it/resources.tt',
        current_view => 'TT',
        title => 'IT Resources',
        section => 'it',
    );
    
    # Log with details
    $c->log->info("IT resources page accessed by user: " . ($c->user ? $c->user->username : 'guest'));
}

=head2 documentation

Display IT documentation

=cut

sub documentation :Local :Args(0) {
    my ($self, $c) = @_;
    
    my $logger = $self->logging;
    $logger->log_to_file("IT documentation action called", undef, 'INFO');
    
    # Push debug messages to stash if in debug mode
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "IT documentation action called";
    }
    
    # Set up the stash for the template
    $c->stash(
        template => 'it/documentation.tt',
        current_view => 'TT',
        title => 'IT Documentation',
        section => 'it',
    );
    
    # Log with details
    $c->log->info("IT documentation page accessed by user: " . ($c->user ? $c->user->username : 'guest'));
}

=head2 support

Display IT support information

=cut

sub support :Local :Args(0) {
    my ($self, $c) = @_;
    
    my $logger = $self->logging;
    $logger->log_to_file("IT support action called", undef, 'INFO');
    
    # Push debug messages to stash if in debug mode
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "IT support action called";
    }
    
    # Set up the stash for the template
    $c->stash(
        template => 'it/support.tt',
        current_view => 'TT',
        title => 'IT Support',
        section => 'it',
    );
    
    # Log with details
    $c->log->info("IT support page accessed by user: " . ($c->user ? $c->user->username : 'guest'));
}

=head2 tools

Display IT tools

=cut

sub tools :Local :Args(0) {
    my ($self, $c) = @_;
    
    my $logger = $self->logging;
    $logger->log_to_file("IT tools action called", undef, 'INFO');
    
    # Push debug messages to stash if in debug mode
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "IT tools action called";
    }
    
    # Set up the stash for the template
    $c->stash(
        template => 'it/tools.tt',
        current_view => 'TT',
        title => 'IT Tools',
        section => 'it',
    );
    
    # Log with details
    $c->log->info("IT tools page accessed by user: " . ($c->user ? $c->user->username : 'guest'));
}

=head2 network

Display network information

=cut

sub network :Local :Args(0) {
    my ($self, $c) = @_;
    
    my $logger = $self->logging;
    $logger->log_to_file("IT network action called", undef, 'INFO');
    
    # Push debug messages to stash if in debug mode
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "IT network action called";
    }
    
    # Set up the stash for the template
    $c->stash(
        template => 'it/network.tt',
        current_view => 'TT',
        title => 'Network Information',
        section => 'it',
    );
    
    # Log with details
    $c->log->info("IT network page accessed by user: " . ($c->user ? $c->user->username : 'guest'));
}

=head2 servers

Display server information

=cut

sub servers :Local :Args(0) {
    my ($self, $c) = @_;
    
    my $logger = $self->logging;
    $logger->log_to_file("IT servers action called", undef, 'INFO');
    
    # Push debug messages to stash if in debug mode
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "IT servers action called";
    }
    
    # Set up the stash for the template
    $c->stash(
        template => 'it/servers.tt',
        current_view => 'TT',
        title => 'Server Information',
        section => 'it',
    );
    
    # Log with details
    $c->log->info("IT servers page accessed by user: " . ($c->user ? $c->user->username : 'guest'));
}

=head2 security

Display security information

=cut

sub security :Local :Args(0) {
    my ($self, $c) = @_;
    
    my $logger = $self->logging;
    $logger->log_to_file("IT security action called", undef, 'INFO');
    
    # Push debug messages to stash if in debug mode
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "IT security action called";
    }
    
    # Set up the stash for the template
    $c->stash(
        template => 'it/security.tt',
        current_view => 'TT',
        title => 'IT Security',
        section => 'it',
    );
    
    # Log with details
    $c->log->info("IT security page accessed by user: " . ($c->user ? $c->user->username : 'guest'));
}

=head1 AUTHOR

Shanta

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;