package Comserv::Controller::User;
use Moose;
use namespace::autoclean;
use Digest::SHA qw(sha256_hex);  # For hashing passwords
use Data::Dumper;
use Email::Sender::Simple qw(sendmail);
use Email::Simple;
use Email::Simple::Creator;
use Email::Sender::Transport::SMTP;
use Comserv::Util::UserVerification;
use Comserv::Util::EmailNotification;
use Comserv::Util::AdminAuth;
use DateTime;

BEGIN { extends 'Catalyst::Controller'; }
# Apply restrictions to the entire controller
has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has 'user_verification' => (
    is => 'ro',
    default => sub { Comserv::Util::UserVerification->new }
);

has 'email_notification' => (
    is => 'ro',
    lazy => 1,
    default => sub {
        my $self = shift;
        return Comserv::Util::EmailNotification->new(logging => $self->logging);
    },
);

sub send_error_notification {
    my ($self, $c, $subject, $error_details) = @_;
    
    my $sitename = $c->stash->{SiteName} || 'CSC';
    my $site = $c->model('DBEncy')->resultset('Site')->search({ name => $sitename })->single;
    my $admin_email = ($site && $site->mail_to_admin) ? $site->mail_to_admin : 'helpdesk@computersystemconsulting.ca';
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_error_notification',
        "Sending error notification to admin: $admin_email");
    
    eval {
        $self->email_notification->send_error_notification($c, $admin_email, $subject, $error_details);
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'send_error_notification',
            "Failed to send error notification: $@");
    }
}

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

    # Don't store the login or registration pages as the referer
    if ($referer !~ m{/user/login} && $referer !~ m{/login} && $referer !~ m{/do_login} &&
        $referer !~ m{/user/register} && $referer !~ m{/user/do_create_account} &&
        $referer !~ m{/user/verify_email} && $referer !~ m{/user/complete_profile}) {
        $c->session->{referer} = $referer;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'login', "Stored referer in session: $referer");
    } else {
        # Clear session referer if it's a login/registration page, and default to home page
        if (!$c->session->{referer} || 
            $c->session->{referer} =~ m{/user/login} || 
            $c->session->{referer} =~ m{/user/register} ||
            $c->session->{referer} =~ m{/user/do_create_account} ||
            $c->session->{referer} =~ m{/user/verify_email} ||
            $c->session->{referer} =~ m{/user/complete_profile}) {
            $c->session->{referer} = $c->uri_for('/');
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'login', 
                "Cleared registration/login referer, using home page");
        } else {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'login', 
                "Using existing valid session referer: " . $c->session->{referer});
        }
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
    
    # Check if admin access is required (from URL parameter)
    my $admin_required = $c->req->param('admin_required');
    $c->stash->{admin_required} = $admin_required;
    
    # Check if this is coming from an admin area (based on return_to URL)
    my $return_to_admin = ($return_to && $return_to =~ m{/admin/}) || 
                         ($c->session->{referer} && $c->session->{referer} =~ m{/admin/});
    $c->stash->{return_to_admin} = $return_to_admin;
    
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
        # Do not automatically clear session here; allow re-login flow to re-authenticate cleanly
        # If you want to force re-auth, uncomment the next line
        # $c->session({});
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
    my $username          = $c->req->body_parameters->{username}          || $c->req->param('username')          || '';
    my $password          = $c->req->body_parameters->{password}          || $c->req->param('password')          || '';
    my $verification_code = $c->req->body_parameters->{verification_code} || $c->req->param('verification_code') || '';
    $verification_code =~ s/\s+//g;

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

    # Manual authentication to bypass Catalyst auth system issues
    my $user;
    eval {
        # Check if input contains '@' to determine if it's email or username
        if ($username =~ /@/) {
            # Lookup by email
            $user = $c->model('DBEncy::User')->find({ email => $username });
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_login', 
                "Manual user lookup by email for '$username': " . (defined $user ? "found" : "not found"));
        } else {
            # Lookup by username
            $user = $c->model('DBEncy::User')->find({ username => $username });
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_login', 
                "Manual user lookup by username for '$username': " . (defined $user ? "found" : "not found"));
        }
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'do_login',
            "Error during manual user lookup: $@");
        $c->flash->{error_msg} = 'Database error occurred. Please try again later.';
        $c->res->redirect($c->uri_for('/user/login'));
        return;
    }
    
    # Verification code auth path (admin-invited users with pending_setup status)
    if ($verification_code =~ /^\d{6}$/) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_login',
            "Verification code login attempt for '$username'");

        unless ($user) {
            $c->flash->{error_msg} = 'Invalid email or username.';
            $c->res->redirect($c->uri_for('/user/login'));
            return;
        }

        my $code_hash = sha256_hex($verification_code);
        my $code_rec;
        eval {
            $code_rec = $user->verification_codes->search({
                code_hash   => $code_hash,
                verified_at => undef,
            })->first;
        };

        if ($code_rec && !$self->user_verification->is_expired($code_rec)) {
            if ($user->status && $user->status eq 'pending_setup') {
                $c->session->{setup_email} = $user->email;
                my $setup_url = (!$user->username)
                    ? $c->uri_for('/user/complete_username_setup', { email => $user->email })
                    : $c->uri_for('/user/complete_password_setup',  { email => $user->email });
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_login',
                    "Valid code for pending_setup user '" . ($user->email||'') . "', redirecting to setup");
                $c->res->redirect($setup_url);
                return;
            } else {
                $c->flash->{error_msg} = 'Your account is already set up. Please log in with your password.';
                $c->res->redirect($c->uri_for('/user/login'));
                return;
            }
        } else {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_login',
                "Invalid or expired verification code for '$username'");
            $c->flash->{error_msg} = 'Invalid or expired verification code.';
            $c->res->redirect($c->uri_for('/user/login'));
            return;
        }
    }

    # Check if user exists and password is correct
    if ($user && $user->check_password($password)) {
        # Check if account is suspended
        if ($user->status && $user->status eq 'suspended') {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_login',
                "Login attempt for suspended account: '$username'");
            $c->flash->{error_msg} = 'Your account has been suspended. Please contact an administrator.';
            $c->res->redirect($c->uri_for('/user/login'));
            return;
        }
        # Manual authentication successful
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_login', 
            "User '$username' successfully authenticated via manual check.");
        
        # Get the authenticated user object (already retrieved above)
        
        # Store additional session data for backward compatibility
        $c->session->{username} = $user->username;
        $c->session->{user_id}  = $user->id;
        $c->session->{first_name} = $user->first_name if $user->can('first_name');
        $c->session->{last_name}  = $user->last_name if $user->can('last_name');
        $c->session->{email}    = $user->email if $user->can('email');

        # Handle roles - parse string format to array for template compatibility
        my $roles = $user->roles;
        
        # Debug: Log the raw roles from database
        $self->logging->log_with_details(
            $c, 'info', __FILE__, __LINE__, 'do_login',
            "Raw roles from database for user '$username': " . (defined $roles ? "'$roles'" : 'undefined')
        );
        
        if (defined $roles && !ref $roles) {
            # If roles is a string, split by comma and clean up whitespace
            if ($roles =~ /,/) {
                $roles = [ map { s/^\s+|\s+$//g; $_ } split /,/, $roles ];
            } else {
                # Single role as string
                $roles = [ $roles ];
            }
        } elsif (ref $roles eq 'ARRAY') {
            # Already an array, keep as is
            # This branch exists for future compatibility
        } else {
            # Undefined or invalid, default to normal role
            $self->logging->log_with_details(
                $c, 'warn', __FILE__, __LINE__, 'do_login',
                "User '$username' has invalid or missing roles. Defaulting to ['normal']."
            );
            $roles = ['normal'];
        }

        # Log the roles before assigning to session
        my $roles_debug = ref($roles) eq 'ARRAY' ? join(', ', @$roles) : $roles;
        $self->logging->log_with_details(
            $c, 'info', __FILE__, __LINE__, 'do_login',
            "Setting roles in session: $roles_debug"
        );
        
        # Assign roles to session (no hard-coded username-based tweaks)
        $c->session->{roles} = $roles;
        
        # Log the final roles
        $roles_debug = ref($roles) eq 'ARRAY' ? join(', ', @$roles) : $roles;
        $self->logging->log_with_details(
            $c, 'info', __FILE__, __LINE__, 'do_login',
            "Final roles in session: $roles_debug"
        );
    } else {
        # Authentication failed
        $self->logging->log_with_details(
            $c, 'warn', __FILE__, __LINE__, 'do_login',
            "Login failed: Invalid username or password for '$username'."
        );

        # Store error message in flash and redirect back to login page
        $c->flash->{error_msg} = 'Invalid username or password.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

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
    # Normalize and redirect
    if ($redirect_path =~ /^\// && $redirect_path !~ /^https?:\/\//i) {
        $c->res->redirect($c->uri_for($redirect_path));
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_login', "Using uri_for for redirect: " . $c->uri_for($redirect_path));
    } else {
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
    my $username = '';
    if ($c->user_exists) {
        $username = $c->user->username if $c->user->can('username');
    } elsif ($c->session->{username}) {
        $username = $c->session->{username};
    } else {
        $username = 'Guest';
    }

    # Store important site information before clearing the session
    my $site_name = $c->session->{SiteName} || '';
    my $theme_name = $c->session->{theme_name} || '';
    my $controller_name = $c->session->{ControllerName} || '';

    # Log the site information we're preserving
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'logout',
        "Preserving site info: SiteName=$site_name, theme=$theme_name, controller=$controller_name");

    # Logout from Catalyst authentication system
    if ($c->user_exists) {
        $c->logout;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'logout',
            "User logged out from Catalyst auth system");
    }

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
        qr{^/user/create_account}, # Registration page
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

    # Load site roles with role names (with error handling)
    my @site_roles = ();
    eval {
        if ($user->can('user_site_roles')) {
            my $user_site_roles_rs = $user->user_site_roles;
            if ($user_site_roles_rs && ref($user_site_roles_rs)) {
                while (my $usr = $user_site_roles_rs->next) {
                    eval {
                        my $role_name = $usr->role || 'Unknown';
                        my $site_name = 'Unknown';
                        if ($usr->site_id) {
                            my $site = $c->model('DBEncy')->resultset('Site')->find($usr->site_id);
                            $site_name = $site ? $site->name : "site#" . $usr->site_id;
                        }
                        push @site_roles, {
                            sitename  => $site_name,
                            role_name => $role_name,
                        };
                    };
                    if ($@) {
                        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'profile',
                            "Error loading individual site role: $@");
                    }
                }
            }
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'profile',
            "Error loading site roles: $@");
    }

    # Prepare user data for display
    my $user_data = {
        username => $user->username || '',
        first_name => $user->first_name || '',
        last_name => $user->last_name || '',
        email => $user->email || '',
        roles => $c->session->{roles} || [],
        status => $user->status || 'active',
        site_roles => \@site_roles,
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

    # Set template and stash data
    $c->stash(
        user => {
            username => $user->username,
            first_name => $user->first_name,
            last_name => $user->last_name,
            email => $user->email,
            email_notifications => eval { $user->email_notifications } || 0,
        },
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
        my $updates = {
            first_name => $first_name,
            last_name => $last_name,
            email => $email,
        };
        $updates->{email_notifications} = $email_notifications if eval { $user->can('email_notifications') };
        $user->update($updates);
    };

    if ($@) {
        # Log the error
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_settings',
            "Error updating user settings: $@");

        $c->flash->{error_msg} = "An error occurred while updating your settings. Please try again.";
        $c->response->redirect($c->uri_for('/user/settings'));
        return;
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

sub change_password :Local {
    my ($self, $c) = @_;

    # Check if user is logged in
    unless ($c->session->{username}) {
        $c->flash->{error_msg} = "You must be logged in to change your password.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    # Log the page access
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'change_password',
        "User '" . $c->session->{username} . "' accessing change password page");

    # Display the change password form
    $c->stash(template => 'user/change_password.tt');
    $c->forward($c->view('TT'));
}

sub do_change_password :Local {
    my ($self, $c) = @_;

    # Check if user is logged in
    unless ($c->session->{username}) {
        $c->flash->{error_msg} = "You must be logged in to change your password.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    # Log the password change attempt
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_change_password',
        "User '" . $c->session->{username} . "' attempting to change password");

    # Get user data from database
    my $user = $c->model('DBEncy::User')->find({ username => $c->session->{username} });

    unless ($user) {
        $c->flash->{error_msg} = "User not found in database. Please log in again.";
        $c->session({});  # Clear session
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    # Get form data
    my $current_password = $c->req->params->{current_password};
    my $new_password = $c->req->params->{new_password};
    my $new_password_confirm = $c->req->params->{new_password_confirm};

    # Validate input
    unless ($current_password && $new_password && $new_password_confirm) {
        $c->stash(
            error_msg => 'All password fields are required.',
            template => 'user/change_password.tt'
        );
        return;
    }

    # Validate current password
    unless ($user->check_password($current_password)) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_change_password',
            "User '" . $c->session->{username} . "' entered incorrect current password");
        $c->stash(
            error_msg => 'Current password is incorrect.',
            template => 'user/change_password.tt'
        );
        return;
    }

    # Validate new passwords match
    unless ($new_password eq $new_password_confirm) {
        $c->stash(
            error_msg => 'New passwords do not match.',
            template => 'user/change_password.tt'
        );
        return;
    }

    # Validate new password length
    unless (length($new_password) >= 8) {
        $c->stash(
            error_msg => 'New password must be at least 8 characters long.',
            template => 'user/change_password.tt'
        );
        return;
    }

    # Hash new password with SHA256
    my $hashed_password = sha256_hex($new_password);

    # Update user password in database
    eval {
        $user->update({ password => $hashed_password });
    };

    if ($@) {
        # Log the error
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'do_change_password',
            "Error updating password: $@");

        $c->flash->{error_msg} = "An error occurred while changing your password. Please try again.";
        $c->response->redirect($c->uri_for('/user/change_password'));
        return;
    }

    # Log the successful password change
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_change_password',
        "User '" . $c->session->{username} . "' password changed successfully");

    # Set success message and redirect (user remains logged in)
    $c->flash->{success_msg} = "Your password has been changed successfully.";
    $c->response->redirect($c->uri_for('/user/profile'));
    return;
}

