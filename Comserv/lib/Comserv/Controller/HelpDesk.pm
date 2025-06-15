package Comserv::Controller::HelpDesk;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

# Set the namespace for this controller
__PACKAGE__->config(namespace => 'HelpDesk');

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

=head1 NAME

Comserv::Controller::HelpDesk - HelpDesk Controller for Comserv

=head1 DESCRIPTION

Controller for the HelpDesk functionality using the chained dispatch system.

=head1 METHODS

=cut

=head2 auto

Common setup for all HelpDesk actions

=cut

sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', 
        "HelpDesk controller auto method called");
    
    # Initialize debug_msg array if it doesn't exist
    $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
    
    # Add the debug message to the array
    push @{$c->stash->{debug_msg}}, "HelpDesk controller loaded successfully";
    
    return 1; # Allow the request to proceed
}

=head2 base

Base method for chained actions

=cut

sub base :Chained('/') :PathPart('HelpDesk') :CaptureArgs(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'base', 
        "Starting HelpDesk base action");
    
    # Common setup for all HelpDesk pages
    $c->stash(section => 'helpdesk');
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'base', 
        "Completed HelpDesk base action");
}

=head2 index

Main HelpDesk page - endpoint of the chain

=cut

sub index :Chained('base') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        "Starting HelpDesk index action");
    
    # Set the template
    $c->stash(template => 'CSC/HelpDesk.tt');
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "HelpDesk index action executed";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        "Completed HelpDesk index action");
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

=head2 ticket_base

Base for all ticket-related actions

=cut

sub ticket_base :Chained('base') :PathPart('ticket') :CaptureArgs(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ticket_base', 
        "Starting ticket_base action");
    
    # Common setup for all ticket pages
    $c->stash(subsection => 'ticket');
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ticket_base', 
        "Completed ticket_base action");
}

=head2 ticket_new

Create new ticket page

=cut

sub ticket_new :Chained('ticket_base') :PathPart('new') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ticket_new', 
        "Starting ticket_new action");
    
    $c->stash(
        template => 'CSC/HelpDesk/new_ticket.tt',
        title => 'Create New Support Ticket'
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "New ticket form loaded";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ticket_new', 
        "Completed ticket_new action");
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

=head2 ticket_status

View ticket status page

=cut

sub ticket_status :Chained('ticket_base') :PathPart('status') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ticket_status', 
        "Starting ticket_status action");
    
    $c->stash(
        template => 'CSC/HelpDesk/ticket_status.tt',
        title => 'View Ticket Status'
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "Ticket status page loaded";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ticket_status', 
        "Completed ticket_status action");
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

=head2 kb

Knowledge Base page

=cut

sub kb :Chained('base') :PathPart('kb') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'kb', 
        "Starting kb action");
    
    $c->stash(
        template => 'CSC/HelpDesk/kb.tt',
        title => 'Knowledge Base'
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "Knowledge Base loaded";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'kb', 
        "Completed kb action");
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

=head2 linux_commands

Linux Commands Reference page

=cut

sub linux_commands :Chained('base') :PathPart('kb/linux_commands') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'linux_commands', 
        "Starting linux_commands action");
    
    # Include CSS and JavaScript enhancements
    $c->stash(
        template => 'CSC/HelpDesk/linux_commands.tt',
        title => 'Linux Commands Reference',
        additional_css => ['/static/css/linux_commands.css'],
        additional_js => ['/static/js/linux_commands.js']
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "Linux Commands Reference loaded with enhancements";
    push @{$c->stash->{success_msg}}, "Command reference enhanced with copy-to-clipboard functionality";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'linux_commands', 
        "Completed linux_commands action with CSS and JS enhancements");
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

=head2 contact

Contact Support page

=cut

sub contact :Chained('base') :PathPart('contact') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'contact', 
        "Starting contact action");
    
    $c->stash(
        template => 'CSC/HelpDesk/contact.tt',
        title => 'Contact Support'
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "Contact Support page loaded";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'contact', 
        "Completed contact action");
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

=head2 admin

Admin page for HelpDesk management

=cut

sub admin :Chained('base') :PathPart('admin') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin', 
        "Starting admin action");
    
    # Check if user has admin role
    my $has_admin_role = 0;
    if ($c->session->{roles}) {
        my $roles = $c->session->{roles};
        if (ref($roles) eq 'ARRAY') {
            $has_admin_role = grep { $_ eq 'admin' } @$roles;
        } elsif (!ref($roles)) {
            $has_admin_role = $roles =~ /\badmin\b/i;
        }
    }
    
    unless ($has_admin_role) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'admin', 
            "Unauthorized access attempt to HelpDesk admin by user: " . ($c->user_exists ? $c->user->username : 'Guest'));
        
        # Redirect to main HelpDesk page with error message
        $c->stash->{error_msg} = "You don't have permission to access the HelpDesk admin area.";
        $c->detach('index');
        return;
    }
    
    $c->stash(
        template => 'CSC/HelpDesk/admin.tt',
        title => 'HelpDesk Administration'
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "HelpDesk admin page loaded";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin', 
        "Completed admin action");
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

=head2 default

Fallback for HelpDesk URLs that don't match any actions

=cut

sub default :Chained('base') :PathPart('') :Args {
    my ($self, $c) = @_;
    
    my $path = join('/', @{$c->req->args});
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'default', 
        "Invalid HelpDesk path: $path");
    
    # Forward to the index action
    $c->stash(
        template => 'CSC/HelpDesk.tt',
        error_msg => "The requested HelpDesk page was not found: $path"
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "Invalid HelpDesk path: $path, forwarded to index";
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

__PACKAGE__->meta->make_immutable;

1;