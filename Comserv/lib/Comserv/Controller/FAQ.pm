package Comserv::Controller::FAQ;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

# Set the namespace for this controller
__PACKAGE__->config(namespace => 'faq');

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

=head1 NAME

Comserv::Controller::FAQ - FAQ Controller for Comserv

=head1 DESCRIPTION

Controller for the FAQ functionality.

=head1 METHODS

=cut

=head2 auto

Common setup for all FAQ actions

=cut

sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', 
        "FAQ controller auto method called");
    
    # Initialize debug_msg array if it doesn't exist
    $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
    
    # Add the debug message to the array
    push @{$c->stash->{debug_msg}}, "FAQ controller loaded successfully";
    
    return 1; # Allow the request to proceed
}

=head2 index

Main FAQ page

=cut

sub index :Path :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        "Starting FAQ index action");
    
    # Set the template
    $c->stash(
        template => 'CSC/FAQ/index.tt',
        title => 'Frequently Asked Questions'
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "FAQ index action executed";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        "Completed FAQ index action");
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

=head2 category

Display FAQs by category

=cut

sub category :Path('category') :Args(1) {
    my ($self, $c, $category_id) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'category', 
        "Starting FAQ category action for category_id: $category_id");
    
    # Set the template
    $c->stash(
        template => 'CSC/FAQ/category.tt',
        title => 'FAQ Category',
        category_id => $category_id
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "FAQ category action executed for category_id: $category_id";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'category', 
        "Completed FAQ category action");
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

__PACKAGE__->meta->make_immutable;

1;