sub create_account :Local {
    my ($self, $c) = @_;

    # Redirect to register for backward compatibility
    $c->response->redirect($c->uri_for('/user/register'));
}
sub do_create_account :Local {
    my ($self, $c) = @_;
    
    my $username = $c->request->params->{username} // '';
    my $email    = $c->request->params->{email}    // '';

    $username =~ s/^\s+|\s+$//g;
    $email    =~ s/^\s+|\s+$//g;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_create_account',
        "Step 1 registration attempt for username: $username, email: $email");

    unless ($username && $email) {
        $c->stash(error_msg => 'Username and email are required', template => 'user/register.tt');
        return;
    }

    unless ($username =~ /^[a-zA-Z0-9_]{3,50}$/) {
        $c->stash(error_msg => 'Username must be 3-50 characters and contain only letters, numbers, or underscores.', template => 'user/register.tt');
        return;
    }

    unless ($email =~ /^[a-zA-Z0-9._%+\-]+\@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$/ && length($email) <= 255) {
        $c->stash(error_msg => 'Please enter a valid email address.', template => 'user/register.tt');
        return;
    }

    my $existing_user = $c->model('DBEncy::User')->find({ username => $username });
    if ($existing_user) {
        $c->stash(
            error_msg => 'Username already exists. Please choose another.',
            template => 'user/register.tt'
        );
        return;
    }
    
    # Check if email exists with same username (prevent exact duplicates)
    # Allow same email with different username for multi-site access
    my $existing_email_user = $c->model('DBEncy::User')->find({ 
        email => $email,
        username => $username 
    });
    if ($existing_email_user) {
        $c->stash(
            error_msg => 'An account with this username and email already exists. Please login instead.',
            template => 'user/register.tt'
        );
        return;
    }
    
    my $new_user;
    my $verification_code;
    eval {
        $new_user = $c->model('DBEncy::User')->create({
            username => $username,
            email => $email,
            status => 'pending_verification',
            creation_context => 'self_registration',
            roles => 'normal',
        });
        
        $verification_code = $self->user_verification->generate_verification_code();
        $self->user_verification->create_verification_code($new_user, $verification_code);
        
        # Create UserSiteRole entry for the current site
        eval {
            my $reg_sitename = $c->stash->{SiteName} || 'CSC';
            my $site = $c->model('DBEncy')->resultset('Site')->search({ name => $reg_sitename })->single;
            
            if ($site) {
                $c->model('DBEncy::UserSiteRole')->create({
                    user_id => $new_user->id,
                    site_id => $site->id,
                    role    => 'normal',
                });
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_create_account',
                    "Created UserSiteRole for user " . $new_user->id . " on site $reg_sitename (site_id=" . $site->id . ") with role 'normal'");
            }
        };
        if ($@) {
            # Log the error but don't fail registration
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_create_account',
                "Could not create UserSiteRole (table may not exist): $@");
        }
        
        $c->session->{verification_user_id} = $new_user->id;
        $c->session->{verification_code_display} = $verification_code;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_create_account',
            "User created with ID: " . $new_user->id . ", verification code: $verification_code");
    };
    
    if ($@) {
        my $error = $@;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'do_create_account',
            "Error creating user: $error");
        
        my $error_msg = "An error occurred during registration.";
        if ($error =~ /Duplicate entry.*username_unique/) {
            $error_msg = "This username is already taken. Please choose a different username.";
        }
        
        $c->stash(
            error_msg => $error_msg,
            template => 'user/register.tt'
        );
        
        # Send error notification to admin
        eval {
            $self->send_error_notification($c, "Registration Error", 
                "User attempted registration with username '$username', email '$email'. Error: $error");
        };
        
        return;
    }
    
    # Send verification email to user
    my $email_sent = 0;
    eval {
        $email_sent = $self->email_notification->send_verification_email($c, $new_user, $verification_code);
        if ($email_sent) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_create_account',
                "Verification email sent successfully to: " . $new_user->email);
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'do_create_account',
            "Failed to send verification email: $@");
    }
    $c->session->{email_sent} = $email_sent ? 1 : 0;
    
    # Send notification to admin about successful registration
    eval {
        my $admin_notified = $self->email_notification->send_admin_registration_notification($c, $new_user);
        if ($admin_notified) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_create_account',
                "Admin notification sent for new user: " . $new_user->username);
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'do_create_account',
            "Failed to send admin notification: $@");
    }
    
    $c->response->redirect($c->uri_for('/user/verify_email'));
}

