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

sub auto :Private {
    my ($self, $c) = @_;
    return 1;
}

sub login :Local {
    my ($self, $c) = @_;

    # Log login page access
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'login', 'Accessing login page');

    # Determine the page to return to after login.
    # Priority: return_to param > destination param (used by Admin.pm) > HTTP Referer
    my $return_to = $c->req->param('return_to')
                 || $c->req->param('destination')
                 || $c->req->referer
                 || $c->uri_for('/');
    my $referer = $return_to;

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
    # Get user input — password field also accepts a 6-digit verification code
    my $username   = $c->req->body_parameters->{username} || $c->req->param('username') || '';
    my $credential = $c->req->body_parameters->{password} || $c->req->param('password') || '';
    $credential =~ s/\s+//g;

    # Determine whether the credential is a 6-digit verification code or a password
    my $password          = ($credential =~ /^\d{6}$/) ? '' : $credential;
    my $verification_code = ($credential =~ /^\d{6}$/) ? $credential : '';

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
            my $status = $user->status || '';

            if ($status eq 'pending_setup') {
                # Admin-invited user — redirect to username/password setup
                $c->session->{setup_email} = $user->email;
                my $setup_url = (!$user->username)
                    ? $c->uri_for('/user/complete_username_setup', { email => $user->email })
                    : $c->uri_for('/user/complete_password_setup',  { email => $user->email });
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_login',
                    "Valid code for pending_setup user '" . ($user->email||'') . "', redirecting to setup");
                $c->res->redirect($setup_url);
                return;

            } elsif ($status eq 'pending_verification') {
                # Self-registered user entering verification code at login screen
                # (e.g. session expired between steps 1 and 2)
                # Re-establish session context and redirect to complete_profile
                $c->session->{verification_user_id} = $user->id;
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_login',
                    "Valid code for pending_verification user '" . ($user->email||'') . "', redirecting to complete_profile");
                $c->res->redirect($c->uri_for('/user/complete_profile'));
                return;

            } else {
                $c->flash->{error_msg} = 'Your account is already active. Please log in with your password.';
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
            my $susp_ip = $c->req->address || 'unknown';
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_login',
                "AUDIT: Login denied user_id=" . $user->id . " username='$username' ip=$susp_ip reason=account_suspended");
            $c->flash->{error_msg} = 'Your account has been suspended. Please contact an administrator.';
            $c->res->redirect($c->uri_for('/user/login'));
            return;
        }
        # Manual authentication successful
        my $client_ip = $c->req->address || 'unknown';
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_login', 
            "AUDIT: Login success user_id=" . $user->id . " username='$username' ip=$client_ip");

        # Auto-activate pre-existing accounts that lack a status (created before the status column)
        # or accounts stuck in pending_verification that somehow still have a correct password
        my $acct_status = $user->status || '';
        if ($acct_status eq '' || $acct_status eq 'pending_verification') {
            eval {
                my $now_str = DateTime->now->strftime('%Y-%m-%d %H:%M:%S');
                $user->update({
                    status => 'active',
                    email_verified_at => $now_str,
                });
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_login',
                    "Auto-activated account user_id=" . $user->id . " (was: '" . ($acct_status||'NULL') . "')");
            };
            if ($@) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_login',
                    "Could not auto-activate account: $@");
            }
        }

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
        $c->session->{roles}    = $roles;
        $c->session->{is_admin} = (grep { lc($_) eq 'admin' } @$roles) ? 1 : 0;

        # NEW: Check if we need to auto-assign WorkshopLeader role based on return_to
        if ($return_to && $return_to =~ m{/workshop/add}) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_login',
                "Detected workshop add redirect, ensuring workshop_leader role for user '" . ($user->username||'') . "'");
            
            my @current_roles = @$roles;
            unless (grep { $_ eq 'workshop_leader' } @current_roles) {
                push @current_roles, 'workshop_leader';
                my $roles_str = join(',', @current_roles);
                eval {
                    $user->update({ roles => $roles_str });
                    $c->session->{roles} = \@current_roles;
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_login',
                        "Auto-assigned workshop_leader role to user '" . ($user->username||'') . "'");
                };
                if ($@) {
                    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'do_login',
                        "Failed to auto-assign workshop_leader role: $@");
                }
            }
        }
        
        # Log the final roles
        $roles_debug = ref($roles) eq 'ARRAY' ? join(', ', @$roles) : $roles;
        $self->logging->log_with_details(
            $c, 'info', __FILE__, __LINE__, 'do_login',
            "Final roles in session: $roles_debug"
        );
    } else {
        # Authentication failed — determine the specific reason for better UX
        my $fail_ip  = $c->req->address || 'unknown';
        my $sitename = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
        my $fail_msg = 'Invalid username or password.';

        if ($user) {
            # User account exists — check specific status and site access

            if ($user->status && $user->status eq 'pending_verification') {
                $fail_msg = 'Your registration is not yet complete. Enter your 6-digit verification code (from your confirmation email) in the password field above to continue setting up your account.';
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_login',
                    "AUDIT: Login denied user_id=" . $user->id . " ip=$fail_ip reason=pending_verification");

            } elsif ($user->status && $user->status eq 'pending_setup') {
                $fail_msg = 'Your account setup is incomplete. Please check your invitation email for the 6-digit code and enter it in the password field above to finish setting up your account.';
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_login',
                    "AUDIT: Login denied user_id=" . $user->id . " ip=$fail_ip reason=pending_setup");

            } else {
                # Active account — check if they have access to the current SiteName
                my $has_site_access = 0;
                eval {
                    my $site = $c->model('DBEncy')->resultset('Site')->search({ name => $sitename })->single;
                    if ($site) {
                        $has_site_access = $c->model('DBEncy')->resultset('UserSiteRole')->search({
                            user_id => $user->id,
                            site_id => $site->id,
                        })->count;
                    } else {
                        $has_site_access = 1;
                    }
                };

                if (!$has_site_access) {
                    $fail_msg = "You do not currently have access to $sitename. Please contact the site administrator to request access.";
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_login',
                        "AUDIT: Login denied user_id=" . $user->id . " username='" . ($user->username||'') . "' ip=$fail_ip reason=no_site_access sitename=$sitename");

                    # Notify the SiteName admin about this access attempt
                    eval {
                        my $site_obj = $c->model('DBEncy')->resultset('Site')->search({ name => $sitename })->single;
                        my $admin_email = ($site_obj && $site_obj->mail_to_admin)
                            ? $site_obj->mail_to_admin
                            : 'helpdesk@computersystemconsulting.ca';
                        my $display_name = ($user->first_name || '') . ' ' . ($user->last_name || '');
                        $display_name =~ s/^\s+|\s+$//g;
                        $display_name ||= $user->username || $user->email || 'unknown';
                        $self->email_notification->send_error_notification($c, $admin_email,
                            "Login attempt — no $sitename access",
                            "A registered user attempted to log in to $sitename but does not have site access.\n\n"
                            . "User: $display_name\n"
                            . "Email: " . ($user->email || 'N/A') . "\n"
                            . "Username: " . ($user->username || 'N/A') . "\n"
                            . "IP Address: $fail_ip\n\n"
                            . "If this person should have access, grant it via the Admin User Management screen."
                        );
                    };
                    if ($@) {
                        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_login',
                            "Could not send no-site-access notification to admin: $@");
                    }
                } else {
                    # Has site access but wrong password
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_login',
                        "AUDIT: Login failed user_id=" . $user->id . " ip=$fail_ip reason=wrong_password sitename=$sitename");
                    # Generic message — don't reveal that the user exists
                    $fail_msg = 'Invalid username or password.';
                }
            }
        } else {
            # User not found at all
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_login',
                "AUDIT: Login failed username='$username' ip=$fail_ip reason=user_not_found");
            # Generic message — don't reveal whether the user exists
            $fail_msg = 'Invalid username or password.';
        }

        $c->stash(
            error_msg        => $fail_msg,
            prefill_username => $username,
            template         => 'user/login.tt',
        );
        $c->forward($c->view('TT'));
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

    my $settings_ip = $c->req->address || 'unknown';
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_settings',
        "AUDIT: Profile updated user_id=" . ($c->session->{user_id} || 'unknown') . " username='" . $c->session->{username} . "' ip=$settings_ip changes=first_name,last_name,email");

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

    my $chpw_ip = $c->req->address || 'unknown';
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_change_password',
        "AUDIT: Password changed user_id=" . ($c->session->{user_id} || 'unknown') . " username='" . $c->session->{username} . "' ip=$chpw_ip");

    eval {
        my $forgot_password_url = $c->uri_for('/user/forgot_password');
        $self->email_notification->send_password_changed_email($c, $user, $forgot_password_url);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_change_password',
            "Password changed notification sent to: " . $user->email);
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_change_password',
            "Failed to send password changed email: $@");
    }

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
    
    # Email must be globally unique — one account per person.
    # The same account can belong to multiple SiteNames via UserSiteRole.
    my $existing_email_user = $c->model('DBEncy::User')->find({ email => $email });
    if ($existing_email_user) {
        $c->stash(
            error_msg => 'An account with this email address already exists. Please log in, or ask your site administrator to grant you access to this site.',
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
        
        eval {
            my $acct = $c->model('DBEncy')->resultset('InternalCurrencyAccount')->find_or_create(
                { user_id => $new_user->id },
                { key => 'primary' }
            );
            my $welcome_coins = 100;
            $acct->update({
                balance        => ($acct->balance || 0) + $welcome_coins,
                lifetime_earned => ($acct->lifetime_earned || 0) + $welcome_coins,
            });
            $c->model('DBEncy')->resultset('InternalCurrencyTransaction')->create({
                to_user_id       => $new_user->id,
                from_user_id     => undef,
                amount           => $welcome_coins,
                transaction_type => 'earn',
                balance_after    => ($acct->balance || 0),
                description      => 'Welcome bonus — new account',
                reference_type   => 'signup',
            });
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_create_account',
                "Granted $welcome_coins welcome coins to user_id=" . $new_user->id);
        };
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_create_account',
                "Could not grant welcome coins (table may not exist yet): $@");
        }

        delete $c->session->{$_} for qw(
            username user_id roles first_name last_name email
            group_membership group_name SiteName theme_name debug_mode
        );
        $c->session->{verification_user_id} = $new_user->id;
        $c->session->{verification_code_display} = $verification_code;
        
        my $reg_ip = $c->req->address || 'unknown';
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_create_account',
            "AUDIT: Account created user_id=" . $new_user->id . " username='$username' email='$email' ip=$reg_ip context=self_registration");
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
            my $verify_ip = $c->req->address || 'unknown';
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'verify_email',
                "AUDIT: Email verified user_id=$user_id ip=$verify_ip");
            
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
            my $roles_to_assign = 'normal';
            my $session_return_to = $c->session->{return_to};
            
            if ($session_return_to && $session_return_to =~ m{/workshop/add}) {
                $roles_to_assign = 'normal,workshop_leader';
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'complete_profile',
                    "Auto-assigning workshop_leader role due to return_to: $session_return_to");
            }

            $user->update({
                first_name        => $first_name,
                last_name         => $last_name,
                password          => $hashed_password,
                status            => 'active',
                roles             => $roles_to_assign,
                email_verified_at => DateTime->now->strftime('%Y-%m-%d %H:%M:%S'),
            });
            
            my $profile_ip = $c->req->address || 'unknown';
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'complete_profile',
                "AUDIT: Profile completed user_id=$user_id ip=$profile_ip status=active roles=$roles_to_assign");
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

        eval {
            $user->discard_changes;
            my $login_url = $c->uri_for('/user/login');
            $self->email_notification->send_welcome_email($c, $user, $login_url);
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'complete_profile',
                "Welcome email sent to: " . $user->email);
        };
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'complete_profile',
                "Failed to send welcome email: $@");
        }

        my $final_redirect = $c->session->{return_to} || $c->uri_for('/user/login');
        delete $c->session->{return_to};
        
        $c->flash->{success_msg} = "Registration complete! You can now log in.";
        $c->response->redirect($final_redirect);
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

        # One account per email address (globally unique).
        # If the email already exists, add that existing user to the selected sites
        # rather than creating a duplicate account.
        my $existing_user = $schema->resultset('User')->search({ email => $email })->single;

        if ($existing_user) {
            # Add the existing user to the selected sites/roles they don't already have
            my $added_sites  = 0;
            my $skipped_sites = 0;
            my $create_ip = $c->req->address || 'unknown';
            eval {
                foreach my $site_name (@selected_sites) {
                    my $site_obj = $schema->resultset('Site')->search({ name => $site_name })->single;
                    next unless $site_obj;
                    foreach my $role_name (@selected_roles) {
                        my $already = $schema->resultset('UserSiteRole')->search({
                            user_id => $existing_user->id,
                            site_id => $site_obj->id,
                            role    => $role_name,
                        })->count;
                        if ($already) {
                            $skipped_sites++;
                        } else {
                            $schema->resultset('UserSiteRole')->create({
                                user_id    => $existing_user->id,
                                site_id    => $site_obj->id,
                                role       => $role_name,
                                granted_by => $c->session->{user_id},
                            });
                            $added_sites++;
                        }
                    }
                }
            };

            if ($@) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'admin_create_user',
                    "Error adding existing user to sites: $@");
                $c->stash(
                    error_msg       => "An error occurred while adding user to sites: $@",
                    sites           => \@sites,
                    available_roles => $available_roles,
                    template        => 'user/admin_create_user.tt',
                );
                return;
            }

            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin_create_user',
                "AUDIT: Existing user user_id=" . $existing_user->id . " email='$email' added to sites='" . join(',', @selected_sites) . "'"
                . " roles='" . join(',', @selected_roles) . "' added=$added_sites skipped=$skipped_sites"
                . " admin_id=" . ($c->session->{user_id} || 'unknown') . " ip=$create_ip");

            my $msg = "User '$email' already has an account.";
            if ($added_sites > 0) {
                $msg .= " They have been granted access to the selected site(s) with the chosen role(s).";
            } else {
                $msg .= " They already have the requested access to all selected site(s) — no changes made.";
            }
            $c->flash->{success_msg} = $msg;
            $c->response->redirect($c->uri_for('/admin/users'));
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

            my $create_ip = $c->req->address || 'unknown';
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin_create_user',
                "AUDIT: Admin created user email='$email' new_user_id=" . $user->id
                . " roles=" . join(',', @selected_roles) . " sites=" . join(',', @selected_sites)
                . " admin_id=" . ($c->session->{user_id} || 'unknown') . " ip=$create_ip");

            my $login_url   = $c->uri_for('/user/login');
            my $admin_uname = $c->session->{username} || '';
            my $email_sent  = 0;
            eval {
                $email_sent = $self->email_notification->send_invitation_email(
                    $c, $user, $code, $login_url, $admin_uname
                );
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin_create_user',
                    "Invitation email sent to: $email");
            };
            if ($@) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'admin_create_user',
                    "Failed to send invitation email to $email: $@");
            }

            my $success = "User created successfully.";
            $success .= $email_sent
                ? " An invitation email has been sent to $email."
                : " Invitation code: $code (email could not be sent - please share manually).";
            $c->flash->{success_msg} = $success;
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
            
            my $setup_ip = $c->req->address || 'unknown';
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'complete_username_setup',
                "AUDIT: Account setup completed user_id=" . $user->id . " username='$username' email='$email' ip=$setup_ip status=active");
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
            
            my $pw_setup_ip = $c->req->address || 'unknown';
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'complete_password_setup',
                "AUDIT: Password setup completed user_id=" . $user->id . " username='" . ($user->username || 'N/A') . "' email='$email' ip=$pw_setup_ip status=active");
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

    my $edit_ip = $c->req->address || 'unknown';
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_edit_user',
        "AUDIT: Admin edited user user_id=$user_id email='$email' roles='$roles_str' status='$status' sites='" . join(',', @new_site_names) . "' admin_id=" . ($c->session->{user_id} || 'unknown') . " ip=$edit_ip");

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

    my $susp_action_ip = $c->req->address || 'unknown';
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin_suspend_user',
        "AUDIT: Account suspended user_id=$user_id admin_id=$admin_uid sitename='$sitename' ip=$susp_action_ip");

    eval {
        $self->email_notification->send_account_suspended_email($c, $user);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin_suspend_user',
            "Account suspended notification sent to: " . $user->email);
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'admin_suspend_user',
            "Failed to send account suspended email: $@");
    }

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

    my $act_ip = $c->req->address || 'unknown';
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin_activate_user',
        "AUDIT: Account activated user_id=$user_id admin_id=$admin_uid sitename='$sitename' ip=$act_ip");

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

    my (@todos, @ai_convos, @assignable_users);
    if ($is_csc_admin) {
        eval { @todos = $schema->resultset('Todo')->search({ user_id => $user_id })->all };
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'admin_delete_user',
                "Could not load todos for user_id=$user_id: $@");
        }
        eval { @ai_convos = $schema->resultset('AiConversation')->search({ user_id => $user_id })->all };
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'admin_delete_user',
                "Could not load ai_convos for user_id=$user_id: $@");
        }
        eval {
            @assignable_users = $schema->resultset('User')->search(
                { id => { '!=' => $user_id }, status => 'active' },
                { columns => [qw(id username first_name last_name email)], order_by => 'username' }
            )->all;
        };
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'admin_delete_user',
                "Could not load assignable_users: $@");
        }
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin_delete_user',
        "Displaying delete confirmation for user_id=$user_id");

    $c->stash(
        user             => $user,
        todos            => \@todos,
        ai_convos        => \@ai_convos,
        assignable_users => \@assignable_users,
        is_csc_admin     => $is_csc_admin,
        template         => 'user/AdminDeleteUser.tt',
    );
    $c->forward($c->view('TT'));
}

