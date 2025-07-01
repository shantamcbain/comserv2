package Comserv::Controller::User;
use Moose;
use namespace::autoclean;
use Digest::SHA qw(sha256_hex);  # For hashing passwords
use Data::Dumper;
use Email::Sender::Simple qw(sendmail);
use Email::Simple;
use Email::Simple::Creator;
use Email::Sender::Transport::SMTP;
use JSON;

BEGIN { extends 'Catalyst::Controller'; }
# Apply restrictions to the entire controller
has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub login :Local {
    my ($self, $c) = @_;

    # Log login page access
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'login', 'Accessing login page');

    # Store the referer URL if it hasn't been stored already
    my $referer = $c->req->referer || $c->uri_for('/');
    
    # Get the return_to parameter if it exists (for explicit redirects)
    my $return_to = $c->req->param('return_to');
    if ($return_to) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'login', "Found return_to parameter: $return_to");
        $referer = $return_to;
    }

    # Don't store the login page as the referer
    if ($referer !~ m{/user/login} && $referer !~ m{/login} && $referer !~ m{/do_login}) {
        $c->session->{referer} = $referer;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'login', "Stored referer in session: $referer");
    } else {
        # If we don't have a valid referer and none is stored, use the home page
        $c->session->{referer} = $c->session->{referer} || $c->uri_for('/');
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'login', 
            "Using existing session referer: " . $c->session->{referer});
    }

    # Clear any error messages
    $c->stash->{error_msg} = undef;

    # If the user is already logged in, log it but don't redirect
    if ($c->session->{username}) {
        $self->logging->log_with_details(
            $c, 'info', __FILE__, __LINE__, 'login',
            "User already logged in as: " . $c->session->{username} . ", allowing access to login page"
        );
    }

    # Log the referer
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'login', "Referer: $referer");
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'login', "Session referer: " . ($c->session->{referer} || 'undefined'));

    # Store the referer in the stash for the template
    $c->stash->{return_to} = $c->session->{referer};
    
    # Display the login form
    $c->stash(template => 'user/login.tt');
    $c->forward($c->view('TT'));
}
sub do_login :Local {
    my ($self, $c) = @_;

    # Check if logging is available
    if (not $self->logging || not $self->logging->can('log_with_details')) {
        print STDERR "ERROR: Logging object or method `log_with_details` is missing in User controller\n";
    }

    # Start login process
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_login', 'Login process initiated.');
    
    # Add debug information about the request
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_login', 
        "Request URI: " . $c->req->uri . ", Method: " . $c->req->method);

    # Check if the user is already logged in
    if ($c->session->{username}) {
        $self->logging->log_with_details(
            $c, 'info', __FILE__, __LINE__, 'do_login',
            "User already logged in as: " . $c->session->{username} . ", proceeding with login"
        );
        # Clear the session to allow re-login
        $c->session({});
    }

    # Check if the request method is POST
    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'do_login',
        "Request method: " . $c->req->method
    );

    # If this is a GET request, redirect to the login page
    if ($c->req->method eq 'GET') {
        $self->logging->log_with_details(
            $c, 'info', __FILE__, __LINE__, 'do_login',
            "GET request to do_login, redirecting to login page"
        );
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    # Get user input
    my $username = $c->req->body_parameters->{username} || $c->req->param('username') || '';
    my $password = $c->req->body_parameters->{password} || $c->req->param('password') || '';

    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'do_login',
        "Attempting login for username: $username"
    );

    # Get redirect path
    # Check for return_to parameter first (highest priority)
    my $return_to = $c->req->param('return_to');
    my $redirect_path;
    
    if ($return_to) {
        $redirect_path = $return_to;
        $self->logging->log_with_details(
            $c, 'info', __FILE__, __LINE__, 'do_login',
            "Using return_to parameter for redirect: $return_to"
        );
    } else {
        # Fall back to session referer
        $redirect_path = $c->session->{referer} || '/';
        $self->logging->log_with_details(
            $c, 'info', __FILE__, __LINE__, 'do_login',
            "Using session referer for redirect: " . ($c->session->{referer} || 'undefined')
        );
    }

    # Ensure we're not redirecting back to the login page
    if ($redirect_path =~ m{/user/login} || $redirect_path =~ m{/login} || $redirect_path =~ m{/do_login}) {
        $redirect_path = '/';
        $self->logging->log_with_details(
            $c, 'info', __FILE__, __LINE__, 'do_login',
            "Avoiding redirect to login page, using home page instead"
        );
    }
    
    # Store the redirect path for debugging
    # Ensure debug_msg is always an array
    $c->stash->{debug_msg} = [] unless ref $c->stash->{debug_msg} eq 'ARRAY';
    push @{$c->stash->{debug_msg}}, "Redirect path: $redirect_path";
    $self->logging->log_with_details(
        $c, 'debug', __FILE__, __LINE__, 'do_login',
        "Final redirect path: $redirect_path"
    );

    # Find user in database
    my $user = $c->model('DBEncy::User')->find({ username => $username });
    unless ($user) {
        $self->logging->log_with_details(
            $c, 'warn', __FILE__, __LINE__, 'do_login',
            "Login failed: Username '$username' not found."
        );
        # Store error message in flash and redirect back to login page
        $c->flash->{error_msg} = "Invalid username or password.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    # Verify password
    if ($self->hash_password($password) ne $user->password) {
        $self->logging->log_with_details(
            $c, 'warn', __FILE__, __LINE__, 'do_login',
            "Login failed: Password mismatch for username '$username'."
        );

        # Store error message in flash and redirect back to login page
        $c->flash->{error_msg} = 'Invalid username or password.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    # Success
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_login', "User '$username' successfully authenticated.");

    # Clear any existing session data
    $c->session({});

    # CRITICAL: Validate site access before setting session
    my $current_site_id = $c->session->{site_id} || 1;
    
    # Check if user has access to the current site
    unless ($c->model('User')->has_site_access($user, $current_site_id)) {
        # User doesn't have access to current site
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_login',
            "User '$username' denied access to site_id: $current_site_id");
            
        # Get user's accessible sites
        my $accessible_sites = $c->model('User')->get_accessible_sites($user);
        
        if (@$accessible_sites) {
            # Redirect to first accessible site
            my $primary_site = $accessible_sites->[0];
            $current_site_id = $primary_site->id;
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_login',
                "Redirecting user '$username' to accessible site_id: $current_site_id");
        } else {
            # User has no site access at all
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'do_login',
                "User '$username' has no site access - login denied");
                
            $c->flash->{error_msg} = 'Your account does not have access to any sites. Please contact an administrator.';
            $c->response->redirect($c->uri_for('/user/login'));
            return;
        }
    }

    # Set new session data
    $c->session->{username} = $user->username;
    $c->session->{user_id}  = $user->id;
    $c->session->{first_name} = $user->first_name;
    $c->session->{last_name}  = $user->last_name;
    $c->session->{email}    = $user->email;
    $c->session->{site_id}  = $current_site_id;  # Ensure correct site_id is set

    # Fetch user role(s)
    my $roles = $user->roles;

    # Check if the roles field contains a single role (string) and wrap it into an array
    if (defined $roles && !ref $roles) {
        $roles = [ $roles ];  # Convert single role to array.
    }

    # Default to ['user'] only if roles are undefined or invalid
    if (!defined $roles || ref $roles ne 'ARRAY') {
        $self->logging->log_with_details(
            $c, 'warn', __FILE__, __LINE__, 'do_login',
            "User '$username' has invalid or missing roles. Defaulting to ['user']."
        );
        $roles = ['user'];
    }

    # Log the roles before assigning to session
    my $roles_debug = ref($roles) eq 'ARRAY' ? join(', ', @$roles) : $roles;
    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'do_login',
        "Setting roles in session: $roles_debug"
    );
    
    # Ensure admin role is included if the user should have it
    if (ref($roles) eq 'ARRAY') {
        my $has_admin = 0;
        foreach my $role (@$roles) {
            if (lc($role) eq 'admin') {
                $has_admin = 1;
                last;
            }
        }
        
        # Check if this user should have admin role based on username
        if ($username eq 'Shanta' && !$has_admin) {
            $self->logging->log_with_details(
                $c, 'info', __FILE__, __LINE__, 'do_login',
                "Adding admin role for user: $username"
            );
            push @$roles, 'admin';
        }
    }
    
    # Assign roles to session
    $c->session->{roles} = $roles;
    
    # Log the final roles
    $roles_debug = ref($roles) eq 'ARRAY' ? join(', ', @$roles) : $roles;
    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'do_login',
        "Final roles in session: $roles_debug"
    );

    # Set a success message in the flash
    $c->flash->{success_msg} = "Login successful. Welcome, $username!";

    # Store the redirect path in the flash for debugging
    $c->flash->{debug_msg} = "Redirecting to: $redirect_path";
    
    # We're keeping the referer in case we need it again
    # but we'll store the current redirect path to avoid loops
    $c->session->{last_redirect} = $redirect_path;

    # Log the redirect
    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'do_login',
        "Redirecting user '$username' to: $redirect_path");

    # After successful login, redirect to the appropriate page
    # No need for a template here as this is an action, not a route
    # Use uri_for if it's a relative path, otherwise use the path directly
    if ($redirect_path =~ /^\// && $redirect_path !~ /^https?:\/\//i) {
        # It's a relative path, use uri_for
        $c->res->redirect($c->uri_for($redirect_path));
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_login', "Using uri_for for redirect: " . $c->uri_for($redirect_path));
    } else {
        # It's an absolute URL, use it directly
        $c->res->redirect($redirect_path);
    }
    return;
}