sub verify_email :Local {
    my ($self, $c) = @_;
    
    unless ($c->session->{verification_user_id}) {
        $c->response->redirect($c->uri_for('/user/register'));
        return;
    }
    
    if ($c->request->method eq 'POST') {
        my $code = $c->request->params->{code};
        my $user_id = $c->session->{verification_user_id};
        
        my $user = $c->model('DBEncy::User')->find($user_id);
        unless ($user) {
            $c->stash(
                error_msg => 'User not found. Please start registration again.',
                template => 'user/VerifyEmail.tt'
            );
            return;
        }
        
        my $verified = $self->user_verification->verify_code($user, $code);
        
        if ($verified) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'verify_email',
                "Email verified successfully for user ID: $user_id");
            
            delete $c->session->{verification_code_display};
            $c->response->redirect($c->uri_for('/user/complete_profile'));
        } else {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'verify_email',
                "Invalid or expired verification code for user ID: $user_id");
            
            $c->stash(
                error_msg => 'Invalid or expired verification code. Please try again.',
                template => 'user/VerifyEmail.tt'
            );
        }
    } else {
        $c->stash(template => 'user/VerifyEmail.tt');
    }
}

sub complete_profile :Local {
    my ($self, $c) = @_;
    
    unless ($c->session->{verification_user_id}) {
        $c->response->redirect($c->uri_for('/user/register'));
        return;
    }
    
    my $user_id = $c->session->{verification_user_id};
    my $user = $c->model('DBEncy::User')->find($user_id);
    
    unless ($user) {
        $c->response->redirect($c->uri_for('/user/register'));
        return;
    }
    
    if ($c->request->method eq 'POST') {
        my $first_name = $c->request->params->{first_name};
        my $last_name = $c->request->params->{last_name};
        my $password = $c->request->params->{password};
        my $password_confirm = $c->request->params->{password_confirm};
        
        unless ($first_name && $last_name && $password && $password_confirm) {
            $c->stash(
                error_msg => 'All fields are required',
                template => 'user/CompleteProfile.tt'
            );
            return;
        }
        
        unless ($password eq $password_confirm) {
            $c->stash(
                error_msg => 'Passwords do not match',
                template => 'user/CompleteProfile.tt'
            );
            return;
        }
        
        unless (length($password) >= 8) {
            $c->stash(
                error_msg => 'Password must be at least 8 characters long',
                template => 'user/CompleteProfile.tt'
            );
            return;
        }
        
        my $hashed_password = sha256_hex($password);
        
        eval {
            $user->update({
                first_name        => $first_name,
                last_name         => $last_name,
                password          => $hashed_password,
                status            => 'active',
                roles             => 'normal',
                email_verified_at => DateTime->now->strftime('%Y-%m-%d %H:%M:%S'),
            });
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'complete_profile',
                "Profile completed for user ID: $user_id, status set to active, role set to normal");
        };
        
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'complete_profile',
                "Error completing profile: $@");
            $c->stash(
                error_msg => "An error occurred: $@",
                template => 'user/CompleteProfile.tt'
            );
            return;
        }
        
        delete $c->session->{verification_user_id};
        
        $c->flash->{success_msg} = "Registration complete! You can now log in.";
        $c->response->redirect($c->uri_for('/user/login'));
    } else {
        $c->stash(template => 'user/CompleteProfile.tt');
    }
}

