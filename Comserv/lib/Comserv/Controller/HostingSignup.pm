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
    # Make sure it's an array reference, not just defined
    $c->stash->{debug_errors} = [] unless (defined $c->stash->{debug_errors} && ref $c->stash->{debug_errors} eq 'ARRAY');
    
    # Initialize debug_msg array if needed
    # Make sure it's an array reference, not just defined
    $c->stash->{debug_msg} = [] unless (defined $c->stash->{debug_msg} && ref $c->stash->{debug_msg} eq 'ARRAY');
    
    return 1; # Allow the request to proceed
}

# Main signup form
sub index :Path :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Entered HostingSignup index method");
    
    # Ensure debug_errors is an array reference
    $c->stash->{debug_errors} = [] unless ref $c->stash->{debug_errors} eq 'ARRAY';
    push @{$c->stash->{debug_errors}}, "Entered HostingSignup index method";
    
    # Ensure debug_msg is an array reference
    $c->stash->{debug_msg} = [] unless ref $c->stash->{debug_msg} eq 'ARRAY';
    push @{$c->stash->{debug_msg}}, "Hosting Signup Form";
    
    # Set the template
    $c->stash(
        template => 'hosting/signup_form.tt',
        title => 'Starter Hosting Signup',
        form_action => $c->uri_for($self->action_for('process_signup')),
    );
}