sub do_login_global_remove_completely :Path('/do_login_remove_completely') :Args(0) {
    my ($self, $c) = @_;

    # Check if this is a GET request (direct access)
    if ($c->req->method eq 'GET') {
        # Redirect to the login page instead of processing the login
        $self->logging->log_with_details(
            $c, 'info', __FILE__, __LINE__, 'do_login_global',
            "GET request to do_login, redirecting to login page"
        );
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    # For POST requests, continue with login processing
    $self->process_login($c);
}

sub process_login {
    my ($self, $c) = @_;

    # Check if logging is available
    if (not $self->logging || not $self->logging->can('log_with_details')) {
        print STDERR "ERROR: Logging object or method `log_with_details` is missing in User controller\n";
    }

    # Start login process
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_login', 'Login process initiated.');

    # Check if the user is already logged in
    if ($c->session->{username}) {
        $self->logging->log_with_details(
            $c, 'info', __FILE__, __LINE__, 'do_login',
            "User already logged in as: " . $c->session->{username}
        );
    }

    # Check if the request method is POST
    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'do_login',
        "Request method: " . $c->req->method
    );

    # Get user input - try different methods
    my $username = $c->req->body_parameters->{username} || $c->req->param('username') || '';
    my $password = $c->req->body_parameters->{password} || $c->req->param('password') || '';

    # Log the raw parameters
    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'do_login',
        "Raw username param: " . ($c->req->param('username') || 'undefined')
    );
    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'do_login',
        "Raw password param: " . ($c->req->param('password') ? 'present' : 'undefined')
    );

    # Debug: Log all parameters
    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'do_login',
        "All parameters: " . Dumper($c->req->params)
    );

    # Also try different ways to access parameters
    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'do_login',
        "Using body_parameters: " . Dumper($c->req->body_parameters)
    );
    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'do_login',
        "Using query_parameters: " . Dumper($c->req->query_parameters)
    );

    # Check if we're getting the form_source parameter
    my $form_source = $c->req->params->{form_source} || 'unknown';
    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'do_login',
        "Form source: $form_source"
    );

    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'do_login',
        "Attempting login for username: $username"
    );

    # Get redirect path
    # Check for return_to parameter first (highest priority)
    my $return_to = $c->req->param('return_to');
    my $redirect_path;
    
    if ($return_to) {
        $redirect_path = $return_to;
        $self->logging->log_with_details(
            $c, 'info', __FILE__, __LINE__, 'do_login',
            "Using return_to parameter for redirect: $return_to"
        );
    } else {
        # Fall back to session referer
        $redirect_path = $c->session->{referer} || '/';
        $self->logging->log_with_details(
            $c, 'info', __FILE__, __LINE__, 'do_login',
            "Using session referer for redirect: " . ($c->session->{referer} || 'undefined')
        );
    }
    
    # Store the redirect path for debugging
    $c->stash->{debug_msg} = "Redirect path: $redirect_path";

    # Ensure we're not redirecting back to the login page
    if ($redirect_path =~ m{/user/login} || $redirect_path =~ m{/login} || $redirect_path =~ m{/do_login}) {
        $redirect_path = '/';
        $self->logging->log_with_details(
            $c, 'info', __FILE__, __LINE__, 'do_login',
            "Avoiding redirect to login page, using home page instead"
        );
    }
    
    $self->logging->log_with_details(
        $c, 'debug', __FILE__, __LINE__, 'do_login',
        "Final redirect path: $redirect_path"
    );

    # Find user in database
    my $user = $c->model('DBEncy::User')->find({ username => $username });
    unless ($user) {
        $self->logging->log_with_details(
            $c, 'warn', __FILE__, __LINE__, 'do_login',
            "Login failed: Username '$username' not found."
        );

        # Store error message in flash and redirect back to login page
        $c->flash->{error_msg} = 'Invalid username or password.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    # Verify password
    if ($self->hash_password($password) ne $user->password) {
        $self->logging->log_with_details(
            $c, 'warn', __FILE__, __LINE__, 'do_login',
            "Login failed: Password mismatch for username '$username'."
        );

        # Store error message in flash and redirect back to login page
        $c->flash->{error_msg} = 'Invalid username or password.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    # Success
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_login', "User '$username' successfully authenticated.");

    # Clear any existing session data
    # Reset the session to an empty hash
    $c->session({});

    # Clear any error messages
    $c->stash->{error_msg} = undef;

    # Set new session data
    $c->session->{username} = $user->username;
    $c->session->{user_id}  = $user->id;
    $c->session->{first_name} = $user->first_name;
    $c->session->{last_name}  = $user->last_name;
    $c->session->{email}    = $user->email;

    # Log the session data
    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'do_login',
        "Session data set: username=" . $user->username . ", user_id=" . $user->id
    );

    # Fetch user role(s)
    my $roles = $user->roles;

    # Check if the roles field contains a single role (string) and wrap it into an array
    if (defined $roles && !ref $roles) {
        $roles = [ $roles ];  # Convert single role to array.
    }

    # Default to ['user'] only if roles are undefined or invalid
    if (!defined $roles || ref $roles ne 'ARRAY') {
        $self->logging->log_with_details(
            $c, 'warn', __FILE__, __LINE__, 'do_login',
            "User '$username' has invalid or missing roles. Defaulting to ['user']."
        );
        $roles = ['user'];
    }

    # Assign roles to session
    $c->session->{roles} = $roles;

    # Redirect after successful login
    # Clear the referer to prevent redirect loops
    $c->session->{referer} = undef;

    # Set a success message in the session
    $c->flash->{success_msg} = "Login successful. Welcome, $username!";

    # Log that we've set the flash message
    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'do_login',
        "Set flash success_msg: Login successful. Welcome, $username!"
    );

    # Log the redirect
    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'do_login',
        "Redirecting user '$username' to: $redirect_path");

    # Log the redirect attempt
    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'do_login',
        "Preparing to redirect to: $redirect_path"
    );

    # Double-check that we're not redirecting back to the login page
    if ($redirect_path =~ m{/user/login} || $redirect_path =~ m{/login} || $redirect_path =~ m{/do_login}) {
        $redirect_path = '/';
        $self->logging->log_with_details(
            $c, 'info', __FILE__, __LINE__, 'do_login',
            "Redirecting to home page instead of login page"
        );
    }

    # Redirect directly - no template needed for this action
    # Use uri_for if it's a relative path, otherwise use the path directly
    if ($redirect_path =~ /^\//) {
        # It's a relative path, use uri_for
        $c->res->redirect($c->uri_for($redirect_path));
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_login', "Using uri_for for redirect: " . $c->uri_for($redirect_path));
    } else {
        # It's an absolute URL, use it directly
        $c->res->redirect($redirect_path);
    }
    return;
}
sub hash_password {
    my ($self, $password) = @_;
    return sha256_hex($password);
}

