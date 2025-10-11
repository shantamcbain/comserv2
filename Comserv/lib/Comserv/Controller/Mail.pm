package Comserv::Controller::Mail;
use Moose;
use namespace::autoclean;
use Try::Tiny;
use Comserv::Util::Logging;
BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub index :Path :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        "Accessing mail index page");
    
    # Set the template to users/index .tt
    $c->stash(template => 'user/mail.tt');

    # Forward to the TT view to render the template
    $c->forward($c->view('TT'));
}

sub send_welcome_email :Local {
    my ($self, $c, $user) = @_;
    
    my $site_id = $user->site_id;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_welcome_email', 
        "Sending welcome email to " . $user->email);
    
    try {
        my $mail_model = $c->model('Mail');
        my $subject = "Welcome to the Application";
        my $body = "Hello " . $user->first_name . ",\n\nWelcome to our application!";
        
        my $result = $mail_model->send_email($c, $user->email, $subject, $body, $site_id);
        
        unless ($result) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'send_welcome_email', 
                "Failed to send welcome email to " . $user->email);
            $c->stash->{debug_msg} = "Could not send welcome email";
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'send_welcome_email', 
            "Welcome email error: $_");
        $c->stash->{debug_msg} = "Welcome email failed: $_";
    };
}

sub add_mail_config_form :Local {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_mail_config_form', 
        "Displaying mail configuration form");
    
    $c->stash(template => 'mail/add_mail_config_form.tt');
}

sub add_mail_config :Local {
    my ($self, $c) = @_;
    
    my $params = $c->req->params;
    my $site_id = $params->{site_id};
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_mail_config', 
        "Processing mail configuration for site_id $site_id");
    
    # Validate required fields
    unless ($params->{smtp_host} && $params->{smtp_port}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_mail_config', 
            "Incomplete SMTP config for site_id $site_id");
        $c->stash->{debug_msg} = "Please provide SMTP host and port";
        $c->stash(template => 'mail/add_mail_config_form.tt');
        return;
    }
    
    try {
        my $schema = $c->model('DBEncy');
        my $site_config_rs = $schema->resultset('SiteConfig');
        
        # Create or update SMTP configuration
        for my $config_key (qw(smtp_host smtp_port smtp_username smtp_password smtp_from smtp_ssl)) {
            next unless defined $params->{$config_key};
            
            $site_config_rs->update_or_create({
                site_id => $site_id,
                config_key => $config_key,
                config_value => $params->{$config_key},
            });
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_mail_config', 
            "SMTP config saved for site_id $site_id");
        $c->stash->{status_msg} = "SMTP configuration saved successfully";
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_mail_config', 
            "Failed to save SMTP config: $_");
        $c->stash->{debug_msg} = "Failed to save configuration: $_";
    };
    
    $c->res->redirect($c->uri_for($self->action_for('add_mail_config_form')));
}

# New method to create a mail account using Virtualmin API
sub create_mail_account :Local {
    my ($self, $c) = @_;
    
    my $params = $c->req->params;
    my $email = $params->{email};
    my $password = $params->{password};
    my $domain = $params->{domain};
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_mail_account', 
        "Creating mail account for $email on domain $domain");
    
    # Validate required fields
    unless ($email && $password && $domain) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_mail_account', 
            "Missing required parameters for mail account creation");
        $c->stash->{debug_msg} = "Email, password, and domain are required";
        return;
    }
    
    # Validate email format
    unless ($email =~ /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_mail_account', 
            "Invalid email format: $email");
        $c->stash->{debug_msg} = "Invalid email format";
        return;
    }
    
    try {
        my $result = $c->model('Mail')->create_mail_account($c, $email, $password, $domain);
        
        if ($result) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_mail_account', 
                "Mail account created successfully for $email");
            $c->stash->{status_msg} = "Mail account created successfully";
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_mail_account', 
                "Failed to create mail account for $email");
            # debug_msg is already set in the model method
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_mail_account', 
            "Error creating mail account: $_");
        $c->stash->{debug_msg} = "Error creating mail account: $_";
    };
    
    # Redirect to appropriate page based on context
    if ($c->req->params->{redirect_url}) {
        $c->res->redirect($c->req->params->{redirect_url});
    } else {
        $c->res->redirect($c->uri_for('/mail'));
    }
}

__PACKAGE__->meta->make_immutable;
1;