sub do_admin_delete_user :Local :Args(1) {
    my ($self, $c, $user_id) = @_;
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'do_admin_delete_user')) {
        $c->flash->{error_msg} = 'Access denied. Admin access required.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    my $schema    = $c->model('DBEncy');
    my $user      = $schema->resultset('User')->find($user_id);
    my $admin_uid = $c->session->{user_id};

    unless ($user) {
        $c->flash->{error_msg} = 'User not found.';
        $c->response->redirect($c->uri_for('/admin/users'));
        return;
    }

    if ($user_id == $admin_uid) {
        $c->flash->{error_msg} = 'You cannot delete your own account.';
        $c->response->redirect($c->uri_for('/admin/users'));
        return;
    }

    my $admin_type   = $admin_auth->get_admin_type($c);
    my $is_csc_admin = ($admin_type eq 'csc' || $admin_type eq 'special');

    my $deleted_username = $user->username // $user->email // "id=$user_id";

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_admin_delete_user',
        "Starting deletion of user_id=$user_id username=$deleted_username by admin_id=$admin_uid");

    # Step 1: Handle optional related records BEFORE entering transaction
    # (avoids MySQL transaction abort from missing tables inside txn_do)

    if ($is_csc_admin) {
        my $todo_action     = $c->req->params->{todo_action}   || 'delete';
        my $todo_assignee   = $c->req->params->{todo_assignee} || $admin_uid;
        my $aiconv_action   = $c->req->params->{aiconv_action}   || 'delete';
        my $aiconv_assignee = $c->req->params->{aiconv_assignee} || $admin_uid;

        eval {
            if ($todo_action eq 'reassign') {
                $schema->resultset('Todo')->search({ user_id => $user_id })
                    ->update({ user_id => $todo_assignee });
            } elsif ($todo_action eq 'flag') {
                $schema->resultset('Todo')->search({ user_id => $user_id })
                    ->update({ user_id => $admin_uid });
            } else {
                $schema->resultset('Todo')->search({ user_id => $user_id })->delete;
            }
        };
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_admin_delete_user',
            "Todo handling result: " . ($@ ? "error: $@" : "ok")) if $@;

        eval {
            my @conv_ids = map { $_->id }
                $schema->resultset('AiConversation')->search({ user_id => $user_id })->all;
            if (@conv_ids) {
                $schema->resultset('AiMessage')->search({ conversation_id => { -in => \@conv_ids } })->delete;
            }
            if ($aiconv_action eq 'reassign') {
                $schema->resultset('AiConversation')->search({ user_id => $user_id })
                    ->update({ user_id => $aiconv_assignee });
            } elsif ($aiconv_action eq 'flag') {
                $schema->resultset('AiConversation')->search({ user_id => $user_id })
                    ->update({ user_id => $admin_uid });
            } else {
                $schema->resultset('AiConversation')->search({ user_id => $user_id })->delete;
            }
        };
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_admin_delete_user',
            "AI conversation handling result: error: $@") if $@;
    } else {
        eval { $schema->resultset('Todo')->search({ user_id => $user_id })->delete };
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_admin_delete_user',
            "Todo delete error: $@") if $@;

        eval {
            my @conv_ids = map { $_->id }
                $schema->resultset('AiConversation')->search({ user_id => $user_id })->all;
            if (@conv_ids) {
                $schema->resultset('AiMessage')->search({ conversation_id => { -in => \@conv_ids } })->delete;
            }
            $schema->resultset('AiConversation')->search({ user_id => $user_id })->delete;
        };
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_admin_delete_user',
            "AiConversation delete error: $@") if $@;
    }

    # Step 2: Clean up optional FK tables — log each failure but continue

    # user_sites table: schema mismatch (no 'id' column in actual table) — use raw SQL
    eval {
        $schema->storage->dbh_do(sub {
            my ($storage, $dbh) = @_;
            $dbh->do("DELETE FROM user_sites WHERE user_id = ?", undef, $user_id);
        });
    };
    if ($@) {
        my $err = "$@";
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_admin_delete_user',
            "Raw SQL cleanup of user_sites for user_id=$user_id: $err");
    }

    for my $rs_name (qw(
        WorkshopRole UserSiteRole UserGroup UserApiKeys ApiToken
        EmailVerificationCode PasswordResetToken PlanAudit
        EnvVariableAuditLog WebSearchResult Participant
    )) {
        eval { $schema->resultset($rs_name)->search({ user_id => $user_id })->delete };
        if ($@) {
            my $err = "$@";
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_admin_delete_user',
                "Cleanup of $rs_name for user_id=$user_id: $err");
        }
    }

    # Step 3: Clear created_by references
    eval {
        $schema->resultset('User')->search({ created_by => $user_id })
            ->update({ created_by => undef });
    };
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'do_admin_delete_user',
        "created_by nullify error: $@") if $@;

    # Step 4: Delete the user record — this is the critical step
    # Capture $@ immediately — logging/notification calls will reset it
    my $delete_err;
    eval { $user->delete };
    $delete_err = "$@" if $@;   # stringify immediately before any other eval runs

    if ($delete_err) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'do_admin_delete_user',
            "FAILED to delete user_id=$user_id username=$deleted_username: $delete_err");
        $self->send_error_notification($c,
            "User deletion failed: $deleted_username",
            "user_id=$user_id\nerror=$delete_err");
        $c->flash->{error_msg} = "Failed to delete user '$deleted_username': $delete_err";
        $c->response->redirect($c->uri_for('/admin/users'));
        return;
    }

    my $del_ip = $c->req->address || 'unknown';
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_admin_delete_user',
        "AUDIT: User deleted username='$deleted_username' user_id=$user_id admin_id=$admin_uid ip=$del_ip");

    $c->flash->{success_msg} = "User '$deleted_username' deleted successfully.";
    $c->response->redirect($c->uri_for('/admin/users'));
}