sub logout :Local {
    my ($self, $c) = @_;

    # Store the current URL before logout
    my $current_url = $c->req->referer || $c->uri_for('/');

    # Log the logout action with the current URL
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'logout',
        "User '" . ($c->session->{username} || 'unknown') . "' logging out, current URL: $current_url");

    # Get username before clearing session (for the success message)
    my $username = $c->session->{username} || 'Guest';

    # Store important site information before clearing the session
    my $site_name = $c->session->{SiteName} || '';
    my $theme_name = $c->session->{theme_name} || '';
    my $controller_name = $c->session->{ControllerName} || '';

    # Log the site information we're preserving
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'logout',
        "Preserving site info: SiteName=$site_name, theme=$theme_name, controller=$controller_name");

    # Properly delete the session (instead of just emptying it)
    $c->delete_session("User logged out");

    # Create a new session with minimal required data
    $c->session->{SiteName} = $site_name if $site_name;
    $c->session->{theme_name} = $theme_name if $theme_name;
    $c->session->{ControllerName} = $controller_name if $controller_name;

    # Set a success message
    $c->flash->{success_msg} = "You have been successfully logged out.";

    # Log the session deletion
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'logout',
        "Session deleted for user '$username'. New session ID: " . $c->sessionid);

    # Check if the current page is accessible to non-logged-in users
    # List of public pages that don't require login
    my @public_pages = (
        qr{^/Documentation},  # Documentation pages
        qr{^/$},              # Home page
        qr{^/about},          # About page
        qr{^/contact},        # Contact page
        qr{^/user/login},     # Login page
        qr{^/user/register}, # Registration page
        qr{^/mcoop},          # MCoop pages
        qr{^/csc},            # CSC pages
        qr{^/usbm},           # USBM pages
        qr{^/forager},        # Forager pages
        qr{^/ve7tit},         # Ve7tit pages
    );

    # Check if current URL is in the public pages list
    my $is_public = 0;
    foreach my $pattern (@public_pages) {
        if ($current_url =~ $pattern) {
            $is_public = 1;
            last;
        }
    }

    # Log the decision
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'logout',
        "URL $current_url is " . ($is_public ? "public" : "not public"));

    # Determine the redirect URL
    my $redirect_url;

    # Log all the information we have for debugging
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'logout',
        "Current URL: $current_url, SiteName: $site_name, Controller: $controller_name");

    # First, try to extract the site from the current URL
    my $site_from_url = '';
    if ($current_url =~ m{^/([^/]+)}) {
        $site_from_url = $1;
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'logout',
            "Extracted site from URL: $site_from_url");
    }

    # Check if the site from URL is a valid controller
    my $site_controller_exists = 0;
    if ($site_from_url) {
        eval {
            my $controller = $c->controller(ucfirst($site_from_url));
            $site_controller_exists = 1 if $controller;
        };
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'logout',
            "Site controller exists: " . ($site_controller_exists ? "Yes" : "No"));
    }

    if ($is_public) {
        # If the current page is public, stay on it
        $redirect_url = $current_url;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'logout',
            "Redirecting to current public page: $redirect_url");
    } elsif ($site_controller_exists) {
        # If we extracted a valid controller from the URL, use that
        $redirect_url = $c->uri_for("/$site_from_url");
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'logout',
            "Redirecting to site from URL: $redirect_url");
    } elsif ($controller_name && $controller_name ne 'Root') {
        # If we have a site-specific controller in the session, redirect to its home page
        $redirect_url = $c->uri_for("/$controller_name");
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'logout',
            "Redirecting to site controller from session: $redirect_url");
    } elsif ($site_name && $site_name ne 'none') {
        # Try to use the site name as a fallback
        $redirect_url = $c->uri_for("/" . lc($site_name));
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'logout',
            "Redirecting to site from SiteName: $redirect_url");
    } else {
        # Default to the root home page as a last resort
        $redirect_url = $c->uri_for('/');
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'logout',
            "Redirecting to default home page: $redirect_url");
    }

    # Perform the redirect
    $c->response->redirect($redirect_url);
    return;
}