# Process the signup form submission
sub process_signup :Path('process') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process_signup', "Processing hosting signup form");
    push @{$c->stash->{debug_errors}}, "Processing hosting signup form";
    
    # Get form data
    my $params = $c->request->params;
    
    # Log form data
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process_signup', "Form data: first_name=" . ($params->{first_name} || 'N/A') . 
        ", last_name=" . ($params->{last_name} || 'N/A') . 
        ", email=" . ($params->{email} || 'N/A') . 
        ", username=" . ($params->{username} || 'N/A') . 
        ", domain_name=" . ($params->{domain_name} || 'N/A') . 
        ", site_name=" . ($params->{site_name} || 'N/A') . 
        ", password_provided=" . ($params->{password} ? 'Yes' : 'No') . 
        ", confirm_password_provided=" . ($params->{confirm_password} ? 'Yes' : 'No') . 
        ", passwords_match=" . (($params->{password} && $params->{confirm_password} && $params->{password} eq $params->{confirm_password}) ? 'Yes' : 'No'));
    
    # Validate form data
    my @errors;
    
    # Required fields
    push @errors, "First name is required" unless $params->{first_name};
    push @errors, "Last name is required" unless $params->{last_name};
    push @errors, "Last name is required" unless $params->{last_name};
    push @errors, "Email is required" unless $params->{email};
    push @errors, "Username is required" unless $params->{username};
    push @errors, "Password is required" unless $params->{password};
    push @errors, "Password confirmation is required" unless $params->{confirm_password};
    push @errors, "Domain name is required" unless $params->{domain_name};
    push @errors, "Site name is required" unless $params->{site_name};
    
    # Email validation
    push @errors, "Invalid email format" if $params->{email} && $params->{email} !~ /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/;
    
    # Username validation (alphanumeric and underscore only)
    push @errors, "Username can only contain letters, numbers, and underscores" if $params->{username} && $params->{username} !~ /^[a-zA-Z0-9_]+$/;
    
    # Password validation (minimum 8 characters)
    push @errors, "Password must be at least 8 characters long" if $params->{password} && length($params->{password}) < 8;
    
    # Password confirmation validation
    push @errors, "Passwords do not match" if $params->{password} && $params->{confirm_password} && $params->{password} ne $params->{confirm_password};
    
    # Domain name validation (basic format check)
    push @errors, "Invalid domain name format" if $params->{domain_name} && $params->{domain_name} !~ /^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9]\.[a-zA-Z]{2,}$/;
    
    # If there are validation errors, redisplay the form with error messages
    if (@errors) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process_signup', "Validation errors: " . join(", ", @errors));
        
        # Ensure debug_errors is an array reference
        $c->stash->{debug_errors} = [] unless ref $c->stash->{debug_errors} eq 'ARRAY';
        push @{$c->stash->{debug_errors}}, "Validation errors: " . join(", ", @errors);
        
        # Ensure debug_msg is an array reference
        $c->stash->{debug_msg} = [] unless ref $c->stash->{debug_msg} eq 'ARRAY';
        push @{$c->stash->{debug_msg}}, "Validation errors in form submission";
        
        $c->stash(
            template => 'hosting/signup_form.tt',
            title => 'Starter Hosting Signup',
            form_action => $c->uri_for($self->action_for('process_signup')),
            errors => \@errors,
            form_data => $params, # Return the submitted data to pre-fill the form
            # debug_msg is already an array initialized in auto
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
            first_name => $params->{first_name},
            last_name => $params->{last_name},
            roles => 'normal', # Default role for new users
        };
        
        my $user = $c->model('User')->create_user($user_data);
        
        # Check if user creation was successful
        if (!ref $user) {
            # If create_user returned an error message instead of a user object
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'process_signup', "User creation failed: $user");
            
            # Ensure debug_errors is an array reference
            $c->stash->{debug_errors} = [] unless ref $c->stash->{debug_errors} eq 'ARRAY';
            push @{$c->stash->{debug_errors}}, "User creation failed: $user";
            
            # Ensure debug_msg is an array reference
            $c->stash->{debug_msg} = [] unless ref $c->stash->{debug_msg} eq 'ARRAY';
            push @{$c->stash->{debug_msg}}, "User creation failed";
            
            $c->stash(
                template => 'hosting/signup_form.tt',
                title => 'Starter Hosting Signup',
                form_action => $c->uri_for($self->action_for('process_signup')),
                errors => ["User creation failed: $user"],
                form_data => $params,
                # debug_msg is already an array initialized in auto
            );
            return;
        }
        
        # 2. Create the site
        my $site_data = {
            name => $params->{site_name},
            description => $params->{site_description} || "Created via hosting signup",
            site_display_name => $params->{site_display_name} || $params->{site_name},
            # theme is stored in a JSON file, not in the database
            auth_table => 'users',
            home_view => 'index.tt',
            css_view_name => 'default',
            mail_from => $params->{email},
            mail_to => $params->{email},
            mail_to_admin => $params->{email},
            mail_to_user => $params->{email},
            mail_replyto => $params->{email},
            # Required fields with default values
            affiliate => $params->{affiliate} || 1, # Default affiliate ID
            pid => $params->{pid} || 0, # Default parent ID
            # Default values for other required fields
            app_logo => $params->{app_logo} || '/static/images/default_logo.png',
            app_logo_alt => $params->{app_logo_alt} || $params->{site_name} . ' Logo',
            app_logo_width => $params->{app_logo_width} || 200,
            app_logo_height => $params->{app_logo_height} || 100,
            document_root_url => $params->{document_root_url} || '/',
            link_target => $params->{link_target} || '_self',
            http_header_params => $params->{http_header_params} || '',
            image_root_url => $params->{image_root_url} || '/static/images/',
            global_datafiles_directory => $params->{global_datafiles_directory} || '/data/',
            templates_cache_directory => $params->{templates_cache_directory} || '/tmp/',
            app_datafiles_directory => $params->{app_datafiles_directory} || '/data/app/',
            datasource_type => $params->{datasource_type} || 'db',
            cal_table => $params->{cal_table} || 'calendar',
            http_header_description => $params->{http_header_description} || 'Created via hosting signup',
            http_header_keywords => $params->{http_header_keywords} || 'website, hosting',
            mail_to_discussion => $params->{mail_to_discussion} || $params->{email},
            mail_to_client => $params->{mail_to_client} || $params->{email},
        };
        
        my $site = $c->model('Site')->add_site($c, $site_data);
        
        # Set the theme for the site after creation
        if ($site) {
            $c->model('ThemeConfig')->set_site_theme($c, $site->name, 'default');
        }
        
        # 3. Add the domain to the site
        if ($site) {
            my $domain_data = {
                site_id => $site->id,
                domain => $params->{domain_name},
            };
            
            my $domain = $c->model('DBEncy::SiteDomain')->create($domain_data);
            
            # 4. Create a new controller for the site
            my $site_name = $site->name;
            
            # Validate site_name before proceeding
            unless (defined $site_name && $site_name =~ /^[a-zA-Z0-9_]+$/) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'process_signup', "Invalid site name for controller/template creation: " . (defined $site_name ? $site_name : 'undefined'));
                
                # Double-check that debug_errors is an array reference before pushing
                if (defined $c->stash->{debug_errors} && ref $c->stash->{debug_errors} eq 'ARRAY') {
                    push @{$c->stash->{debug_errors}}, "Invalid site name for controller/template creation";
                } else {
                    # If it's still not an array reference, reinitialize it
                    $c->stash->{debug_errors} = ["Invalid site name for controller/template creation"];
                }
                
                next; # Skip to the next step in the try block
            }
            
            # Create controller with error handling
            my $controller_result = $self->create_site_controller($c, $site_name);
            unless ($controller_result) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'process_signup', "Failed to create controller for site: $site_name");
                
                # Double-check that debug_errors is an array reference before pushing
                if (defined $c->stash->{debug_errors} && ref $c->stash->{debug_errors} eq 'ARRAY') {
                    push @{$c->stash->{debug_errors}}, "Failed to create controller for site: $site_name";
                } else {
                    # If it's still not an array reference, reinitialize it
                    $c->stash->{debug_errors} = ["Failed to create controller for site: $site_name"];
                }
                
                # Continue with template creation even if controller creation failed
            }
            
            # 5. Create the index.tt template for the site with error handling
            my $template_result = $self->create_site_template($c, $site_name);
            unless ($template_result) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'process_signup', "Failed to create template for site: $site_name");
                
                # Double-check that debug_errors is an array reference before pushing
                if (defined $c->stash->{debug_errors} && ref $c->stash->{debug_errors} eq 'ARRAY') {
                    push @{$c->stash->{debug_errors}}, "Failed to create template for site: $site_name";
                } else {
                    # If it's still not an array reference, reinitialize it
                    $c->stash->{debug_errors} = ["Failed to create template for site: $site_name"];
                }
                
                # Continue with the signup process even if template creation failed
            }
            
            # Log success
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process_signup', 
                "Signup successful - User: " . $user->username . ", Site: " . $site->name . ", Domain: " . $domain->domain);
                
            # Send confirmation email to the user
            $self->send_confirmation_email($c, {
                username => $user->username,
                email => $user->email,
                first_name => $user->first_name,
                last_name => $user->last_name,
                site_name => $site->name,
                domain_name => $domain->domain
            });
            
            # Ensure debug_errors is an array reference - more robust check
            if (!defined $c->stash->{debug_errors} || ref $c->stash->{debug_errors} ne 'ARRAY') {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process_signup', "Initializing debug_errors as empty array");
                $c->stash->{debug_errors} = [];
            }
            push @{$c->stash->{debug_errors}}, "Signup successful";
            
            # Ensure debug_msg is an array reference - more robust check
            if (!defined $c->stash->{debug_msg} || ref $c->stash->{debug_msg} ne 'ARRAY') {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process_signup', "Initializing debug_msg as empty array");
                $c->stash->{debug_msg} = [];
            }
            push @{$c->stash->{debug_msg}}, "Signup successful";
            
            # Redirect to success page
            $c->stash(
                template => 'hosting/signup_success.tt',
                title => 'Signup Successful',
                user => $user,
                site => $site,
                domain => $domain,
                # debug_msg is already an array initialized in auto
            );
        } else {
            # Site creation failed
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'process_signup', "Site creation failed");
            
            # Ensure debug_errors is an array reference - more robust check
            if (!defined $c->stash->{debug_errors} || ref $c->stash->{debug_errors} ne 'ARRAY') {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process_signup', "Initializing debug_errors as empty array");
                $c->stash->{debug_errors} = [];
            }
            push @{$c->stash->{debug_errors}}, "Site creation failed";
            
            # Ensure debug_msg is an array reference - more robust check
            if (!defined $c->stash->{debug_msg} || ref $c->stash->{debug_msg} ne 'ARRAY') {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process_signup', "Initializing debug_msg as empty array");
                $c->stash->{debug_msg} = [];
            }
            push @{$c->stash->{debug_msg}}, "Site creation failed";
            
            $c->stash(
                template => 'hosting/signup_form.tt',
                title => 'Starter Hosting Signup',
                form_action => $c->uri_for($self->action_for('process_signup')),
                errors => ["Site creation failed. Please try again."],
                form_data => $params,
                # debug_msg is already an array initialized in auto
            );
        }
    } catch {
        # Handle any exceptions
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'process_signup', "Exception: $error");
        
        # Ensure debug_errors is an array reference - more robust check
        if (!defined $c->stash->{debug_errors} || ref $c->stash->{debug_errors} ne 'ARRAY') {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process_signup', "Initializing debug_errors as empty array in exception handler");
            $c->stash->{debug_errors} = [];
        }
        push @{$c->stash->{debug_errors}}, "Exception: $error";
        
        # Ensure debug_msg is an array reference - more robust check
        if (!defined $c->stash->{debug_msg} || ref $c->stash->{debug_msg} ne 'ARRAY') {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process_signup', "Initializing debug_msg as empty array in exception handler");
            $c->stash->{debug_msg} = [];
        }
        push @{$c->stash->{debug_msg}}, "Exception during signup process";
        
        $c->stash(
            template => 'hosting/signup_form.tt',
            title => 'Starter Hosting Signup',
            form_action => $c->uri_for($self->action_for('process_signup')),
            errors => ["An error occurred during signup: $error"],
            form_data => $params,
            # debug_msg is already an array initialized in auto
        );
    };
}