sub admin_create_user :Local {
    my ($self, $c) = @_;
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    
    unless ($admin_auth->check_admin_access($c, 'admin_create_user')) {
        $c->flash->{error_msg} = "Access denied. Admin access required.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin_create_user',
        'Admin accessing user creation form');
    
    my $admin_type = $admin_auth->get_admin_type($c);
    my $is_csc_admin = ($admin_type eq 'csc' || $admin_type eq 'special');
    my $sitename = $c->session->{SiteName};
    my $schema = $c->model('DBEncy');
    
    my @sites;
    if ($is_csc_admin) {
        @sites = $schema->resultset('Site')->search({}, { order_by => 'name' })->all;
    } else {
        my $site = $schema->resultset('Site')->search({ name => $sitename })->single;
        @sites = ($site) if $site;
    }

    my $available_roles = $self->_load_available_roles($c, $is_csc_admin, $sitename);

    if ($c->req->method eq 'POST') {
        my $first_name     = $c->req->params->{first_name};
        my $last_name      = $c->req->params->{last_name};
        my $email          = $c->req->params->{email};
        my $username       = $c->req->params->{username} || undef;
        my @selected_sites = $c->req->param('sitenames');
        my @selected_roles = $c->req->param('roles');

        unless ($first_name && $last_name && $email) {
            $c->stash(
                error_msg       => 'First name, last name, and email are required',
                sites           => \@sites,
                available_roles => $available_roles,
                template        => 'user/admin_create_user.tt',
            );
            return;
        }

        unless (@selected_sites && @selected_roles) {
            $c->stash(
                error_msg       => 'Please select at least one site and one role',
                sites           => \@sites,
                available_roles => $available_roles,
                template        => 'user/admin_create_user.tt',
            );
            return;
        }

        my $existing_email = $schema->resultset('User')->search({ email => $email })->count;
        if ($existing_email) {
            $c->stash(
                error_msg       => 'A user with this email already exists',
                sites           => \@sites,
                available_roles => $available_roles,
                template        => 'user/admin_create_user.tt',
            );
            return;
        }

        if ($username) {
            my $existing_username = $schema->resultset('User')->search({ username => $username })->count;
            if ($existing_username) {
                $c->stash(
                    error_msg       => 'A user with this username already exists',
                    sites           => \@sites,
                    available_roles => $available_roles,
                    template        => 'user/admin_create_user.tt',
                );
                return;
            }
        }

        eval {
            my $user = $schema->resultset('User')->create({
                username         => $username,
                first_name       => $first_name,
                last_name        => $last_name,
                email            => $email,
                status           => 'pending_setup',
                roles            => join(',', @selected_roles),
                created_by       => $c->session->{user_id},
                creation_context => 'admin_created',
                created_at       => DateTime->now->strftime('%Y-%m-%d %H:%M:%S'),
            });

            my $code = $self->user_verification->generate_verification_code();
            $self->user_verification->create_verification_code($user, $code);

            foreach my $site_name (@selected_sites) {
                my $site_obj = $schema->resultset('Site')->search({ name => $site_name })->single;
                next unless $site_obj;
                foreach my $role_name (@selected_roles) {
                    $schema->resultset('UserSiteRole')->create({
                        user_id    => $user->id,
                        site_id    => $site_obj->id,
                        role       => $role_name,
                        granted_by => $c->session->{user_id},
                    });
                }
            }

            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin_create_user',
                "User created by admin: email=$email user_id=" . $user->id
                . " roles=" . join(',', @selected_roles) . " code=$code");

            $c->flash->{success_msg} = "User created successfully. Verification code: $code (would be emailed in production)";
            $c->response->redirect($c->uri_for('/admin/users'));
        };

        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'admin_create_user',
                "Error creating user: $@");
            $c->stash(
                error_msg       => "An error occurred: $@",
                sites           => \@sites,
                available_roles => $available_roles,
                template        => 'user/admin_create_user.tt',
            );
            return;
        }
    } else {
        $c->stash(
            sites           => \@sites,
            available_roles => $available_roles,
            template        => 'user/admin_create_user.tt',
        );
    }
}