sub register :Local {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'register',
        'Displaying registration form (Step 1)');
    
    my $return_to = $c->req->param('return_to');
    if ($return_to) {
        $c->session->{return_to} = $return_to;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'register',
            "Stored return_to in session: $return_to");
    }
    
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

    # Pre-fill from query param (set by the login form's JS forgot-password link)
    my $prefill = $c->req->param('email') || '';

    if ($c->req->method eq 'POST') {
        my $input = $c->req->params->{email} || '';
        $input =~ s/^\s+|\s+$//g;

        if (!$input) {
            $c->stash(
                error_msg    => 'Please enter your username or email address.',
                prefill_email => $input,
                template     => 'user/forgot_password.tt',
            );
            $c->forward($c->view('TT'));
            return;
        }

        # Find user by email or username
        my $user;
        eval {
            if ($input =~ /@/) {
                $user = $c->model('DBEncy::User')->find({ email => $input });
            } else {
                $user = $c->model('DBEncy::User')->find({ username => $input });
                # If not found by username, try email anyway
                $user ||= $c->model('DBEncy::User')->find({ email => $input });
            }
        };
        my $lookup_err = "$@" if $@;
        if ($lookup_err) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'forgot_password',
                "DB error looking up user '$input': $lookup_err");
        }

        if ($user) {
            my $reset_err;
            eval {
                my $token = $self->user_verification->generate_reset_token();
                $self->user_verification->create_reset_token($user, $token);

                my $reset_link = $c->uri_for('/user/reset_password', { token => $token });
                my $req_ip = $c->req->address || 'unknown';

                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'forgot_password',
                    "AUDIT: Password reset requested user_id=" . $user->id . " input='$input' ip=$req_ip");

                $c->session->{reset_token} = $token;
                $c->session->{reset_email} = $user->email;

                eval {
                    $self->email_notification->send_password_reset_email($c, $user, $reset_link);
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'forgot_password',
                        "Password reset email sent to: " . ($user->email||''));
                };
                if ($@) {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'forgot_password',
                        "Failed to send password reset email: $@");
                }
            };
            $reset_err = "$@" if $@;
            if ($reset_err) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'forgot_password',
                    "Error generating reset token for '$input': $reset_err");
            }
        } else {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'forgot_password',
                "Password reset requested for unknown input: '$input'");
        }

        # Always show generic success message (security — don't reveal whether user exists)
        $c->stash(success_msg => 'If an account exists with that username or email, reset instructions have been sent.');
        $c->stash(template => 'user/forgot_password.tt');
        $c->forward($c->view('TT'));
        return;
    }

    # GET — display form, pre-filled if query param provided
    $c->stash(
        prefill_email => $prefill,
        template      => 'user/forgot_password.tt',
    );
    $c->forward($c->view('TT'));
}