# Success page after signup
sub success :Path('success') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'success', "Entered success method");
    
    # Ensure debug_errors is an array reference - more robust check
    if (!defined $c->stash->{debug_errors} || ref $c->stash->{debug_errors} ne 'ARRAY') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'success', "Initializing debug_errors as empty array");
        $c->stash->{debug_errors} = [];
    }
    push @{$c->stash->{debug_errors}}, "Entered success method";
    
    # This page should normally be reached via a redirect from process_signup
    # If accessed directly, redirect to the signup form
    unless ($c->stash->{user} && $c->stash->{site} && $c->stash->{domain}) {
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    # Add debug message
    # Ensure debug_msg is an array reference - more robust check
    if (!defined $c->stash->{debug_msg} || ref $c->stash->{debug_msg} ne 'ARRAY') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'success', "Initializing debug_msg as empty array");
        $c->stash->{debug_msg} = [];
    }
    push @{$c->stash->{debug_msg}}, "Hosting Signup Successful";
    
    # Template is already set in process_signup
}

# Helper method to create a new controller for the site
sub create_site_controller {
    my ($self, $c, $site_name) = @_;
    
    # Ensure debug_errors is an array reference - more robust check
    if (!defined $c->stash->{debug_errors} || ref $c->stash->{debug_errors} ne 'ARRAY') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_site_controller', "Initializing debug_errors as empty array");
        $c->stash->{debug_errors} = [];
    }
    
    # Ensure debug_msg is an array reference - more robust check
    if (!defined $c->stash->{debug_msg} || ref $c->stash->{debug_msg} ne 'ARRAY') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_site_controller', "Initializing debug_msg as empty array");
        $c->stash->{debug_msg} = [];
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_site_controller', "Creating controller for site: $site_name");
    
    # Validate site_name
    unless (defined $site_name && $site_name =~ /^[a-zA-Z0-9_]+$/) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_site_controller', "Invalid site name: " . (defined $site_name ? $site_name : 'undefined'));
        
        # Double-check that debug_errors is an array reference before pushing
        if (defined $c->stash->{debug_errors} && ref $c->stash->{debug_errors} eq 'ARRAY') {
            push @{$c->stash->{debug_errors}}, "Invalid site name for controller creation";
        } else {
            # If it's still not an array reference, reinitialize it
            $c->stash->{debug_errors} = ["Invalid site name for controller creation"];
        }
        
        return 0;
    }
    
    # Create the controller file path - use absolute path
    my $controller_path = "/home/shanta/PycharmProjects/comserv/Comserv/lib/Comserv/Controller/$site_name.pm";
    
    # Log the controller path for debugging
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_site_controller', "Controller path: $controller_path");
    
    # Check if the controller already exists
    if (-e $controller_path) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_site_controller', "Controller already exists for site: $site_name");
        return 1;
    }
    
    # Double-check site_name again before using it in the here-doc
    unless (defined $site_name && $site_name =~ /^[a-zA-Z0-9_]+$/) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_site_controller', "Invalid site name for here-doc: " . (defined $site_name ? $site_name : 'undefined'));
        
        # Double-check that debug_errors is an array reference before pushing
        if (defined $c->stash->{debug_errors} && ref $c->stash->{debug_errors} eq 'ARRAY') {
            push @{$c->stash->{debug_errors}}, "Invalid site name for controller creation";
        } else {
            # If it's still not an array reference, reinitialize it
            $c->stash->{debug_errors} = ["Invalid site name for controller creation"];
        }
        
        return 0;
    }
    
    # Create the controller content - using a safer approach with string concatenation
    my $controller_content = "package Comserv::Controller::$site_name;\n";
    $controller_content .= "use Moose;\n";
    $controller_content .= "use namespace::autoclean;\n";
    $controller_content .= "use Comserv::Util::Logging;\n\n";
    $controller_content .= "BEGIN { extends 'Catalyst::Controller'; }\n\n";
    $controller_content .= "has 'logging' => (\n";
    $controller_content .= "    is => 'ro',\n";
    $controller_content .= "    default => sub { Comserv::Util::Logging->instance }\n";
    $controller_content .= ");\n\n";
    $controller_content .= "# Set the namespace for this controller\n";
    $controller_content .= "__PACKAGE__->config(namespace => lc('$site_name'));\n\n";
    $controller_content .= "sub auto :Private {\n";
    $controller_content .= "    my (\$self, \$c) = \@_;\n";
    $controller_content .= "    \$self->logging->log_with_details(\$c, 'info', __FILE__, __LINE__, 'auto', \"$site_name controller auto method called\");\n";
    $controller_content .= "    \$self->logging->log_with_details(\$c, 'info', __FILE__, __LINE__, 'auto', \"Request path: \" . \$c->req->uri->path);\n";
    $controller_content .= "    \$self->logging->log_with_details(\$c, 'info', __FILE__, __LINE__, 'auto', \"Request method: \" . \$c->req->method);\n";
    $controller_content .= "    \$self->logging->log_with_details(\$c, 'info', __FILE__, __LINE__, 'auto', \"Controller: \" . __PACKAGE__);\n\n";
    $controller_content .= "    # Initialize debug_errors array if needed\n";
    $controller_content .= "    \$c->stash->{debug_errors} = [] unless (defined \$c->stash->{debug_errors} && ref \$c->stash->{debug_errors} eq 'ARRAY');\n\n";
    $controller_content .= "    # Initialize debug_msg array if needed\n";
    $controller_content .= "    \$c->stash->{debug_msg} = [] unless (defined \$c->stash->{debug_msg} && ref \$c->stash->{debug_msg} eq 'ARRAY');\n\n";
    $controller_content .= "    return 1; # Allow the request to proceed\n";
    $controller_content .= "}\n\n";
    $controller_content .= "# Main index page\n";
    $controller_content .= "sub index :Path :Args(0) {\n";
    $controller_content .= "    my (\$self, \$c) = \@_;\n\n";
    $controller_content .= "    \$self->logging->log_with_details(\$c, 'info', __FILE__, __LINE__, 'index', \"Entered $site_name index method\");\n\n";
    $controller_content .= "    # Ensure debug_errors is an array reference\n";
    $controller_content .= "    \$c->stash->{debug_errors} = [] unless ref \$c->stash->{debug_errors} eq 'ARRAY';\n";
    $controller_content .= "    push \@{\$c->stash->{debug_errors}}, \"Entered $site_name index method\";\n\n";
    $controller_content .= "    # Add debug message\n";
    $controller_content .= "    # Ensure debug_msg is an array reference\n";
    $controller_content .= "    \$c->stash->{debug_msg} = [] unless ref \$c->stash->{debug_msg} eq 'ARRAY';\n";
    $controller_content .= "    push \@{\$c->stash->{debug_msg}}, \"$site_name Home Page\";\n\n";
    $controller_content .= "    # Set the template\n";
    $controller_content .= "    \$c->stash(\n";
    $controller_content .= "        template => '$site_name/index.tt',\n";
    $controller_content .= "        title => '$site_name',\n";
    $controller_content .= "        # debug_msg is already set as an array above\n";
    $controller_content .= "    );\n";
    $controller_content .= "}\n\n";
    $controller_content .= "__PACKAGE__->meta->make_immutable;\n\n";
    $controller_content .= "1;\n";
    
    # Log the controller content for debugging
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_site_controller', "Controller content length: " . length($controller_content));
    
    # Write the controller file with improved error handling
    eval {
        # Check if we can write to the directory
        my $dir = $c->path_to('lib', 'Comserv', 'Controller');
        unless (-d $dir && -w $dir) {
            die "Controller directory does not exist or is not writable: $dir";
        }
        
        # Open the file for writing
        open my $fh, '>', $controller_path or die "Failed to open file for writing: $!";
        
        # Write the content
        print $fh $controller_content or die "Failed to write to file: $!";
        
        # Close the file
        close $fh or die "Failed to close file: $!";
    };
    
    if ($@) {
        my $error = $@;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_site_controller', "Failed to create controller file: $error");
        
        # Double-check that debug_errors is an array reference before pushing
        if (defined $c->stash->{debug_errors} && ref $c->stash->{debug_errors} eq 'ARRAY') {
            push @{$c->stash->{debug_errors}}, "Failed to create controller file: $error";
        } else {
            # If it's still not an array reference, reinitialize it
            $c->stash->{debug_errors} = ["Failed to create controller file: $error"];
        }
        
        return 0;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_site_controller', "Controller created for site: $site_name");
    
    # Add the controller to Comserv.pm to ensure it's loaded
    $self->add_controller_to_comserv($c, $site_name);
    
    return 1;
}