sub profile :Local {
    my ($self, $c) = @_;

    # Check if user is logged in
    unless ($c->session->{username}) {
        $c->flash->{error_msg} = "You must be logged in to view your profile.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    # Log the profile access
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'profile',
        "User '" . $c->session->{username} . "' accessing profile");

    # Get user data from database
    my $user = $c->model('DBEncy::User')->find({ username => $c->session->{username} });

    unless ($user) {
        $c->flash->{error_msg} = "User not found in database. Please log in again.";
        $c->session({});  # Clear session
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    # Get user's current mailing list subscriptions
    my $site_id = $c->session->{site_id} || 1;
    my @user_subscriptions = $user->mailing_list_subscriptions->search({
        'mailing_list.site_id' => $site_id,
        'mailing_list.is_active' => 1,
        'me.is_active' => 1
    }, {
        join => 'mailing_list',
        prefetch => 'mailing_list'
    });

    # Prepare user data for display
    my $user_data = {
        username => $user->username,
        first_name => $user->first_name,
        last_name => $user->last_name,
        email => $user->email,
        roles => $c->session->{roles} || [],
        subscriptions => \@user_subscriptions,
        # Add other fields as needed
    };

    # Set template and stash data
    $c->stash(
        user => $user_data,
        template => 'user/profile.tt'
    );

    $c->forward($c->view('TT'));
}

sub settings :Local {
    my ($self, $c) = @_;

    # Check if user is logged in
    unless ($c->session->{username}) {
        $c->flash->{error_msg} = "You must be logged in to access account settings.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    # Log the settings access
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'settings',
        "User '" . $c->session->{username} . "' accessing account settings");

    # Get user data from database
    my $user = $c->model('DBEncy::User')->find({ username => $c->session->{username} });

    unless ($user) {
        $c->flash->{error_msg} = "User not found in database. Please log in again.";
        $c->session({});  # Clear session
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    # Get available mailing lists for the site
    my $site_id = $c->session->{site_id} || 1;
    my $available_lists = $c->forward('/mail/get_available_lists', [$site_id]) || [];
    
    # Get user's current subscriptions
    my @current_subscriptions = $user->mailing_list_subscriptions->search({
        'mailing_list.site_id' => $site_id,
        'mailing_list.is_active' => 1,
        'me.is_active' => 1
    }, {
        join => 'mailing_list'
    });
    
    # Create a hash of subscribed list IDs for easy lookup
    my %subscribed_lists = map { $_->mailing_list_id => 1 } @current_subscriptions;

    # Set template and stash data
    $c->stash(
        user => {
            username => $user->username,
            first_name => $user->first_name,
            last_name => $user->last_name,
            email => $user->email,
            email_notifications => $self->_user_has_email_notifications($user, $c->session->{site_id} || 1),
            # Add other fields as needed
        },
        available_mailing_lists => $available_lists,
        subscribed_lists => \%subscribed_lists,
        template => 'user/settings.tt'
    );

    $c->forward($c->view('TT'));
}

sub update_settings :Local {
    my ($self, $c) = @_;

    # Check if user is logged in
    unless ($c->session->{username}) {
        $c->flash->{error_msg} = "You must be logged in to update settings.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    # Log the update attempt
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_settings',
        "User '" . $c->session->{username} . "' attempting to update settings");

    # Get user data from database
    my $user = $c->model('DBEncy::User')->find({ username => $c->session->{username} });

    unless ($user) {
        $c->flash->{error_msg} = "User not found in database. Please log in again.";
        $c->session({});  # Clear session
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    # Get form data
    my $first_name = $c->req->params->{first_name};
    my $last_name = $c->req->params->{last_name};
    my $email = $c->req->params->{email};
    my $theme = $c->req->params->{theme} || 'default';
    my $email_notifications = $c->req->params->{email_notifications} ? 1 : 0;
    my $debug_mode = $c->req->params->{debug_mode} ? 1 : 0;

    # Validate input
    unless ($first_name && $last_name && $email) {
        $c->flash->{error_msg} = "First name, last name, and email are required fields.";
        $c->response->redirect($c->uri_for('/user/settings'));
        return;
    }

    # Validate email format
    unless ($email =~ /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/) {
        $c->flash->{error_msg} = "Invalid email format.";
        $c->response->redirect($c->uri_for('/user/settings'));
        return;
    }

    # Update user in database
    eval {
        $user->update({
            first_name => $first_name,
            last_name => $last_name,
            email => $email,
            # Add other fields as needed
        });
        
        # Handle email_notifications through default announcement mailing list
        $self->_update_user_email_notifications($user, $email_notifications, $c->session->{site_id} || 1);
    };

    if ($@) {
        # Log the error
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_settings',
            "Error updating user settings: $@");

        $c->flash->{error_msg} = "An error occurred while updating your settings. Please try again.";
        $c->response->redirect($c->uri_for('/user/settings'));
        return;
    }

    # Handle mailing list subscription updates
    my $site_id = $c->session->{site_id} || 1;
    
    # Get current subscriptions (outside eval for later use)
    my @current_subscriptions = $user->mailing_list_subscriptions->search({
        'mailing_list.site_id' => $site_id,
        'mailing_list.is_active' => 1
    }, {
        join => 'mailing_list'
    });
    
    # Process radio button selections for mailing lists
    my @selected_list_ids = ();
    my $params = $c->req->params;
    
    # Find all mailing list subscription parameters (format: list_{id}_subscription)
    foreach my $param_name (keys %$params) {
        if ($param_name =~ /^list_(\d+)_subscription$/) {
            my $list_id = $1;
            my $subscription_status = $params->{$param_name};
            
            # Only add to selected if user chose "subscribed"
            if ($subscription_status eq 'subscribed') {
                push @selected_list_ids, $list_id;
            }
        }
    }
    
    eval {
        my $schema = $c->model('DBEncy');
        
        # Create hash of current subscriptions
        my %current_subs = map { $_->mailing_list_id => $_ } @current_subscriptions;
        
        # Add new subscriptions
        foreach my $list_id (@selected_list_ids) {
            unless ($current_subs{$list_id}) {
                my $list = $schema->resultset('MailingList')->find({
                    id => $list_id,
                    site_id => $site_id,
                    is_active => 1
                });
                
                if ($list) {
                    $schema->resultset('MailingListSubscription')->create({
                        mailing_list_id => $list_id,
                        user_id => $user->id,
                        subscription_source => 'profile_update',
                        is_active => 1,
                    });
                    
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_settings',
                        "User " . $user->username . " subscribed to mailing list: " . $list->name);
                }
            }
        }
        
        # Remove unselected subscriptions (deactivate rather than delete)
        my %selected_hash = map { $_ => 1 } @selected_list_ids;
        foreach my $list_id (keys %current_subs) {
            unless ($selected_hash{$list_id}) {
                $current_subs{$list_id}->update({ is_active => 0 });
                
                my $list_name = $current_subs{$list_id}->mailing_list->name;
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_settings',
                    "User " . $user->username . " unsubscribed from mailing list: $list_name");
            }
        }
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_settings',
            "Error updating mailing list subscriptions: $@");
        # Don't fail the entire update for mailing list errors
    }
    
    # Send admin notification if there were mailing list changes
    my @new_subscriptions = ();
    my @removed_subscriptions = ();
    
    # Collect changes for admin notification
    my %selected_hash = map { $_ => 1 } @selected_list_ids;
    my %current_subs = map { $_->mailing_list_id => $_ } @current_subscriptions;
    
    # Find new subscriptions
    foreach my $list_id (@selected_list_ids) {
        unless ($current_subs{$list_id}) {
            my $list = $c->model('DBEncy')->resultset('MailingList')->find($list_id);
            push @new_subscriptions, $list->name if $list;
        }
    }
    
    # Find removed subscriptions
    foreach my $list_id (keys %current_subs) {
        unless ($selected_hash{$list_id}) {
            push @removed_subscriptions, $current_subs{$list_id}->mailing_list->name;
        }
    }
    
    # Send admin notification if there were changes
    if (@new_subscriptions || @removed_subscriptions) {
        my $mail_to_admin = $c->stash->{mail_to_admin};
        
        if ($mail_to_admin && $mail_to_admin =~ /\@/) {
            eval {
                my $mail_from = $c->stash->{mail_from} || 'noreply@computersystemconsulting.ca';
                my $timestamp = scalar localtime;
                
                $c->stash->{email} = {
                    to       => $mail_to_admin,
                    from     => $mail_from,
                    subject  => 'Comserv - User Mailing List Subscription Changes',
                    template => 'email/admin_subscription_notification.tt',
                    template_vars => {
                        username   => $user->username,
                        first_name => $first_name,
                        last_name  => $last_name,
                        email      => $email,
                        updated_at => $timestamp,
                        site_name  => $c->stash->{ScriptDisplayName} || 'Comserv',
                        new_subscriptions => \@new_subscriptions,
                        removed_subscriptions => \@removed_subscriptions,
                    },
                };
                
                $c->forward($c->view('Email::Template'));
                
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_settings',
                    "Admin notification sent for mailing list changes by user: " . $user->username);
            };
            
            if ($@) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_settings',
                    "Error sending admin notification for mailing list changes: $@");
            }
        }
    }

    # Update session data
    $c->session->{first_name} = $first_name;
    $c->session->{last_name} = $last_name;
    $c->session->{email} = $email;
    $c->session->{theme_name} = $theme;
    $c->session->{debug_mode} = $debug_mode;

    # Log the successful update
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_settings',
        "User '" . $c->session->{username} . "' settings updated successfully");

    # Set success message and redirect
    $c->flash->{success_msg} = "Your settings have been updated successfully.";
    $c->response->redirect($c->uri_for('/user/profile'));
    return;
}