sub reset_password :Local {
    my ($self, $c) = @_;

    my $token     = $c->req->param('token');
    my $home_path = '/' . lc($c->stash->{SiteName} || $c->session->{SiteName} || '');
    $home_path = '/' if $home_path eq '/';

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'reset_password',
        "Accessing reset password page with token: " . ($token ? 'present' : 'missing'));

    # ── GET ──────────────────────────────────────────────────────────────────
    if ($c->req->method ne 'POST') {
        # If the user is already logged in and the token is invalid/used,
        # redirect home instead of showing a confusing error.
        if ($c->session->{username}) {
            my $record = $token
                ? $self->user_verification->verify_reset_token($c->model('DBEncy'), $token)
                : undef;
            unless ($record) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'reset_password',
                    "Already logged in; token invalid/used — redirecting home");
                $c->res->redirect($c->uri_for($home_path));
                return;
            }
        } elsif (!$token) {
            $c->flash->{error_msg} = 'No reset link provided. Please use the link from your email.';
            $c->res->redirect($c->uri_for('/user/forgot_password'));
            return;
        } else {
            my $record = $self->user_verification->verify_reset_token($c->model('DBEncy'), $token);
            unless ($record) {
                $c->stash(
                    error_msg => 'This reset link has already been used or has expired. Please request a new one.',
                    template  => 'user/reset_password.tt',
                );
                $c->forward($c->view('TT'));
                return;
            }
        }

        $c->stash(template => 'user/reset_password.tt', token => $token);
        $c->forward($c->view('TT'));
        return;
    }

    # ── POST ─────────────────────────────────────────────────────────────────
    my $new_password    = $c->req->param('new_password')    || '';
    my $password_confirm = $c->req->param('password_confirm') || '';

    unless ($token) {
        $c->stash(error_msg => 'Missing reset token.', template => 'user/reset_password.tt');
        $c->forward($c->view('TT'));
        return;
    }
    unless ($new_password && $password_confirm) {
        $c->stash(error_msg => 'Please enter and confirm your new password.',
            template => 'user/reset_password.tt', token => $token);
        $c->forward($c->view('TT'));
        return;
    }
    if ($new_password ne $password_confirm) {
        $c->stash(error_msg => 'Passwords do not match.',
            template => 'user/reset_password.tt', token => $token);
        $c->forward($c->view('TT'));
        return;
    }
    if (length($new_password) < 8) {
        $c->stash(error_msg => 'Password must be at least 8 characters.',
            template => 'user/reset_password.tt', token => $token);
        $c->forward($c->view('TT'));
        return;
    }

    my $reset_record = $self->user_verification->verify_reset_token($c->model('DBEncy'), $token);
    unless ($reset_record) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'reset_password',
            "POST: invalid/expired/used reset token");
        $c->stash(error_msg => 'This reset link has already been used or has expired. Please request a new one.',
            template => 'user/reset_password.tt');
        $c->forward($c->view('TT'));
        return;
    }

    my $user = $c->model('DBEncy::User')->find({ id => $reset_record->user_id });
    unless ($user) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'reset_password',
            "User not found for reset token user_id=" . $reset_record->user_id);
        $c->stash(error_msg => 'Account not found.', template => 'user/reset_password.tt');
        $c->forward($c->view('TT'));
        return;
    }

    my $update_err;
    eval {
        my $now_str = DateTime->now->strftime('%Y-%m-%d %H:%M:%S');
        my $status  = $user->status || '';
        my %updates = ( password => sha256_hex($new_password) );
        unless ($status eq 'suspended') {
            $updates{status}           = 'active';
            $updates{email_verified_at} = $now_str unless $user->email_verified_at;
        }
        $user->update(\%updates);
        $reset_record->update({ used_at => $now_str });

        my $ip = $c->req->address || 'unknown';
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'reset_password',
            "AUDIT: Password reset completed user_id=" . $user->id . " username='" . ($user->username || 'N/A') . "' ip=$ip");
    };
    $update_err = "$@" if $@;

    if ($update_err) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'reset_password',
            "Error resetting password: $update_err");
        $c->stash(error_msg => 'An error occurred. Please try again.',
            template => 'user/reset_password.tt', token => $token);
        $c->forward($c->view('TT'));
        return;
    }

    delete $c->session->{reset_token};
    delete $c->session->{reset_email};

    # Redirect to home if already logged in, otherwise to login page
    if ($c->session->{username}) {
        $c->flash->{success_msg} = 'Your password has been updated successfully.';
        $c->res->redirect($c->uri_for($home_path));
    } else {
        $c->flash->{success_msg} = 'Password reset successful. You can now log in with your new password.';
        $c->res->redirect($c->uri_for('/user/login'));
    }
}

