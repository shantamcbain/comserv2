package Comserv::Controller::CSC;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

# Set the namespace for this controller
__PACKAGE__->config(namespace => 'CSC');

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "CSC controller auto method called");
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Request path: " . $c->req->uri->path);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Request method: " . $c->req->method);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Controller: " . __PACKAGE__);
    return 1; # Allow the request to proceed
}

# Default action for the base CSC path
sub base :Path :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'base', "Base method called, forwarding to index");
    $c->forward('index');
}

sub index :Local :Args(0) {
    my ($self, $c) = @_;

    # Set the MailServer in the session
    $c->session->{MailServer} = "http://webmail.computersystemconsulting.ca";
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Entered Index Method");

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Rendering CSC template");
    $c->stash(template => 'CSC/CSC.tt');
    $c->forward($c->view('TT'));
}
sub hosting :Local :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'hosting', "Entered Hosting Method");
    $c->stash(template => 'CSC/cloudhosting.tt');
    $c->forward($c->view('TT'));
}

# Alternative method for cloud hosting
sub web_hosting :Path('/CSC/web_hosting') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'web_hosting', "Entered Web Hosting Method");
    $c->stash(template => 'CSC/cloudhosting.tt');
    $c->forward($c->view('TT'));
}


sub voip :Local :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'voip', "Entered VOIP Method");

    my $site_name = $c->stash->{SiteName};
    $c->stash(template => 'CSC/voip.tt');
    $c->forward($c->view('TT'));
}

# New method for hosting that matches the voip method exactly
sub hosting_debug :Action :Path('/voip') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'hosting_debug', "Entered Hosting Debug Method");

    my $site_name = $c->stash->{SiteName};
    $c->stash(template => 'CSC/cloudhosting.tt');
    $c->forward($c->view('TT'));
}

# Method for cloud hosting
sub hosting_via_voip :Path('/CSC/hosting_via_voip') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'hosting_via_voip', "Entered Cloud Hosting Method");

    my $site_name = $c->stash->{SiteName};
    $c->stash(
        template => 'CSC/cloudhosting.tt',
        show_hosting => 1
    );
    $c->forward($c->view('TT'));
}

# Email test form
sub email_test :Local :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'email_test', "Email test form requested");
    
    # If this is a form submission, process it
    if ($c->req->method eq 'POST') {
        my $to = $c->req->params->{to};
        my $subject = $c->req->params->{subject} || 'Test Email from Comserv';
        my $message = $c->req->params->{message} || 'This is a test email from the Comserv system.';
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'email_test', 
            "Attempting to send test email to: $to with subject: $subject");
        
        # Get email configuration from the stash (set by site_setup in Root.pm)
        my $mail_from = $c->stash->{mail_from};
        my $mail_replyto = $c->stash->{mail_replyto};
        
        # Log the email configuration for debugging
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'email_test',
            "Email configuration - From: " . ($mail_from || 'undefined') . 
            ", Reply-To: " . ($mail_replyto || 'undefined'));
        
        eval {
            # Use default values if site configuration is missing
            my $from_address = $mail_from || 'noreply@computersystemconsulting.ca';
            my $reply_to = $mail_replyto || 'helpdesk@computersystemconsulting.ca';
            
            $c->stash->{email} = {
                to       => $to,
                from     => $from_address,
                reply_to => $reply_to,
                subject  => $subject,
                body     => $message,
            };
            
            # Send the email
            $c->forward($c->view('Email::Template'));
            
            # Set success message
            $c->flash->{success_msg} = "Test email sent successfully to $to";
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'email_test',
                "Test email sent successfully to: $to");
        };
        
        if ($@) {
            # Log email error
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'email_test',
                "Error sending test email: $@");
            $c->flash->{error_msg} = "Error sending email: $@";
        }
        
        # Redirect to avoid form resubmission
        $c->response->redirect($c->uri_for('/CSC/email_test'));
        return;
    }
    
    # Display the email test form
    $c->stash(template => 'CSC/email_test.tt');
}

# Catch-all for any other CSC paths
sub default :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'default', "Default method called");
    $c->forward('index');
}

__PACKAGE__->meta->make_immutable;

1;