sub do_create_account :Local {
    my ($self, $c) = @_;

    # Retrieve the form data
    my $username = $c->request->params->{username};
    my $password = $c->request->params->{password};
    my $password_confirm = $c->request->params->{password_confirm};  # Retrieve the confirmation password
    my $first_name = $c->request->params->{first_name};
    my $last_name = $c->request->params->{last_name};
    my $email = $c->request->params->{email};
    my $roles = $c->request->params->{roles} || 'user';  # Default role is 'user'

    # Log the account creation attempt
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_create_account',
        "Account creation attempt for username: $username");

    # Ensure all required fields are filled
    unless ($username && $password && $password_confirm && $first_name && $last_name) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_create_account',
            "Missing required fields for account creation");

        $c->stash(
            error_msg => 'All fields are required to create an account',
            template  => 'user/register.tt',
        );
        return;
    }

    # Check if the passwords match
    if ($password ne $password_confirm) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_create_account',
            "Passwords do not match for account creation");

        $c->stash(
            error_msg => 'Passwords do not match',
            template  => 'user/register.tt',
        );
        return;
    }

    # Hash the password
    my $hashed_password = $self->hash_password($password);

    # Check if the username already exists in the database
    my $existing_user = $c->model('DBEncy::User')->find({ username => $username });
    if ($existing_user) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_create_account',
            "Username already exists: $username");

        $c->stash(
            error_msg => 'Username already exists. Please choose another.',
            template  => 'user/register.tt',
        );
        return;
    }

    # Get the current site ID from session
    my $site_id = $c->session->{site_id} || 1;
    
    # Create the new user in the database
    my $new_user;
    eval {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_create_account',
            "Creating new user: $username with roles: $roles for site_id: $site_id");

        $new_user = $c->model('DBEncy::User')->create({
            username    => $username,
            password    => $hashed_password,
            first_name  => $first_name,
            last_name   => $last_name,
            email       => $email,
            roles       => $roles,
            active      => 1,
            created_at  => \'NOW()',
        });
        
        # CRITICAL: Create user-site relationship immediately after user creation
        if ($new_user) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_create_account',
                "Creating user-site relationship for user_id: " . $new_user->id . ", site_id: $site_id");
                
            # Create entry in user_sites table
            $c->model('DBEncy::UserSite')->create({
                user_id => $new_user->id,
                site_id => $site_id,
            });
            
            # Create default site role entry for proper role management
            $c->model('DBEncy::UserSiteRole')->create({
                user_id => $new_user->id,
                site_id => $site_id,
                role => 'site_user',  # Default role for new users
                granted_by => undef,  # System-granted during registration
                is_active => 1,
            });
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_create_account',
                "User-site relationship created successfully for user: $username");
        }
    };

    if ($@) {
        # Handle any database errors
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'do_create_account',
            "Error creating user: $@");
            
        $c->stash(
            error_msg => "An error occurred while creating the account: $@",
            template  => 'user/register.tt',
        );
        return;
    }

    # Get email configuration from the stash (set by site_setup in Root.pm)
    # These variables are set in Root.pm's site_setup method for each site
    my $mail_from = $c->stash->{mail_from}; 
    my $mail_replyto = $c->stash->{mail_replyto};
    
    # Log the email configuration for debugging
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_create_account',
        "Email configuration - From: " . ($mail_from || 'undefined') . 
        ", Reply-To: " . ($mail_replyto || 'undefined'));
    
    # Send email notification to the user if we have a valid email address
    if ($email && $email =~ /\@/) {
        eval {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_create_account',
                "Sending welcome email to new user: $email");
                
            # Use default values if site configuration is missing
            my $from_address = $mail_from || 'noreply@computersystemconsulting.ca';
            my $reply_to = $mail_replyto || 'helpdesk@computersystemconsulting.ca';
            
            $c->stash->{email} = {
                to       => $email,
                from     => $from_address,
                reply_to => $reply_to,
                subject  => 'Welcome to Comserv - Account Created',
                template => 'email/account_created.tt',
                template_vars => {
                    username   => $username,
                    first_name => $first_name,
                    last_name  => $last_name,
                    email      => $email,
                    site_name  => $c->stash->{ScriptDisplayName} || 'Comserv',
                },
            };
            
            # Send the email
            $c->forward($c->view('Email::Template'));
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_create_account',
                "Welcome email sent successfully to: $email");
        };
    } else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_create_account',
            "Cannot send welcome email: Invalid or missing user email address");
    }
    
    if ($@) {
        # Log email error but continue (don't block account creation if email fails)
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'do_create_account',
            "Error sending welcome email: $@");
    }
    
    # Handle mailing list subscriptions first so we can include them in admin notification
    my $selected_lists = $c->req->params->{mailing_lists};
    my @subscribed_list_names = ();
    
    if ($selected_lists && $new_user) {
        $selected_lists = [$selected_lists] unless ref($selected_lists) eq 'ARRAY';
        
        eval {
            my $schema = $c->model('DBEncy');
            
            foreach my $list_id (@$selected_lists) {
                next unless $list_id && $list_id =~ /^\d+$/;
                
                my $list = $schema->resultset('MailingList')->find({
                    id => $list_id,
                    site_id => $c->session->{site_id} || 1,
                    is_active => 1
                });
                
                if ($list) {
                    $schema->resultset('MailingListSubscription')->create({
                        mailing_list_id => $list_id,
                        user_id => $new_user->id,
                        subscription_source => 'registration',
                        is_active => 1,
                    });
                    
                    push @subscribed_list_names, $list->name;
                    
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_create_account',
                        "User $username subscribed to mailing list: " . $list->name);
                }
            }
        };
        
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'do_create_account',
                "Error processing mailing list subscriptions: $@");
        }
    }
    
    # Always ensure new user is subscribed to the default announcement list (SiteName Announcements)
    if ($new_user) {
        eval {
            my $site_id = $c->session->{site_id} || 1;
            my $announcement_list = $self->_get_or_create_announcement_list($new_user, $site_id);
            
            if ($announcement_list) {
                # Check if already subscribed (might be in the selected lists above)
                my $schema = $c->model('DBEncy');
                my $existing_announcement_sub = $schema->resultset('MailingListSubscription')->find({
                    mailing_list_id => $announcement_list->id,
                    user_id => $new_user->id,
                });
                
                unless ($existing_announcement_sub) {
                    $schema->resultset('MailingListSubscription')->create({
                        mailing_list_id => $announcement_list->id,
                        user_id => $new_user->id,
                        subscription_source => 'registration_default_announcement',
                        is_active => 1,
                    });
                    
                    push @subscribed_list_names, $announcement_list->name;
                    
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_create_account',
                        "User $username auto-subscribed to default announcement list: " . $announcement_list->name);
                }
            }
        };
        
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'do_create_account',
                "Error subscribing to default announcement list: $@");
        }
    }

    # Get the admin email from the stash (set by site_setup in Root.pm)
    # This variable is set in Root.pm's site_setup method for each site
    my $mail_to_admin = $c->stash->{mail_to_admin};
    
    # Log the admin email for debugging
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_create_account',
        "Admin email: " . ($mail_to_admin || 'undefined'));
    
    # Send notification to admin if we have a valid admin email
    if ($mail_to_admin && $mail_to_admin =~ /\@/) {
        eval {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_create_account',
                "Sending admin notification about new user to: $mail_to_admin");
                
            # Format the current timestamp
            my $timestamp = scalar localtime;
            
            # Use default values if site configuration is missing
            my $from_address = $mail_from || 'noreply@computersystemconsulting.ca';
                
            $c->stash->{email} = {
                to       => $mail_to_admin,
                from     => $from_address,
                subject  => 'Comserv - New User Account Created',
                template => 'email/admin_account_notification.tt',
                template_vars => {
                    username   => $username,
                    first_name => $first_name,
                    last_name  => $last_name,
                    email      => $email,
                    roles      => $roles,
                    created_at => $timestamp,
                    site_name  => $c->stash->{ScriptDisplayName} || 'Comserv',
                    mailing_lists => \@subscribed_list_names,
                },
            };
            
            # Send the email
            $c->forward($c->view('Email::Template'));
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_create_account',
                "Admin notification email sent successfully to: $mail_to_admin");
        };
    } else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_create_account',
            "Cannot send admin notification: Invalid or missing admin email address");
    }
    
    if ($@) {
        # Log email error but continue
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'do_create_account',
            "Error sending admin notification email: $@");
    }
    
    # Clear newsletter email from session if it was used
    delete $c->session->{newsletter_email} if $c->session->{newsletter_email};

    # Set success message and redirect to the login page
    $c->flash->{success_msg} = "Your account has been created successfully. You can now log in.";
    $c->response->redirect($c->uri_for('/user/login'));
}
sub list_users :Local :Args(0) {
    my ($self, $c) = @_;

    # Fetch the list of users and pass it to the view
    my @users = $c->model('DBEncy::User')->all;
    $c->stash(users => \@users);

    # Display the list of users
    $c->stash(template => 'user/list_users.tt');
}
sub edit_user :Local :Args(1) {
    my ($self, $c) = @_;

    # Check if user is logged in
    unless ($c->user_exists) {
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    # Get current site context
    my $current_site_id = $c->session->{site_id} || 1;
    
    # Check if user has permission to edit users on this site
    unless ($c->check_user_roles_enhanced('admin', $current_site_id) || 
            $c->check_user_roles_enhanced('site_admin', $current_site_id) || 
            $c->check_user_roles_enhanced('csc_admin')) {
        
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'edit_user',
            "Access denied: User " . $c->session->{username} . " attempted to edit user without proper permissions");
        
        $c->stash(error_msg => 'Access denied. You do not have permission to edit users.');
        $c->stash(template => 'error.tt');
        return;
    }

    # Retrieve the user ID from the URL
    my $user_id = $c->request->arguments->[0];

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object
    my $rs = $schema->resultset('User');

    # Find the user in the database
    my $user = $rs->find($user_id);

    if ($user) {
        # Log the access
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_user',
            "User " . $c->session->{username} . " accessing edit form for user ID: $user_id");
        
        # The user was found, so store the user object in the stash
        $c->stash(user => $user);

        # Set the template for the response
        $c->stash(template => 'user/edit_user.tt');
    } else {
        # The user was not found, so display an error message
        $c->stash(error_msg => 'User not found');
        $c->stash(template => 'error.tt');
    }
}
sub do_edit_user :Local :Args(1) {
    my ($self, $c) = @_;

    # Check if user is logged in
    unless ($c->user_exists) {
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    # Get current site context
    my $current_site_id = $c->session->{site_id} || 1;
    
    # Check if user has permission to edit users on this site
    unless ($c->check_user_roles_enhanced('admin', $current_site_id) || 
            $c->check_user_roles_enhanced('site_admin', $current_site_id) || 
            $c->check_user_roles_enhanced('csc_admin')) {
        
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_edit_user',
            "Access denied: User " . $c->session->{username} . " attempted to update user without proper permissions");
        
        $c->stash(error_msg => 'Access denied. You do not have permission to edit users.');
        $c->stash(template => 'error.tt');
        return;
    }

    # Retrieve the user ID from the URL
    my $user_id = $c->request->arguments->[0];

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object
    my $rs = $schema->resultset('User');

    # Find the user in the database
    my $user = $rs->find($user_id);

    if ($user) {
        # The user was found, so retrieve the form data
        my $form_data = $c->request->body_parameters;

        # Log the update attempt
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_edit_user',
            "User " . $c->session->{username} . " updating user ID: $user_id");

        # Prepare update data
        my $update_data = {
            username   => $form_data->{username},
            first_name => $form_data->{first_name},
            last_name  => $form_data->{last_name},
            email      => $form_data->{email},
        };

        # Handle roles field with proper access control
        my $can_edit_roles = $c->check_user_roles_enhanced('admin', $current_site_id) || 
                           $c->check_user_roles_enhanced('site_admin', $current_site_id) || 
                           $c->check_user_roles_enhanced('csc_admin');

        if ($can_edit_roles) {
            # User has permission to edit roles
            my $new_roles = $form_data->{roles};
            
            # Log role change if different
            if (($user->roles || '') ne ($new_roles || '')) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_edit_user',
                    "Role change for user ID $user_id: '" . ($user->roles || 'none') . "' -> '" . ($new_roles || 'none') . "'");
            }
            
            $update_data->{roles} = $new_roles;
        } else {
            # User doesn't have permission to edit roles - preserve existing roles
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_edit_user',
                "Preserving existing roles for user ID $user_id (no role edit permission)");
        }

        # Update the user record with the new data
        eval {
            $user->update($update_data);
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_edit_user',
                "Successfully updated user ID: $user_id");
            
            # Set success message
            $c->flash->{success_msg} = "User updated successfully.";
        };
        
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'do_edit_user',
                "Error updating user ID $user_id: $@");
            
            $c->flash->{error_msg} = "Error updating user: $@";
        }

        # Redirect the user back to the list of users
        $c->response->redirect($c->uri_for($self->action_for('list_users')));
    } else {
        # The user was not found, so display an error message
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_edit_user',
            "User not found for ID: $user_id");
        
        $c->stash(error_msg => 'User not found');
        $c->stash(template => 'error.tt');
    }
}
sub register :Local {
    my ($self, $c) = @_;

    # Get available mailing lists for the site
    my $site_id = $c->session->{site_id} || 1;
    my $available_lists = $c->forward('/mail/get_available_lists', [$site_id]) || [];
    
    # Debug logging
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'register',
        "Site ID: $site_id, Available lists count: " . scalar(@$available_lists));
    
    # Additional debug - let's also try direct database query
    eval {
        my $schema = $c->model('DBEncy');
        my @direct_lists = $schema->resultset('MailingList')->search(
            { 
                site_id => $site_id,
                is_active => 1 
            },
            { order_by => 'name' }
        )->all;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'register',
            "Direct DB query found " . scalar(@direct_lists) . " lists");
            
        # If forward didn't work, use direct query
        if (!@$available_lists && @direct_lists) {
            $available_lists = \@direct_lists;
        }
    };
    
    # Pre-fill email if coming from newsletter signup
    my $prefill_email = $c->session->{newsletter_email} || '';
    
    $c->stash(
        available_mailing_lists => $available_lists,
        prefill_email => $prefill_email,
        template => 'user/register.tt'
    );
}