sub change_password_request :Local {
    my ($self, $c) = @_;
    # Legacy route — redirect to the active forgot_password flow
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'change_password_request',
        'Legacy change_password_request accessed — redirecting to forgot_password');
    $c->res->redirect($c->uri_for('/user/forgot_password'));
}

sub do_change_password_request :Path('/do_change_password_request') :Args(0) {
    my ($self, $c) = @_;
    # Legacy route — redirect to the active forgot_password flow
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_change_password_request',
        'Legacy do_change_password_request accessed — redirecting to forgot_password');
    $c->res->redirect($c->uri_for('/user/forgot_password'));
}

sub admin_manage_roles :Local :Args(1) {
    my ($self, $c, $user_id) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'admin_manage_roles')) {
        $c->flash->{error_msg} = 'Access denied. Admin access required.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    my $schema       = $c->model('DBEncy');
    my $user         = $schema->resultset('User')->find($user_id);

    unless ($user) {
        $c->flash->{error_msg} = 'User not found.';
        $c->response->redirect($c->uri_for('/admin/users'));
        return;
    }

    my $admin_type   = $admin_auth->get_admin_type($c);
    my $is_csc_admin = ($admin_type eq 'csc' || $admin_type eq 'special');
    my $sitename     = $c->session->{SiteName};
    my $admin_uid    = $c->session->{user_id};

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

    if ($c->req->method eq 'POST') {
        my @roles_arr      = $c->req->param('roles');
        my @new_site_names = $c->req->param('sitenames');
        my $roles_str      = join(',', @roles_arr);

        my @all_sites;
        eval {
            @all_sites = $is_csc_admin
                ? $schema->resultset('Site')->search({}, { order_by => 'name' })->all
                : $schema->resultset('Site')->search({ name => $sitename }, { order_by => 'name' })->all;
        };

        my %allowed_site_ids;
        for my $s (@all_sites) {
            $allowed_site_ids{$s->id} = $s->name;
        }

        eval {
            $user->update({ roles => $roles_str });

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
                }
            }

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
                }
            }
        };

        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'admin_manage_roles',
                "Error updating roles for user_id=$user_id: $@");
            $c->flash->{error_msg} = "An error occurred while saving role changes: $@";
        } else {
            my $roles_ip = $c->req->address || 'unknown';
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin_manage_roles',
                "AUDIT: Roles updated user_id=$user_id admin_id=$admin_uid roles='$roles_str' sites='" . join(',', @new_site_names) . "' ip=$roles_ip");
            $c->flash->{success_msg} = 'User roles and site access updated successfully.';
        }

        $c->response->redirect($c->uri_for('/user/edit_user', $user_id));
        return;
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

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin_manage_roles',
        "Displaying role management form for user_id=$user_id");

    $c->stash(
        user            => $user,
        available_roles => $available_roles,
        is_csc_admin    => $is_csc_admin,
        all_sites       => \@all_sites,
        user_site_ids   => \%user_site_ids,
        template        => 'user/AdminManageRoles.tt',
    );
    $c->forward($c->view('TT'));
}