# Helper method to create the index.tt template for the site
sub create_site_template {
    my ($self, $c, $site_name) = @_;
    
    # Ensure debug_errors is an array reference - more robust check
    if (!defined $c->stash->{debug_errors} || ref $c->stash->{debug_errors} ne 'ARRAY') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_site_template', "Initializing debug_errors as empty array");
        $c->stash->{debug_errors} = [];
    }
    
    # Ensure debug_msg is an array reference - more robust check
    if (!defined $c->stash->{debug_msg} || ref $c->stash->{debug_msg} ne 'ARRAY') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_site_template', "Initializing debug_msg as empty array");
        $c->stash->{debug_msg} = [];
    }
    
    # Validate site_name
    unless (defined $site_name && $site_name =~ /^[a-zA-Z0-9_]+$/) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_site_template', "Invalid site name: " . (defined $site_name ? $site_name : 'undefined'));
        
        # Double-check that debug_errors is an array reference before pushing
        if (defined $c->stash->{debug_errors} && ref $c->stash->{debug_errors} eq 'ARRAY') {
            push @{$c->stash->{debug_errors}}, "Invalid site name for template creation";
        } else {
            # If it's still not an array reference, reinitialize it
            $c->stash->{debug_errors} = ["Invalid site name for template creation"];
        }
        
        return 0;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_site_template', "Creating template for site: $site_name");
    
    # Create the template directory - use absolute path
    my $template_dir = "/home/shanta/PycharmProjects/comserv/Comserv/root/$site_name";
    
    # Log the template directory path for debugging
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_site_template', "Template directory path: $template_dir");
    
    # Create the directory if it doesn't exist
    unless (-d $template_dir) {
        # Use system mkdir to ensure proper permissions
        my $result = system("mkdir -p $template_dir");
        if ($result != 0) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_site_template', "Failed to create template directory: $!");
            return 0;
        }
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_site_template', "Created template directory: $template_dir");
    }
    
    # Create the template file path
    my $template_path = "$template_dir/index.tt";
    
    # Check if the template already exists
    if (-e $template_path) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_site_template', "Template already exists for site: $site_name");
        return;
    }
    
    # Double-check site_name again before using it in the template content
    unless (defined $site_name && $site_name =~ /^[a-zA-Z0-9_]+$/) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_site_template', "Invalid site name for template content: " . (defined $site_name ? $site_name : 'undefined'));
        
        # Double-check that debug_errors is an array reference before pushing
        if (defined $c->stash->{debug_errors} && ref $c->stash->{debug_errors} eq 'ARRAY') {
            push @{$c->stash->{debug_errors}}, "Invalid site name for template creation";
        } else {
            # If it's still not an array reference, reinitialize it
            $c->stash->{debug_errors} = ["Invalid site name for template creation"];
        }
        
        return 0;
    }
    
    # Create the template content using string concatenation
    my $template_content = "[% META title = '$site_name' %]\n";
    $template_content .= "[% PageVersion = '$site_name/index.tt,v 0.01 2025/04/12 shanta Exp shanta ' %]\n\n";
    $template_content .= "[% IF c.session.debug_mode == 1 %]\n";
    $template_content .= "    [% PageVersion %]\n";
    $template_content .= "    [% # Use the standard debug message system %]\n";
    $template_content .= "    [% IF debug_msg.defined && debug_msg.size > 0 %]\n";
    $template_content .= "        <div class=\"debug-messages\">\n";
    $template_content .= "            [% FOREACH msg IN debug_msg %]\n";
    $template_content .= "                <p class=\"debug\">Debug: [% msg %]</p>\n";
    $template_content .= "            [% END %]\n";
    $template_content .= "        </div>\n";
    $template_content .= "    [% END %]\n";
    $template_content .= "[% END %]\n\n";
    $template_content .= "<div class=\"container mt-4\">\n";
    $template_content .= "    <div class=\"row\">\n";
    $template_content .= "        <div class=\"col-md-12\">\n";
    $template_content .= "            <div class=\"card\">\n";
    $template_content .= "                <div class=\"card-header bg-primary text-white\">\n";
    $template_content .= "                    <h2 class=\"card-title\">Welcome to $site_name</h2>\n";
    $template_content .= "                </div>\n";
    $template_content .= "                <div class=\"card-body\">\n";
    $template_content .= "                    <p class=\"lead\">This is the home page for $site_name.</p>\n\n";
    $template_content .= "                    <div class=\"alert alert-info\">\n";
    $template_content .= "                        <h4 class=\"alert-heading\">Getting Started</h4>\n";
    $template_content .= "                        <p>This is your new website. You can customize this page and add more content as needed.</p>\n";
    $template_content .= "                    </div>\n\n";
    $template_content .= "                    <h3>Features</h3>\n";
    $template_content .= "                    <ul class=\"list-group mb-4\">\n";
    $template_content .= "                        <li class=\"list-group-item\">Custom domain name</li>\n";
    $template_content .= "                        <li class=\"list-group-item\">Website hosting</li>\n";
    $template_content .= "                        <li class=\"list-group-item\">Email accounts</li>\n";
    $template_content .= "                        <li class=\"list-group-item\">Database support</li>\n";
    $template_content .= "                        <li class=\"list-group-item\">Technical support</li>\n";
    $template_content .= "                    </ul>\n\n";
    $template_content .= "                    <h3>Next Steps</h3>\n";
    $template_content .= "                    <p>Here are some things you might want to do next:</p>\n";
    $template_content .= "                    <ol>\n";
    $template_content .= "                        <li>Customize this page with your own content</li>\n";
    $template_content .= "                        <li>Add more pages to your website</li>\n";
    $template_content .= "                        <li>Set up your email accounts</li>\n";
    $template_content .= "                        <li>Configure your database</li>\n";
    $template_content .= "                        <li>Add users to your website</li>\n";
    $template_content .= "                    </ol>\n";
    $template_content .= "                </div>\n";
    $template_content .= "                <div class=\"card-footer\">\n";
    $template_content .= "                    <p class=\"text-muted\">For support, please contact support\@computersystemconsulting.ca</p>\n";
    $template_content .= "                </div>\n";
    $template_content .= "            </div>\n";
    $template_content .= "        </div>\n";
    $template_content .= "    </div>\n";
    $template_content .= "</div>\n";
    
    # Log the template content for debugging
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_site_template', "Template content length: " . length($template_content));
    
    # Write the template file with improved error handling
    eval {
        # Check if we can write to the directory
        unless (-d $template_dir && -w $template_dir) {
            die "Template directory does not exist or is not writable: $template_dir";
        }
        
        # Open the file for writing
        open my $fh, '>', $template_path or die "Failed to open template file for writing: $!";
        
        # Write the content
        print $fh $template_content or die "Failed to write to template file: $!";
        
        # Close the file
        close $fh or die "Failed to close template file: $!";
    };
    
    if ($@) {
        my $error = $@;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_site_template', "Failed to create template file: $error");
        
        # Double-check that debug_errors is an array reference before pushing
        if (defined $c->stash->{debug_errors} && ref $c->stash->{debug_errors} eq 'ARRAY') {
            push @{$c->stash->{debug_errors}}, "Failed to create template file: $error";
        } else {
            # If it's still not an array reference, reinitialize it
            $c->stash->{debug_errors} = ["Failed to create template file: $error"];
        }
        
        return 0;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_site_template', "Template created for site: $site_name");
    
    return 1;
}