sub debug_create_lists :Local {
    my ($self, $c) = @_;
    
    my $site_id = $c->session->{site_id} || 1;
    my $user_id = $c->session->{user_id} || 1;
    
    eval {
        my $schema = $c->model('DBEncy');
        
        # Check if lists already exist
        my $existing_count = $schema->resultset('MailingList')->search({
            site_id => $site_id
        })->count;
        
        if ($existing_count == 0) {
            # Create test mailing lists
            my @test_lists = (
                {
                    name => 'Newsletter',
                    description => 'General newsletter with updates and announcements',
                    is_software_only => 1,
                },
                {
                    name => 'Workshop Notifications',
                    description => 'Notifications about upcoming workshops and events',
                    is_software_only => 1,
                }
            );
            
            foreach my $list_data (@test_lists) {
                $schema->resultset('MailingList')->create({
                    site_id => $site_id,
                    name => $list_data->{name},
                    description => $list_data->{description},
                    is_software_only => $list_data->{is_software_only},
                    is_active => 1,
                    created_by => $user_id,
                });
            }
            
            $c->response->body("Created " . scalar(@test_lists) . " test mailing lists for site $site_id");
        } else {
            $c->response->body("Mailing lists already exist ($existing_count found)");
        }
    };
    
    if ($@) {
        $c->response->body("Error: $@");
    }
}
sub welcome :Local {
    my ($self, $c) = @_;

    # Display the welcome page
    $c->stash(template => 'user/welcome.tt');
    $c->forward($c->view('TT'));
}