sub complete_username_setup :Local {
    my ($self, $c) = @_;
    
    my $email = $c->req->param('email') || $c->session->{setup_email};
    my $code = $c->req->param('code');
    
    unless ($email) {
        $c->flash->{error_msg} = 'Invalid setup link';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    my $user = $c->model('DBEncy::User')->find({ email => $email });
    
    unless ($user && $user->status eq 'pending_setup') {
        $c->flash->{error_msg} = 'Invalid or expired setup link';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    if ($c->req->method eq 'POST') {
        my $input_code = $c->req->params->{code};
        my $username = $c->req->params->{username};
        my $first_name = $c->req->params->{first_name};
        my $last_name = $c->req->params->{last_name};
        my $password = $c->req->params->{password};
        my $password_confirm = $c->req->params->{password_confirm};
        
        unless ($input_code && $username && $first_name && $last_name && $password && $password_confirm) {
            $c->stash(
                user => $user,
                error_msg => 'All fields are required',
                template => 'user/complete_username_setup.tt'
            );
            return;
        }
        
        my $verification = $self->user_verification->verify_code($user, $input_code);
        unless ($verification) {
            $c->stash(
                user => $user,
                error_msg => 'Invalid or expired verification code',
                template => 'user/complete_username_setup.tt'
            );
            return;
        }
        
        my $existing = $c->model('DBEncy::User')->find({ username => $username });
        if ($existing) {
            $c->stash(
                user => $user,
                error_msg => 'Username already taken',
                template => 'user/complete_username_setup.tt'
            );
            return;
        }
        
        unless ($password eq $password_confirm) {
            $c->stash(
                user => $user,
                error_msg => 'Passwords do not match',
                template => 'user/complete_username_setup.tt'
            );
            return;
        }
        
        unless (length($password) >= 8) {
            $c->stash(
                user => $user,
                error_msg => 'Password must be at least 8 characters long',
                template => 'user/complete_username_setup.tt'
            );
            return;
        }
        
        eval {
            $user->update({
                username => $username,
                first_name => $first_name,
                last_name => $last_name,
                password => sha256_hex($password),
                status => 'active',
                email_verified_at => DateTime->now->strftime('%Y-%m-%d %H:%M:%S'),
            });
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'complete_username_setup',
                "Setup completed for user: $username (email=$email)");
        };
        
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'complete_username_setup',
                "Error completing setup: $@");
            $c->stash(
                user => $user,
                error_msg => "An error occurred: $@",
                template => 'user/complete_username_setup.tt'
            );
            return;
        }
        
        delete $c->session->{setup_email};
        
        $c->flash->{success_msg} = "Account setup complete! You can now log in.";
        $c->response->redirect($c->uri_for('/user/login'));
    } else {
        $c->session->{setup_email} = $email;
        $c->stash(
            user => $user,
            template => 'user/complete_username_setup.tt'
        );
    }
}

sub complete_password_setup :Local {
    my ($self, $c) = @_;
    
    my $email = $c->req->param('email') || $c->session->{setup_email};
    
    unless ($email) {
        $c->flash->{error_msg} = 'Invalid setup link';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    my $user = $c->model('DBEncy::User')->find({ email => $email });
    
    unless ($user && $user->status eq 'pending_setup' && $user->username) {
        $c->flash->{error_msg} = 'Invalid or expired setup link';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    if ($c->req->method eq 'POST') {
        my $input_code = $c->req->params->{code};
        my $password = $c->req->params->{password};
        my $password_confirm = $c->req->params->{password_confirm};
        
        unless ($input_code && $password && $password_confirm) {
            $c->stash(
                user => $user,
                error_msg => 'All fields are required',
                template => 'user/complete_password_setup.tt'
            );
            return;
        }
        
        my $verification = $self->user_verification->verify_code($user, $input_code);
        unless ($verification) {
            $c->stash(
                user => $user,
                error_msg => 'Invalid or expired verification code',
                template => 'user/complete_password_setup.tt'
            );
            return;
        }
        
        unless ($password eq $password_confirm) {
            $c->stash(
                user => $user,
                error_msg => 'Passwords do not match',
                template => 'user/complete_password_setup.tt'
            );
            return;
        }
        
        unless (length($password) >= 8) {
            $c->stash(
                user => $user,
                error_msg => 'Password must be at least 8 characters long',
                template => 'user/complete_password_setup.tt'
            );
            return;
        }
        
        eval {
            $user->update({
                password => sha256_hex($password),
                status => 'active',
                email_verified_at => DateTime->now->strftime('%Y-%m-%d %H:%M:%S'),
            });
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'complete_password_setup',
                "Password setup completed for user: " . $user->username);
        };
        
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'complete_password_setup',
                "Error completing password setup: $@");
            $c->stash(
                user => $user,
                error_msg => "An error occurred: $@",
                template => 'user/complete_password_setup.tt'
            );
            return;
        }
        
        delete $c->session->{setup_email};
        
        $c->flash->{success_msg} = "Account setup complete! You can now log in.";
        $c->response->redirect($c->uri_for('/user/login'));
    } else {
        $c->session->{setup_email} = $email;
        $c->stash(
            user => $user,
            template => 'user/complete_password_setup.tt'
        );
    }
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

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'edit_user')) {
        $c->flash->{error_msg} = 'Access denied. Admin access required.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    my $user_id = $c->request->arguments->[0];
    my $schema  = $c->model('DBEncy');
    my $user    = $schema->resultset('User')->find($user_id);

    unless ($user) {
        $c->flash->{error_msg} = 'User not found.';
        $c->response->redirect($c->uri_for('/admin/users'));
        return;
    }

    my $admin_type   = $admin_auth->get_admin_type($c);
    my $is_csc_admin = ($admin_type eq 'csc' || $admin_type eq 'special');
    my $sitename     = $c->session->{SiteName};

    unless ($is_csc_admin) {
        my $site_obj = $schema->resultset('Site')->search({ name => $sitename })->single;
        if ($site_obj) {
            my $access = $schema->resultset('UserSiteRole')->search({
                user_id => $user_id,
                site_id => $site_obj->id,
            })->count;
            unless ($access) {
                $c->flash->{error_msg} = 'Access denied. You can only edit users in your site.';
                $c->response->redirect($c->uri_for('/admin/users'));
                return;
            }
        }
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_user',
        "Admin editing user_id=$user_id");

    my $available_roles = $self->_load_available_roles($c, $is_csc_admin, $sitename);

    my @all_sites;
    my %user_site_ids;
    eval {
        @all_sites = $is_csc_admin
            ? $schema->resultset('Site')->search({}, { order_by => 'name' })->all
            : $schema->resultset('Site')->search({ name => $sitename }, { order_by => 'name' })->all;

        my @usr = $schema->resultset('UserSiteRole')->search(
            { user_id => $user_id },
            { columns => ['site_id'], distinct => 1 }
        )->all;
        for my $sr (@usr) {
            $user_site_ids{$sr->site_id} = 1 if defined $sr->site_id;
        }
    };

    $c->stash(
        user            => $user,
        available_roles => $available_roles,
        is_csc_admin    => $is_csc_admin,
        all_sites       => \@all_sites,
        user_site_ids   => \%user_site_ids,
        template        => 'user/edit_user.tt',
    );
}

