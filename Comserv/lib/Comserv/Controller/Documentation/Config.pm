package Comserv::Controller::Documentation::Config;
use Moose;
use namespace::autoclean;
use Comserv::Util::DocumentationConfig;
use Comserv::Util::Logging;
use JSON;

BEGIN { extends 'Catalyst::Controller'; }

=head1 NAME

Comserv::Controller::Documentation::Config - Controller for documentation configuration

=head1 DESCRIPTION

This controller handles the documentation configuration system.

=head1 METHODS

=head2 index

Main documentation configuration page

=cut

sub index :Path :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user has admin or developer role
    unless ($c->user_exists && ($c->user->role eq 'admin' || $c->user->role eq 'developer')) {
        $c->stash(error_msg => "You don't have permission to access this page");
        $c->detach('/error/access_denied');
        return;
    }
    
    # Get documentation configuration
    my $config = Comserv::Util::DocumentationConfig->instance();
    
    # Get categories and pages
    my $categories = $config->get_categories();
    my $pages = $config->get_pages();
    
    # Add to stash
    $c->stash(
        categories => $categories,
        pages => $pages,
        template => 'Documentation/config/index.tt'
    );
}

=head2 reload

Reload documentation configuration

=cut

sub reload :Local :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user has admin or developer role
    unless ($c->user_exists && ($c->user->role eq 'admin' || $c->user->role eq 'developer')) {
        $c->stash(error_msg => "You don't have permission to access this page");
        $c->detach('/error/access_denied');
        return;
    }
    
    # Get documentation configuration
    my $config = Comserv::Util::DocumentationConfig->instance();
    
    # Reload configuration
    $config->reload_config();
    
    # Add success message
    $c->stash(status_msg => "Documentation configuration reloaded successfully");
    
    # Redirect back to index
    $c->response->redirect($c->uri_for($self->action_for('index')));
}

=head2 export

Export documentation configuration as JSON

=cut

sub export :Local :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user has admin or developer role
    unless ($c->user_exists && ($c->user->role eq 'admin' || $c->user->role eq 'developer')) {
        $c->stash(error_msg => "You don't have permission to access this page");
        $c->detach('/error/access_denied');
        return;
    }
    
    # Get documentation configuration
    my $config = Comserv::Util::DocumentationConfig->instance();
    
    # Get categories and pages
    my $categories = $config->get_categories();
    my $pages = $config->get_pages();
    
    # Create JSON
    my $json = encode_json({
        categories => $categories,
        pages => $pages
    });
    
    # Set response
    $c->response->content_type('application/json');
    $c->response->body($json);
}

=head2 scan

Scan documentation files and update configuration

=cut

sub scan :Local :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user has admin or developer role
    unless ($c->user_exists && ($c->user->role eq 'admin' || $c->user->role eq 'developer')) {
        $c->stash(error_msg => "You don't have permission to access this page");
        $c->detach('/error/access_denied');
        return;
    }
    
    # This would scan the documentation directories and update the configuration
    # For now, just redirect back to index with a message
    $c->stash(status_msg => "Documentation scan not yet implemented");
    
    # Redirect back to index
    $c->response->redirect($c->uri_for($self->action_for('index')));
}

__PACKAGE__->meta->make_immutable;

1;