# Administrative method to fix existing users without site relationships
sub fix_user_site_relationships :Local {
    my ($self, $c) = @_;
    
    # Only allow CSC admins to run this
    unless ($c->check_user_roles('admin')) {
        $c->response->status(403);
        $c->response->body('Access denied: Admin role required');
        return;
    }
    
    my $fixed_count = 0;
    my $error_count = 0;
    my @messages;
    
    eval {
        my $schema = $c->model('DBEncy');
        
        # Find all users without any site relationships
        my @users_without_sites = $schema->resultset('User')->search({
            'user_sites.user_id' => undef
        }, {
            join => { user_sites => 'site' },
            prefetch => 'user_sites'
        })->all;
        
        push @messages, "Found " . scalar(@users_without_sites) . " users without site relationships";
        
        foreach my $user (@users_without_sites) {
            eval {
                # Default to site_id = 1 for existing users
                my $default_site_id = 1;
                
                # Create user-site relationship
                $schema->resultset('UserSite')->create({
                    user_id => $user->id,
                    site_id => $default_site_id,
                });
                
                # Create default site role
                $schema->resultset('UserSiteRole')->create({
                    user_id => $user->id,
                    site_id => $default_site_id,
                    role => 'site_user',
                    granted_by => undef,  # System-granted
                    is_active => 1,
                });
                
                $fixed_count++;
                push @messages, "Fixed user: " . $user->username . " (ID: " . $user->id . ")";
                
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fix_user_site_relationships',
                    "Fixed site relationship for user: " . $user->username);
            };
            
            if ($@) {
                $error_count++;
                push @messages, "Error fixing user " . $user->username . ": $@";
                
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'fix_user_site_relationships',
                    "Error fixing user " . $user->username . ": $@");
            }
        }
    };
    
    if ($@) {
        push @messages, "General error: $@";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'fix_user_site_relationships',
            "General error in fix_user_site_relationships: $@");
    }
    
    # Return results
    my $result = {
        fixed_count => $fixed_count,
        error_count => $error_count,
        messages => \@messages,
    };
    
    $c->response->content_type('application/json');
    $c->response->body(JSON::encode_json($result));
}