sub do_edit_user :Local :Args(1) {
    my ($self, $c) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'do_edit_user')) {
        $c->flash->{error_msg} = 'Access denied. Admin access required.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    my $user_id  = $c->request->arguments->[0];
    my $schema   = $c->model('DBEncy');
    my $user     = $schema->resultset('User')->find($user_id);

    unless ($user) {
        $c->flash->{error_msg} = 'User not found.';
        $c->response->redirect($c->uri_for('/admin/users'));
        return;
    }

    my $admin_type   = $admin_auth->get_admin_type($c);
    my $is_csc_admin = ($admin_type eq 'csc' || $admin_type eq 'special');
    my $sitename     = $c->session->{SiteName};

    unless ($is_csc_admin) {
        my $site_obj = $schema->resultset('Site')->search({ name => $sitename })->single;
        if ($site_obj) {
            my $access = $schema->resultset('UserSiteRole')->search({
                user_id => $user_id,
                site_id => $site_obj->id,
            })->count;
            unless ($access) {
                $c->flash->{error_msg} = 'Access denied. You can only edit users in your site.';
                $c->response->redirect($c->uri_for('/admin/users'));
                return;
            }
        }
    }

    my $available_roles = $self->_load_available_roles($c, $is_csc_admin, $sitename);

    my @all_sites;
    my %user_site_ids;
    eval {
        @all_sites = $is_csc_admin
            ? $schema->resultset('Site')->search({}, { order_by => 'name' })->all
            : $schema->resultset('Site')->search({ name => $sitename }, { order_by => 'name' })->all;

        my @usr = $schema->resultset('UserSiteRole')->search(
            { user_id => $user_id },
            { columns => ['site_id'], distinct => 1 }
        )->all;
        for my $sr (@usr) {
            $user_site_ids{$sr->site_id} = 1 if defined $sr->site_id;
        }
    };

    my $username   = $c->req->params->{username} || undef;
    my $first_name = $c->req->params->{first_name};
    my $last_name  = $c->req->params->{last_name};
    my $email      = $c->req->params->{email};
    my @roles_arr  = $c->req->param('roles');
    my $roles_str  = join(',', @roles_arr);
    my $status     = $c->req->params->{status};
    my @new_site_names = $c->req->param('sitenames');

    unless ($email) {
        $c->stash(
            user            => $user,
            available_roles => $available_roles,
            is_csc_admin    => $is_csc_admin,
            all_sites       => \@all_sites,
            user_site_ids   => \%user_site_ids,
            error_msg       => 'Email is required.',
            template        => 'user/edit_user.tt',
        );
        return;
    }

    if ($username && $username ne ($user->username || '')) {
        my $existing = $schema->resultset('User')->search({
            username => $username,
            id       => { '!=' => $user_id },
        })->count;
        if ($existing) {
            $c->stash(
                user            => $user,
                available_roles => $available_roles,
                is_csc_admin    => $is_csc_admin,
                all_sites       => \@all_sites,
                user_site_ids   => \%user_site_ids,
                error_msg       => "Username '$username' is already taken.",
                template        => 'user/edit_user.tt',
            );
            return;
        }
    }

    if ($email ne ($user->email // '')) {
        my $existing = $schema->resultset('User')->search({
            email => $email,
            id    => { '!=' => $user_id },
        })->count;
        if ($existing) {
            $c->stash(
                user            => $user,
                available_roles => $available_roles,
                is_csc_admin    => $is_csc_admin,
                all_sites       => \@all_sites,
                user_site_ids   => \%user_site_ids,
                error_msg       => "Email '$email' is already in use.",
                template        => 'user/edit_user.tt',
            );
            return;
        }
    }

    eval {
        $user->update({
            username   => $username,
            first_name => $first_name,
            last_name  => $last_name,
            email      => $email,
            roles      => $roles_str,
            status     => $status,
        });

        my %allowed_site_ids;
        for my $s (@all_sites) {
            $allowed_site_ids{$s->id} = $s->name;
        }

        my %new_site_ids_wanted;
        for my $sn (@new_site_names) {
            my $s = $schema->resultset('Site')->search({ name => $sn })->single;
            if ($s && exists $allowed_site_ids{$s->id}) {
                $new_site_ids_wanted{$s->id} = 1;
            }
        }

        my @current_sr = $schema->resultset('UserSiteRole')->search(
            { user_id => $user_id, site_id => { -in => [keys %allowed_site_ids] } }
        )->all;
        my %current_site_ids;
        for my $sr (@current_sr) {
            $current_site_ids{$sr->site_id} = 1 if defined $sr->site_id;
        }

        for my $sid (keys %current_site_ids) {
            unless (exists $new_site_ids_wanted{$sid}) {
                $schema->resultset('UserSiteRole')->search({
                    user_id => $user_id,
                    site_id => $sid,
                })->delete;
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_edit_user',
                    "Removed site_id=$sid from user_id=$user_id");
            }
        }

        my $admin_uid  = $c->session->{user_id};
        for my $sid (keys %new_site_ids_wanted) {
            unless (exists $current_site_ids{$sid}) {
                for my $role (@roles_arr ? @roles_arr : ('normal')) {
                    eval {
                        $schema->resultset('UserSiteRole')->create({
                            user_id    => $user_id,
                            site_id    => $sid,
                            role       => $role,
                            granted_by => $admin_uid,
                        });
                    };
                }
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_edit_user',
                    "Added site_id=$sid to user_id=$user_id with roles=$roles_str");
            }
        }
    };

    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'do_edit_user',
            "Error updating user_id=$user_id: $@");
        $c->stash(
            user            => $user,
            available_roles => $available_roles,
            is_csc_admin    => $is_csc_admin,
            all_sites       => \@all_sites,
            user_site_ids   => \%user_site_ids,
            error_msg       => "An error occurred while saving changes: $@",
            template        => 'user/edit_user.tt',
        );
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_edit_user',
        "User updated by admin: user_id=$user_id email=$email roles=$roles_str status=$status sites=" . join(',', @new_site_names));

    $c->flash->{success_msg} = 'User updated successfully.';
    $c->response->redirect($c->uri_for('/admin/users'));
}