sub admin_role_list :Local :Args(0) {
    my ($self, $c) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'admin_role_list')) {
        $c->flash->{error_msg} = 'Access denied. Admin access required.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    my $schema       = $c->model('DBEncy');
    my $admin_type   = $admin_auth->get_admin_type($c);
    my $is_csc_admin = ($admin_type eq 'csc' || $admin_type eq 'special');
    my $sitename     = $c->session->{SiteName};

    if ($c->req->method eq 'POST') {
        my $action      = $c->req->params->{action} || 'create';
        my $role_name   = $c->req->params->{role_name};
        my $description = $c->req->params->{description} || '';
        my $target_site = $c->req->params->{sitename} || $sitename;

        unless ($is_csc_admin || $target_site eq $sitename) {
            $c->flash->{error_msg} = 'Access denied. You can only manage roles for your own site.';
            $c->response->redirect($c->uri_for('/user/admin_role_list'));
            return;
        }

        if ($action eq 'create') {
            unless ($role_name && $role_name =~ /^[a-zA-Z][a-zA-Z0-9_]{1,49}$/) {
                $c->flash->{error_msg} = 'Invalid role name. Use letters, numbers, underscores (2-50 chars, start with a letter).';
                $c->response->redirect($c->uri_for('/user/admin_role_list'));
                return;
            }

            my @system_roles = qw(normal member editor developer admin);
            if (grep { $_ eq lc($role_name) } map { lc($_) } @system_roles) {
                $c->flash->{error_msg} = "Cannot create a custom role with a system role name: $role_name";
                $c->response->redirect($c->uri_for('/user/admin_role_list'));
                return;
            }

            eval {
                $schema->resultset('SiteRole')->create({
                    sitename       => $target_site,
                    role_name      => $role_name,
                    description    => $description,
                    is_system_role => 0,
                });
            };

            if ($@) {
                if ($@ =~ /duplicate|Duplicate/i) {
                    $c->flash->{error_msg} = "Role '$role_name' already exists for site '$target_site'.";
                } else {
                    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'admin_role_list',
                        "Error creating role '$role_name' for site '$target_site': $@");
                    $c->flash->{error_msg} = "An error occurred while creating the role.";
                }
            } else {
                my $role_create_ip = $c->req->address || 'unknown';
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin_role_list',
                    "AUDIT: Custom role created role='$role_name' site='$target_site' admin_id=" . ($c->session->{user_id} || 'unknown') . " admin='" . ($c->session->{username} || 'unknown') . "' ip=$role_create_ip");
                $c->flash->{success_msg} = "Role '$role_name' created successfully for site '$target_site'.";
            }
        }

        $c->response->redirect($c->uri_for('/user/admin_role_list'));
        return;
    }

    my @site_roles;
    eval {
        my $rs = $is_csc_admin
            ? $schema->resultset('SiteRole')->search({}, { order_by => ['sitename', 'role_name'] })
            : $schema->resultset('SiteRole')->search({ sitename => $sitename }, { order_by => 'role_name' });
        @site_roles = $rs->all;
    };

    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'admin_role_list',
            "Could not load site_roles: $@");
        $c->flash->{error_msg} = 'Could not load roles. The site_roles table may not exist yet.';
    }

    my @available_sites;
    eval {
        @available_sites = $is_csc_admin
            ? $schema->resultset('Site')->search({}, { order_by => 'name' })->all
            : $schema->resultset('Site')->search({ name => $sitename }, { order_by => 'name' })->all;
    };

    my @system_roles = qw(normal member editor developer admin WorkshopLeader);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin_role_list',
        "Displaying role list for sitename=$sitename is_csc_admin=$is_csc_admin");

    $c->stash(
        site_roles       => \@site_roles,
        system_roles     => \@system_roles,
        available_sites  => \@available_sites,
        is_csc_admin     => $is_csc_admin,
        sitename         => $sitename,
        template         => 'user/AdminRoleList.tt',
    );
    $c->forward($c->view('TT'));
}

