package Comserv::Controller::HostingSignup;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Try::Tiny;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# Set the namespace for this controller
__PACKAGE__->config(namespace => 'hosting_signup');

sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "HostingSignup controller auto method called");
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Request path: " . $c->req->uri->path);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Request method: " . $c->req->method);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Controller: " . __PACKAGE__);
    
    # Initialize debug_errors array if needed
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    
    return 1; # Allow the request to proceed
}

# Main signup form
sub index :Path :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Entered HostingSignup index method");
    push @{$c->stash->{debug_errors}}, "Entered HostingSignup index method";
    
    # Add debug message
    $c->stash->{debug_msg} = "Hosting Signup Form";
    
    # Set the template
    $c->stash(
        template => 'hosting/signup_form.tt',
        title => 'Starter Hosting Signup',
        form_action => $c->uri_for($self->action_for('process_signup')),
        debug_msg => "Hosting Signup Form",
    );
}

# Process the signup form submission
sub process_signup :Path('process') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process_signup', "Processing hosting signup form");
    push @{$c->stash->{debug_errors}}, "Processing hosting signup form";
    
    # Get form data
    my $params = $c->request->params;
    
    # Validate form data
    my @errors;
    
    # Required fields
    push @errors, "Full name is required" unless $params->{full_name};
    push @errors, "Email is required" unless $params->{email};
    push @errors, "Username is required" unless $params->{username};
    push @errors, "Password is required" unless $params->{password};
    push @errors, "Domain name is required" unless $params->{domain_name};
    push @errors, "Site name is required" unless $params->{site_name};
    
    # Email validation
    push @errors, "Invalid email format" if $params->{email} && $params->{email} !~ /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/;
    
    # Username validation (alphanumeric and underscore only)
    push @errors, "Username can only contain letters, numbers, and underscores" if $params->{username} && $params->{username} !~ /^[a-zA-Z0-9_]+$/;
    
    # Password validation (minimum 8 characters)
    push @errors, "Password must be at least 8 characters long" if $params->{password} && length($params->{password}) < 8;
    
    # Domain name validation (basic format check)
    push @errors, "Invalid domain name format" if $params->{domain_name} && $params->{domain_name} !~ /^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9]\.[a-zA-Z]{2,}$/;
    
    # If there are validation errors, redisplay the form with error messages
    if (@errors) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process_signup', "Validation errors: " . join(", ", @errors));
        push @{$c->stash->{debug_errors}}, "Validation errors: " . join(", ", @errors);
        
        $c->stash(
            template => 'hosting/signup_form.tt',
            title => 'Starter Hosting Signup',
            form_action => $c->uri_for($self->action_for('process_signup')),
            errors => \@errors,
            form_data => $params, # Return the submitted data to pre-fill the form
            debug_msg => "Validation errors in form submission",
        );
        return;
    }
    
    # Process the signup - create user and site
    try {
        # 1. Create the user
        my $user_data = {
            username => $params->{username},
            password => $params->{password},
            email => $params->{email},
            name => $params->{full_name},
            role => 'normal', # Default role for new users
            active => 1,      # Activate the user
        };
        
        my $user = $c->model('User')->create_user($user_data);
        
        # Check if user creation was successful
        if (!ref $user) {
            # If create_user returned an error message instead of a user object
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'process_signup', "User creation failed: $user");
            push @{$c->stash->{debug_errors}}, "User creation failed: $user";
            
            $c->stash(
                template => 'hosting/signup_form.tt',
                title => 'Starter Hosting Signup',
                form_action => $c->uri_for($self->action_for('process_signup')),
                errors => ["User creation failed: $user"],
                form_data => $params,
                debug_msg => "User creation failed",
            );
            return;
        }
        
        # 2. Create the site
        my $site_data = {
            name => $params->{site_name},
            description => $params->{site_description} || "Created via hosting signup",
            site_display_name => $params->{site_display_name} || $params->{site_name},
            theme => 'default', # Default theme
            auth_table => 'users',
            home_view => 'index.tt',
            css_view_name => 'default',
            mail_from => $params->{email},
            mail_to => $params->{email},
            mail_to_admin => $params->{email},
            mail_to_user => $params->{email},
            mail_replyto => $params->{email},
        };
        
        my $site = $c->model('Site')->add_site($c, $site_data);
        
        # 3. Add the domain to the site
        if ($site) {
            my $domain_data = {
                site_id => $site->id,
                domain => $params->{domain_name},
            };
            
            my $domain = $c->model('DBEncy::SiteDomain')->create($domain_data);
            
            # Log success
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process_signup', 
                "Signup successful - User: " . $user->username . ", Site: " . $site->name . ", Domain: " . $domain->domain);
            push @{$c->stash->{debug_errors}}, "Signup successful";
            
            # Redirect to success page
            $c->stash(
                template => 'hosting/signup_success.tt',
                title => 'Signup Successful',
                user => $user,
                site => $site,
                domain => $domain,
                debug_msg => "Signup successful",
            );
        } else {
            # Site creation failed
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'process_signup', "Site creation failed");
            push @{$c->stash->{debug_errors}}, "Site creation failed";
            
            $c->stash(
                template => 'hosting/signup_form.tt',
                title => 'Starter Hosting Signup',
                form_action => $c->uri_for($self->action_for('process_signup')),
                errors => ["Site creation failed. Please try again."],
                form_data => $params,
                debug_msg => "Site creation failed",
            );
        }
    } catch {
        # Handle any exceptions
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'process_signup', "Exception: $error");
        push @{$c->stash->{debug_errors}}, "Exception: $error";
        
        $c->stash(
            template => 'hosting/signup_form.tt',
            title => 'Starter Hosting Signup',
            form_action => $c->uri_for($self->action_for('process_signup')),
            errors => ["An error occurred during signup: $error"],
            form_data => $params,
            debug_msg => "Exception during signup process",
        );
    };
}

# Success page after signup
sub success :Path('success') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'success', "Entered success method");
    push @{$c->stash->{debug_errors}}, "Entered success method";
    
    # This page should normally be reached via a redirect from process_signup
    # If accessed directly, redirect to the signup form
    unless ($c->stash->{user} && $c->stash->{site} && $c->stash->{domain}) {
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    # Add debug message
    $c->stash->{debug_msg} = "Hosting Signup Successful";
    
    # Template is already set in process_signup
}

__PACKAGE__->meta->make_immutable;

1;