# Helper method to add the controller to Comserv.pm
sub add_controller_to_comserv {
    my ($self, $c, $site_name) = @_;
    
    # Ensure debug_errors is an array reference - more robust check
    if (!defined $c->stash->{debug_errors} || ref $c->stash->{debug_errors} ne 'ARRAY') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_controller_to_comserv', "Initializing debug_errors as empty array");
        $c->stash->{debug_errors} = [];
    }
    
    # Ensure debug_msg is an array reference - more robust check
    if (!defined $c->stash->{debug_msg} || ref $c->stash->{debug_msg} ne 'ARRAY') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_controller_to_comserv', "Initializing debug_msg as empty array");
        $c->stash->{debug_msg} = [];
    }
    
    # Validate site_name
    unless (defined $site_name && $site_name =~ /^[a-zA-Z0-9_]+$/) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_controller_to_comserv', "Invalid site name: " . (defined $site_name ? $site_name : 'undefined'));
        
        # Double-check that debug_errors is an array reference before pushing
        if (defined $c->stash->{debug_errors} && ref $c->stash->{debug_errors} eq 'ARRAY') {
            push @{$c->stash->{debug_errors}}, "Invalid site name for adding controller to Comserv.pm";
        } else {
            # If it's still not an array reference, reinitialize it
            $c->stash->{debug_errors} = ["Invalid site name for adding controller to Comserv.pm"];
        }
        
        return 0;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_controller_to_comserv', "Adding controller to Comserv.pm: $site_name");
    
    # Path to Comserv.pm - use absolute path
    my $comserv_path = "/home/shanta/PycharmProjects/comserv/Comserv/lib/Comserv.pm";
    
    # Log the Comserv.pm path for debugging
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'add_controller_to_comserv', "Comserv.pm path: $comserv_path");
    
    # Read the current content with improved error handling
    my @lines;
    eval {
        open my $fh, '<', $comserv_path or die "Failed to open Comserv.pm: $!";
        @lines = <$fh>;
        close $fh or die "Failed to close Comserv.pm: $!";
    };
    
    if ($@) {
        my $error = $@;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_controller_to_comserv', "Failed to read Comserv.pm: $error");
        
        # Double-check that debug_errors is an array reference before pushing
        if (defined $c->stash->{debug_errors} && ref $c->stash->{debug_errors} eq 'ARRAY') {
            push @{$c->stash->{debug_errors}}, "Failed to read Comserv.pm: $error";
        } else {
            # If it's still not an array reference, reinitialize it
            $c->stash->{debug_errors} = ["Failed to read Comserv.pm: $error"];
        }
        
        return 0;
    }
    
    # Check if the controller is already loaded
    my $controller_line = "use Comserv::Controller::$site_name;";
    if (grep { $_ =~ /\Q$controller_line\E/ } @lines) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_controller_to_comserv', "Controller already loaded in Comserv.pm: $site_name");
        return;
    }
    
    # Find the line where controllers are loaded
    my $insert_index = -1;
    for (my $i = 0; $i < @lines; $i++) {
        if ($lines[$i] =~ /# Explicitly load controllers to ensure they're available/) {
            $insert_index = $i + 1;
            last;
        }
    }
    
    if ($insert_index == -1) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_controller_to_comserv', "Could not find where to insert controller in Comserv.pm");
        return;
    }
    
    # Insert the new controller line
    splice @lines, $insert_index, 0, "                use Comserv::Controller::$site_name;\n";
    
    # Write the updated content with improved error handling
    eval {
        open my $fh, '>', $comserv_path or die "Failed to open Comserv.pm for writing: $!";
        print $fh @lines;
        close $fh or die "Failed to close Comserv.pm after writing: $!";
    };
    
    if ($@) {
        my $error = $@;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_controller_to_comserv', "Failed to write to Comserv.pm: $error");
        
        # Double-check that debug_errors is an array reference before pushing
        if (defined $c->stash->{debug_errors} && ref $c->stash->{debug_errors} eq 'ARRAY') {
            push @{$c->stash->{debug_errors}}, "Failed to write to Comserv.pm: $error";
        } else {
            # If it's still not an array reference, reinitialize it
            $c->stash->{debug_errors} = ["Failed to write to Comserv.pm: $error"];
        }
        
        return 0;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_controller_to_comserv', "Controller added to Comserv.pm: $site_name");
    
    return 1;
}