sub admin_suspend_user :Local :Args(1) {
    my ($self, $c, $user_id) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'admin_suspend_user')) {
        $c->flash->{error_msg} = 'Access denied. Admin access required.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    my $schema = $c->model('DBEncy');
    my $user   = $schema->resultset('User')->find($user_id);

    unless ($user) {
        $c->flash->{error_msg} = 'User not found.';
        $c->response->redirect($c->uri_for('/admin/users'));
        return;
    }

    my $admin_type   = $admin_auth->get_admin_type($c);
    my $is_csc_admin = ($admin_type eq 'csc' || $admin_type eq 'special');
    my $sitename     = $c->session->{SiteName};

    unless ($is_csc_admin) {
        my $site_obj = $schema->resultset('Site')->search({ name => $sitename })->single;
        if ($site_obj) {
            my $access = $schema->resultset('UserSiteRole')->search({
                user_id => $user_id,
                site_id => $site_obj->id,
            })->count;
            unless ($access) {
                $c->flash->{error_msg} = 'Access denied. You can only manage users in your site.';
                $c->response->redirect($c->uri_for('/admin/users'));
                return;
            }
        }
    }

    my $admin_uid = $c->session->{user_id};

    eval {
        $user->update({ status => 'suspended' });
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'admin_suspend_user',
            "Error suspending user_id=$user_id: $@");
        $c->flash->{error_msg} = 'An error occurred while suspending the account.';
        $c->response->redirect($c->uri_for('/admin/users'));
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin_suspend_user',
        "User suspended: user_id=$user_id by admin_id=$admin_uid sitename=$sitename");

    $c->flash->{success_msg} = 'User account suspended successfully.';
    $c->response->redirect($c->uri_for('/admin/users'));
}

sub admin_activate_user :Local :Args(1) {
    my ($self, $c, $user_id) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'admin_activate_user')) {
        $c->flash->{error_msg} = 'Access denied. Admin access required.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    my $schema = $c->model('DBEncy');
    my $user   = $schema->resultset('User')->find($user_id);

    unless ($user) {
        $c->flash->{error_msg} = 'User not found.';
        $c->response->redirect($c->uri_for('/admin/users'));
        return;
    }

    my $admin_type   = $admin_auth->get_admin_type($c);
    my $is_csc_admin = ($admin_type eq 'csc' || $admin_type eq 'special');
    my $sitename     = $c->session->{SiteName};

    unless ($is_csc_admin) {
        my $site_obj = $schema->resultset('Site')->search({ name => $sitename })->single;
        if ($site_obj) {
            my $access = $schema->resultset('UserSiteRole')->search({
                user_id => $user_id,
                site_id => $site_obj->id,
            })->count;
            unless ($access) {
                $c->flash->{error_msg} = 'Access denied. You can only manage users in your site.';
                $c->response->redirect($c->uri_for('/admin/users'));
                return;
            }
        }
    }

    my $admin_uid = $c->session->{user_id};

    eval {
        $user->update({ status => 'active' });
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'admin_activate_user',
            "Error activating user_id=$user_id: $@");
        $c->flash->{error_msg} = 'An error occurred while activating the account.';
        $c->response->redirect($c->uri_for('/admin/users'));
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin_activate_user',
        "User activated: user_id=$user_id by admin_id=$admin_uid sitename=$sitename");

    $c->flash->{success_msg} = 'User account activated successfully.';
    $c->response->redirect($c->uri_for('/admin/users'));
}

sub admin_delete_user :Local :Args(1) {
    my ($self, $c, $user_id) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'admin_delete_user')) {
        $c->flash->{error_msg} = 'Access denied. Admin access required.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    my $schema = $c->model('DBEncy');
    my $user   = $schema->resultset('User')->find($user_id);

    unless ($user) {
        $c->flash->{error_msg} = 'User not found.';
        $c->response->redirect($c->uri_for('/admin/users'));
        return;
    }

    my $admin_type   = $admin_auth->get_admin_type($c);
    my $is_csc_admin = ($admin_type eq 'csc' || $admin_type eq 'special');
    my $sitename     = $c->session->{SiteName};
    my $admin_uid    = $c->session->{user_id};

    if ($user_id == $admin_uid) {
        $c->flash->{error_msg} = 'You cannot delete your own account.';
        $c->response->redirect($c->uri_for('/admin/users'));
        return;
    }

    unless ($is_csc_admin) {
        my $site_obj = $schema->resultset('Site')->search({ name => $sitename })->single;
        if ($site_obj) {
            my $access = $schema->resultset('UserSiteRole')->search({
                user_id => $user_id,
                site_id => $site_obj->id,
            })->count;
            unless ($access) {
                $c->flash->{error_msg} = 'Access denied. You can only delete users in your site.';
                $c->response->redirect($c->uri_for('/admin/users'));
                return;
            }
        }
    }

    my $deleted_username = $user->username // $user->email // "id=$user_id";

    eval {
        $schema->resultset('UserSiteRole')->search({ user_id => $user_id })->delete;
        $schema->resultset('EmailVerificationCode')->search({ user_id => $user_id })->delete;
        $schema->resultset('PasswordResetToken')->search({ user_id => $user_id })->delete;
        $user->delete;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'admin_delete_user',
            "Error deleting user_id=$user_id: $@");
        $c->flash->{error_msg} = 'An error occurred while deleting the account.';
        $c->response->redirect($c->uri_for('/admin/users'));
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin_delete_user',
        "User deleted: username=$deleted_username user_id=$user_id by admin_id=$admin_uid");

    $c->flash->{success_msg} = "User '$deleted_username' deleted successfully.";
    $c->response->redirect($c->uri_for('/admin/users'));
}

