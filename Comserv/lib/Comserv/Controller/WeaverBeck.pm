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

sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "WeaverBeck controller auto method called");
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Request path: " . $c->req->uri->path);
    
    # Initialize debug_errors array if needed
    $c->stash->{debug_errors} = [] unless (defined $c->stash->{debug_errors} && ref $c->stash->{debug_errors} eq 'ARRAY');
    
    # Initialize debug_msg array if needed
    $c->stash->{debug_msg} = [] unless (defined $c->stash->{debug_msg} && ref $c->stash->{debug_msg} eq 'ARRAY');
    
    return 1; # Allow the request to proceed
}

# Main index action
sub index :Path('/WeaverBeck') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Entered WeaverBeck index method");
    
    # Ensure debug_msg is an array reference
    $c->stash->{debug_msg} = [] unless ref $c->stash->{debug_msg} eq 'ARRAY';
    push @{$c->stash->{debug_msg}}, "WeaverBeck Index Page";
    
    # Set the template
    $c->stash(
        template => 'weaverbeck/index.tt',
        title => 'WeaverBeck',
    );
    
    # Add detailed logging for debugging
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        "Using template: weaverbeck/index.tt");
}

# About page
sub about :Path('/WeaverBeck/about') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'about', "Entered WeaverBeck about method");
    
    # Ensure debug_msg is an array reference
    $c->stash->{debug_msg} = [] unless ref $c->stash->{debug_msg} eq 'ARRAY';
    push @{$c->stash->{debug_msg}}, "WeaverBeck About Page";
    
    # Set the template
    $c->stash(
        template => 'weaverbeck/about.tt',
        title => 'About WeaverBeck',
    );
}

# Services page
sub services :Path('/WeaverBeck/services') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'services', "Entered WeaverBeck services method");
    
    # Ensure debug_msg is an array reference
    $c->stash->{debug_msg} = [] unless ref $c->stash->{debug_msg} eq 'ARRAY';
    push @{$c->stash->{debug_msg}}, "WeaverBeck Services Page";
    
    # Set the template
    $c->stash(
        template => 'weaverbeck/services.tt',
        title => 'WeaverBeck Services',
    );
}

# Contact page
sub contact :Path('/WeaverBeck/contact') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'contact', "Entered WeaverBeck contact method");
    
    # Ensure debug_msg is an array reference
    $c->stash->{debug_msg} = [] unless ref $c->stash->{debug_msg} eq 'ARRAY';
    push @{$c->stash->{debug_msg}}, "WeaverBeck Contact Page";
    
    # Set the template
    $c->stash(
        template => 'weaverbeck/contact.tt',
        title => 'Contact WeaverBeck',
    );
}

# Process contact form
sub process_contact :Path('/WeaverBeck/process_contact') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process_contact', "Processing WeaverBeck contact form");
    
    # Get form data
    my $params = $c->request->params;
    
    # Log form data
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process_contact', 
        "Form data: name=" . ($params->{name} || 'N/A') . 
        ", email=" . ($params->{email} || 'N/A') . 
        ", subject=" . ($params->{subject} || 'N/A'));
    
    # Validate form data
    my @errors;
    
    # Required fields
    push @errors, "Name is required" unless $params->{name};
    push @errors, "Email is required" unless $params->{email};
    push @errors, "Subject is required" unless $params->{subject};
    push @errors, "Message is required" unless $params->{message};
    
    # Email validation
    push @errors, "Invalid email format" if $params->{email} && $params->{email} !~ /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/;
    
    # If there are validation errors, redisplay the form with error messages
    if (@errors) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process_contact', "Validation errors: " . join(", ", @errors));
        
        # Ensure debug_errors is an array reference
        $c->stash->{debug_errors} = [] unless ref $c->stash->{debug_errors} eq 'ARRAY';
        push @{$c->stash->{debug_errors}}, "Validation errors: " . join(", ", @errors);
        
        $c->stash(
            template => 'weaverbeck/contact.tt',
            title => 'Contact WeaverBeck',
            errors => \@errors,
            form_data => $params, # Return the submitted data to pre-fill the form
        );
        return;
    }
    
    # Process the contact form - send email, etc.
    # This is a placeholder for actual email sending logic
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process_contact', "Contact form processed successfully");
    
    # Ensure success_msg is an array reference
    $c->stash->{success_msg} = [] unless ref $c->stash->{success_msg} eq 'ARRAY';
    push @{$c->stash->{success_msg}}, "Your message has been sent successfully. We will get back to you soon.";
    
    # Redirect to contact page with success message
    $c->response->redirect($c->uri_for($self->action_for('contact')));
}

# End of controller
__PACKAGE__->meta->make_immutable;

1;