# Administrative interface for managing user-site relationships
sub manage_site_access :Local {
    my ($self, $c) = @_;
    
    # Only allow CSC admins to access this
    unless ($c->check_user_roles('admin')) {
        $c->response->status(403);
        $c->stash(
            error_msg => 'Access denied: Admin role required',
            template => 'error/403.tt'
        );
        return;
    }
    
    my $action = $c->req->param('action') || 'list';
    
    if ($action eq 'add' && $c->req->method eq 'POST') {
        # Add site access for a user
        my $user_id = $c->req->param('user_id');
        my $site_id = $c->req->param('site_id');
        my $role = $c->req->param('role') || 'site_user';
        
        if ($user_id && $site_id) {
            my $user = $c->model('DBEncy::User')->find($user_id);
            if ($user) {
                my $success = $c->model('User')->add_site_access($user, $site_id, $role, $c->session->{user_id});
                if ($success) {
                    $c->flash->{success_msg} = "Site access granted successfully";
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'manage_site_access',
                        "Granted site access: user_id=$user_id, site_id=$site_id, role=$role");
                } else {
                    $c->flash->{error_msg} = "Failed to grant site access";
                }
            } else {
                $c->flash->{error_msg} = "User not found";
            }
        } else {
            $c->flash->{error_msg} = "Missing required parameters";
        }
        
        $c->response->redirect($c->uri_for('/user/manage_site_access'));
        return;
    }
    
    if ($action eq 'remove' && $c->req->method eq 'POST') {
        # Remove site access for a user
        my $user_id = $c->req->param('user_id');
        my $site_id = $c->req->param('site_id');
        
        if ($user_id && $site_id) {
            my $user = $c->model('DBEncy::User')->find($user_id);
            if ($user) {
                my $success = $c->model('User')->remove_site_access($user, $site_id);
                if ($success) {
                    $c->flash->{success_msg} = "Site access removed successfully";
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'manage_site_access',
                        "Removed site access: user_id=$user_id, site_id=$site_id");
                } else {
                    $c->flash->{error_msg} = "Failed to remove site access";
                }
            } else {
                $c->flash->{error_msg} = "User not found";
            }
        } else {
            $c->flash->{error_msg} = "Missing required parameters";
        }
        
        $c->response->redirect($c->uri_for('/user/manage_site_access'));
        return;
    }
    
    # Default: List all users and their site access
    eval {
        my $schema = $c->model('DBEncy');
        
        # Get all users with their site relationships
        my @users = $schema->resultset('User')->search(
            {},
            {
                prefetch => ['user_sites', 'user_site_roles'],
                order_by => 'username'
            }
        )->all;
        
        # Get all available sites
        my @sites = $schema->resultset('Project')->search(
            { is_active => 1 },
            { order_by => 'name' }
        )->all;
        
        $c->stash(
            users => \@users,
            sites => \@sites,
            template => 'user/manage_site_access.tt'
        );
    };
    
    if ($@) {
        $c->stash(
            error_msg => "Error loading data: $@",
            template => 'error/500.tt'
        );
    }
}
sub forgot_password :Local {
    my ($self, $c) = @_;

    # Log access to the forgot password page
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'forgot_password', 'Accessing forgot password page');

    if ($c->req->method eq 'POST') {
        # Process the form submission
        my $email = $c->req->params->{email};

        # Validate email
        if (!$email) {
            $c->stash(error_msg => 'Please enter your email address');
            $c->stash(template => 'user/forgot_password.tt');
            return;
        }

        # Find user with the provided email
        my $user = $c->model('DBEncy::User')->find({ email => $email });

        if ($user) {
            # Generate a reset token (in a real implementation, you'd store this in the database)
            # For now, we'll just show a success message

            $self->logging->log_with_details(
                $c, 'info', __FILE__, __LINE__, 'forgot_password',
                "Password reset requested for email: $email"
            );

            $c->stash(
                success_msg => 'If an account exists with that email, password reset instructions have been sent.',
                template => 'user/forgot_password.tt'
            );
        } else {
            # Don't reveal that the email doesn't exist (security best practice)
            $c->stash(success_msg => 'If an account exists with that email, password reset instructions have been sent.');
        }
    }

    # Display the forgot password form
    $c->stash(template => 'user/forgot_password.tt');
}

sub change_password_request :Local {
    my ($self, $c) = @_;

    # Log access to the change password request page
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'change_password_request', 'Accessing change password request page');

    # Display the change password request form
    $c->stash(template => 'user/change_password_request.tt');
    $c->forward($c->view('TT'));
}

sub do_change_password_request :Path('/do_change_password_request') :Args(0) {
    my ($self, $c) = @_;

    # Log the password change request
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_change_password_request', 'Processing change password request');

    # Get the email from the form
    my $email = $c->req->params->{email} || '';

    # Validate email
    if (!$email) {
        $c->stash(
            error_msg => 'Please enter your email address',
            template => 'user/change_password_request.tt'
        );
        $c->forward($c->view('TT'));
        return;
    }

    # Find user with the provided email
    my $user = $c->model('DBEncy::User')->find({ email => $email });

    if ($user) {
        # In a real implementation, you would:
        # 1. Generate a unique token
        # 2. Store it in the database with an expiration time
        # 3. Send an email with a link containing the token

        $self->logging->log_with_details(
            $c, 'info', __FILE__, __LINE__, 'do_change_password_request',
            "Password change requested for email: $email"
        );
    }

    # Always show success message (even if email not found) for security
    $c->stash(
        success_msg => 'If an account exists with that email, password reset instructions have been sent.',
        template => 'user/change_password_request.tt'
    );
    $c->forward($c->view('TT'));
}

# Helper method to check if user has email notifications enabled
# This is determined by subscription to the default announcement mailing list
sub _user_has_email_notifications {
    my ($self, $user, $site_id) = @_;
    
    # Find or create the default announcement list for the site
    my $announcement_list = $self->_get_or_create_announcement_list($user, $site_id);
    return 0 unless $announcement_list;
    
    # Check if user is subscribed to the announcement list
    my $subscription = $user->mailing_list_subscriptions->find({
        mailing_list_id => $announcement_list->id,
        is_active => 1
    });
    
    return $subscription ? 1 : 0;
}

# Helper method to update user email notifications through mailing list subscription
sub _update_user_email_notifications {
    my ($self, $user, $enable_notifications, $site_id) = @_;
    
    # Find or create the default announcement list for the site
    my $announcement_list = $self->_get_or_create_announcement_list($user, $site_id);
    return unless $announcement_list;
    
    # Find existing subscription
    my $subscription = $user->mailing_list_subscriptions->find({
        mailing_list_id => $announcement_list->id,
    });
    
    if ($enable_notifications) {
        if ($subscription) {
            # Reactivate if exists
            $subscription->update({ is_active => 1 });
        } else {
            # Create new subscription
            $user->mailing_list_subscriptions->create({
                mailing_list_id => $announcement_list->id,
                subscription_source => 'email_notifications',
                is_active => 1,
            });
        }
    } else {
        if ($subscription) {
            # Deactivate subscription
            $subscription->update({ is_active => 0 });
        }
    }
}

# Helper method to get or create the default announcement mailing list for a site
sub _get_or_create_announcement_list {
    my ($self, $user, $site_id) = @_;
    
    # Get site name for the announcement list
    my $site_name = "Site $site_id"; # Default fallback
    
    # Try to get actual site name if available
    # This would need to be implemented based on your site configuration
    
    my $list_name = "$site_name Announcements";
    
    # Find or create the announcement list
    my $schema = $user->result_source->schema;
    my $announcement_list = $schema->resultset('MailingList')->find_or_create({
        site_id => $site_id,
        name => $list_name,
        description => "Default announcement list for $site_name",
        is_software_only => 1,
        is_active => 1,
        created_by => 1, # System created
    });
    
    return $announcement_list;
}

__PACKAGE__->meta->make_immutable;

1;