sub register :Local {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'register',
        'Displaying registration form (Step 1)');
    
    $c->stash(template => 'user/register.tt');
}
sub welcome :Local {
    my ($self, $c) = @_;

    # Display the welcome page
    $c->stash(template => 'user/welcome.tt');
    $c->forward($c->view('TT'));
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
            # Generate a 32-char hex reset token
            my $token = $self->user_verification->generate_reset_token();
            
            # Store hashed token in database (expires in 24 hours)
            eval {
                my $reset_record = $self->user_verification->create_reset_token($user, $token);
                
                # Build reset link
                my $reset_link = $c->uri_for('/user/reset_password', { token => $token });
                
                $self->logging->log_with_details(
                    $c, 'info', __FILE__, __LINE__, 'forgot_password',
                    "Password reset token generated for email: $email. Reset link: $reset_link"
                );
                
                # TODO: Send reset email with $reset_link
                # For now, store the token in session for testing
                $c->session->{reset_token} = $token;
                $c->session->{reset_email} = $email;
            };
            
            if ($@) {
                $self->logging->log_with_details(
                    $c, 'error', __FILE__, __LINE__, 'forgot_password',
                    "Error generating reset token for email $email: $@"
                );
            }
        } else {
            # Don't reveal that the email doesn't exist (security best practice)
            $self->logging->log_with_details(
                $c, 'info', __FILE__, __LINE__, 'forgot_password',
                "Password reset requested for non-existent email: $email"
            );
        }
        
        # Always show generic success message (security)
        $c->stash(success_msg => 'If an account exists with that email, password reset instructions have been sent.');
    }

    # Display the forgot password form
    $c->stash(template => 'user/forgot_password.tt');
}

sub reset_password :Local {
    my ($self, $c) = @_;

    # Get token from URL parameter
    my $token = $c->req->param('token');

    # Log access to reset password page
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'reset_password', 
        "Accessing reset password page with token: " . ($token ? 'present' : 'missing'));

    if ($c->req->method eq 'POST') {
        # Process the password reset form
        my $new_password = $c->req->param('new_password');
        my $password_confirm = $c->req->param('password_confirm');

        # Validate inputs
        if (!$token) {
            $c->stash(error_msg => 'Invalid or missing reset token');
            $c->stash(template => 'user/reset_password.tt');
            return;
        }

        if (!$new_password || !$password_confirm) {
            $c->stash(
                error_msg => 'Please enter and confirm your new password',
                template => 'user/reset_password.tt',
                token => $token
            );
            return;
        }

        # Validate passwords match
        if ($new_password ne $password_confirm) {
            $c->stash(
                error_msg => 'Passwords do not match',
                template => 'user/reset_password.tt',
                token => $token
            );
            return;
        }

        # Validate password length
        if (length($new_password) < 8) {
            $c->stash(
                error_msg => 'Password must be at least 8 characters long',
                template => 'user/reset_password.tt',
                token => $token
            );
            return;
        }

        # Verify the reset token
        my $reset_record = $self->user_verification->verify_reset_token($c->model('DBEncy')->schema, $token);

        if (!$reset_record) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'reset_password',
                "Invalid or expired reset token");
            $c->stash(
                error_msg => 'Invalid or expired reset token. Please request a new password reset.',
                template => 'user/reset_password.tt'
            );
            return;
        }

        # Get the user
        my $user = $c->model('DBEncy::User')->find({ id => $reset_record->user_id });

        if (!$user) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'reset_password',
                "User not found for reset token");
            $c->stash(
                error_msg => 'User account not found',
                template => 'user/reset_password.tt'
            );
            return;
        }

        # Hash the new password
        my $password_hash = sha256_hex($new_password);

        # Update user password
        eval {
            $user->update({ password => $password_hash });
            
            # Mark token as used
            $reset_record->update({ used_at => DateTime->now->strftime('%Y-%m-%d %H:%M:%S') });
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'reset_password',
                "Password successfully reset for user: " . $user->username);
        };

        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'reset_password',
                "Error resetting password: $@");
            $c->stash(
                error_msg => 'An error occurred while resetting your password. Please try again.',
                template => 'user/reset_password.tt',
                token => $token
            );
            return;
        }

        # Clear session data
        delete $c->session->{reset_token};
        delete $c->session->{reset_email};

        # Redirect to login with success message
        $c->flash->{success_msg} = 'Your password has been successfully reset. You can now login with your new password.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    # Validate token for GET request
    if ($token) {
        my $reset_record = $self->user_verification->verify_reset_token($c->model('DBEncy')->schema, $token);
        
        if (!$reset_record) {
            $c->stash(
                error_msg => 'Invalid or expired reset token. Please request a new password reset.',
                template => 'user/reset_password.tt'
            );
            return;
        }
    } else {
        $c->stash(
            error_msg => 'No reset token provided. Please use the link from your email.',
            template => 'user/reset_password.tt'
        );
        return;
    }

    # Display the reset password form
    $c->stash(
        template => 'user/reset_password.tt',
        token => $token
    );
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

sub _load_available_roles {
    my ($self, $c, $is_csc_admin, $sitename) = @_;

    my @default_roles = qw(normal member editor developer admin);

    my @site_specific;
    eval {
        my $schema = $c->model('DBEncy');
        my $rs;
        if ($is_csc_admin) {
            $rs = $schema->resultset('SiteRole')->search(
                {},
                { order_by => ['sitename', 'role_name'] }
            );
        } else {
            $rs = $schema->resultset('SiteRole')->search(
                { sitename => $sitename },
                { order_by => 'role_name' }
            );
        }
        my %default_set = map { $_ => 1 } @default_roles;
        while (my $sr = $rs->next) {
            next if $default_set{ $sr->role_name };
            push @site_specific, {
                name     => $sr->role_name,
                sitename => $sr->sitename,
            };
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_load_available_roles',
            "Could not load site_roles (table may not exist): $@");
    }

    return {
        default_roles => \@default_roles,
        site_roles    => \@site_specific,
    };
}

__PACKAGE__->meta->make_immutable;

1;