sub admin_delete_site_role :Local :Args(1) {
    my ($self, $c, $role_id) = @_;
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'admin_delete_site_role')) {
        $c->flash->{error_msg} = 'Access denied. Admin access required.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    my $schema       = $c->model('DBEncy');
    my $admin_type   = $admin_auth->get_admin_type($c);
    my $is_csc_admin = ($admin_type eq 'csc' || $admin_type eq 'special');
    my $sitename     = $c->session->{SiteName};

    my $role = $schema->resultset('SiteRole')->find($role_id);

    unless ($role) {
        $c->flash->{error_msg} = 'Role not found.';
        $c->response->redirect($c->uri_for('/user/admin_role_list'));
        return;
    }

    unless ($is_csc_admin || $role->sitename eq $sitename) {
        $c->flash->{error_msg} = 'Access denied. You can only delete roles for your own site.';
        $c->response->redirect($c->uri_for('/user/admin_role_list'));
        return;
    }

    if ($role->is_system_role) {
        $c->flash->{error_msg} = "Cannot delete system role '" . $role->role_name . "'.";
        $c->response->redirect($c->uri_for('/user/admin_role_list'));
        return;
    }

    my $role_name = $role->role_name;
    my $role_site = $role->sitename;

    eval {
        $role->delete;
    };

    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'admin_delete_site_role',
            "Error deleting role_id=$role_id: $@");
        $c->flash->{error_msg} = "An error occurred while deleting the role.";
    } else {
        my $role_del_ip = $c->req->address || 'unknown';
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin_delete_site_role',
            "AUDIT: Custom role deleted role='$role_name' site='$role_site' admin_id=" . ($c->session->{user_id} || 'unknown') . " admin='" . ($c->session->{username} || 'unknown') . "' ip=$role_del_ip");
        $c->flash->{success_msg} = "Role '$role_name' deleted successfully.";
    }

    $c->response->redirect($c->uri_for('/user/admin_role_list'));
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