# Helper method to send confirmation email
sub send_confirmation_email {
    my ($self, $c, $user_data) = @_;
    
    # Ensure debug_errors is an array reference - more robust check
    if (!defined $c->stash->{debug_errors} || ref $c->stash->{debug_errors} ne 'ARRAY') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_confirmation_email', "Initializing debug_errors as empty array");
        $c->stash->{debug_errors} = [];
    }
    
    # Ensure debug_msg is an array reference - more robust check
    if (!defined $c->stash->{debug_msg} || ref $c->stash->{debug_msg} ne 'ARRAY') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_confirmation_email', "Initializing debug_msg as empty array");
        $c->stash->{debug_msg} = [];
    }
    
    # Log the email sending attempt
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_confirmation_email', 
        "Sending confirmation email to " . $user_data->{email});
    
    # Prepare email content
    my $subject = "Welcome to " . $user_data->{site_name} . " - Your Hosting Account is Ready";
    
    my $body = "Dear " . $user_data->{first_name} . " " . $user_data->{last_name} . ",\n\n";
    $body .= "Thank you for signing up for hosting with us. Your account has been created successfully.\n\n";
    $body .= "Here are your account details:\n";
    $body .= "Username: " . $user_data->{username} . "\n";
    $body .= "Site Name: " . $user_data->{site_name} . "\n";
    $body .= "Domain Name: " . $user_data->{domain_name} . "\n\n";
    $body .= "You can access your site at: http://" . $user_data->{domain_name} . "\n\n";
    $body .= "If you have any questions or need assistance, please contact our support team.\n\n";
    $body .= "Best regards,\n";
    $body .= "The Hosting Team";
    
    # Try to send the email
    eval {
        $c->stash->{email} = {
            to => $user_data->{email},
            cc => 'support@computersystemconsulting.ca',
            from => 'noreply@computersystemconsulting.ca',
            subject => $subject,
            body => $body,
        };
        
        # Use Catalyst's email view to send the email
        $c->forward($c->view('Email::Template'));
        
        # Log success
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_confirmation_email', 
            "Confirmation email sent successfully to " . $user_data->{email});
        
        # Add success message to debug_msg
        push @{$c->stash->{debug_msg}}, "Confirmation email sent to " . $user_data->{email};
    };
    
    # Handle any errors
    if ($@) {
        my $error = $@;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'send_confirmation_email', 
            "Failed to send confirmation email: $error");
        
        # Double-check that debug_errors is an array reference before pushing
        if (defined $c->stash->{debug_errors} && ref $c->stash->{debug_errors} eq 'ARRAY') {
            push @{$c->stash->{debug_errors}}, "Failed to send confirmation email: $error";
        } else {
            # If it's still not an array reference, reinitialize it
            $c->stash->{debug_errors} = ["Failed to send confirmation email: $error"];
        }
        
        return 0;
    }
    
    return 1;
}

__PACKAGE__->meta->make_immutable;

1;