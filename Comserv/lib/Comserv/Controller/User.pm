package Comserv::Controller::User;
use Moose;
use namespace::autoclean;
use Digest::SHA qw(sha256_hex);  # For hashing passwords
use Data::Dumper;
use Email::Sender::Simple qw(sendmail);
use Email::Simple;
use Email::Simple::Creator;
use Email::Sender::Transport::SMTP;

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

    # Don't store the login page as the referer
    if ($referer !~ m{/user/login} && $referer !~ m{/login} && $referer !~ m{/do_login}) {
        $c->session->{referer} = $referer;
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
    # Use a default path if referer is not set, avoid using undefined values
    my $redirect_path = $c->session->{referer} || '/';

    # Log the referer for debugging
    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'do_login',
        "Session referer: " . ($c->session->{referer} || 'undefined')
    );

    # Ensure we're not redirecting back to the login page
    if ($redirect_path =~ m{/user/login} || $redirect_path =~ m{/login} || $redirect_path =~ m{/do_login}) {
        $redirect_path = '/';
    }

    # Find user in database
    my $user = $c->model('DBEncy::User')->find({ username => $username });
    unless ($user) {
        $self->logging->log_with_details(
            $c, 'warn', __FILE__, __LINE__, 'do_login',
            "Login failed: Username '$username' not found."
        );

        # Improved error handling
        $c->stash(
            error_msg => 'Invalid username or password.',
            template => 'user/login.tt'
        );
        $c->forward($c->view('TT'));
        return;
    }

    # Verify password
    if ($self->hash_password($password) ne $user->password) {
        $self->logging->log_with_details(
            $c, 'warn', __FILE__, __LINE__, 'do_login',
            "Login failed: Password mismatch for username '$username'."
        );

        # Improved error handling
        $c->stash(
            error_msg => 'Invalid username or password.',
            template => 'user/login.tt'
        );
        $c->forward($c->view('TT'));
        return;
    }

    # Success
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_login', "User '$username' successfully authenticated.");

    # Clear any existing session data
    $c->session({});

    # Set new session data
    $c->session->{username} = $user->username;
    $c->session->{user_id}  = $user->id;
    $c->session->{first_name} = $user->first_name;
    $c->session->{last_name}  = $user->last_name;
    $c->session->{email}    = $user->email;

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

    # Set a success message in the flash
    $c->flash->{success_msg} = "Login successful. Welcome, $username!";

    # Clear the referer to prevent redirect loops
    $c->session->{referer} = undef;

    # Log the redirect
    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'do_login',
        "Redirecting user '$username' to: $redirect_path");

    # Redirect to the appropriate page
    $c->res->redirect($redirect_path);
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
    # Use a default path if forwarder is not set, avoid using undefined values
    my $redirect_path = $c->session->{referer} || '/';

    # Ensure we're not redirecting back to the login page
    if ($redirect_path =~ m{/user/login} || $redirect_path =~ m{/login}) {
        $redirect_path = '/';
    }

    # Log the components of the redirect path
    $self->logging->log_with_details(
        $c, 'debug', __FILE__, __LINE__, 'do_login',
        "session->{referer}: " . ($c->session->{referer} || 'undefined')
    );
    $self->logging->log_with_details(
        $c, 'debug', __FILE__, __LINE__, 'do_login',
        "Redirect path resolved to: $redirect_path"
    );

    # Find user in database
    my $user = $c->model('DBEncy::User')->find({ username => $username });
    unless ($user) {
        $self->logging->log_with_details(
            $c, 'warn', __FILE__, __LINE__, 'do_login',
            "Login failed: Username '$username' not found."
        );

        # Improved error handling
        $c->stash(
            error_msg => 'Invalid username or password.',
            template => 'user/login.tt'
        );
        $c->forward($c->view('TT'));
        return;
    }

    # Verify password
    if ($self->hash_password($password) ne $user->password) {
        $self->logging->log_with_details(
            $c, 'warn', __FILE__, __LINE__, 'do_login',
            "Login failed: Password mismatch for username '$username'."
        );

        # Improved error handling
        $c->stash(
            error_msg => 'Invalid username or password.',
            template => 'user/login.tt'
        );
        $c->forward($c->view('TT'));
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

    # Try a different approach for the redirect
    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'do_login',
        "Using $c->res->redirect() for redirect to: $redirect_path"
    );

    # Double-check that we're not redirecting back to the login page
    if ($redirect_path =~ m{/user/login} || $redirect_path =~ m{/login} || $redirect_path =~ m{/do_login}) {
        $redirect_path = '/';
        $self->logging->log_with_details(
            $c, 'info', __FILE__, __LINE__, 'do_login',
            "Redirecting to home page instead of login page"
        );
    }

    $c->res->redirect($redirect_path);
    return;
}
sub hash_password {
    my ($self, $password) = @_;
    return sha256_hex($password);
}
sub create_account :Local {
    my ($self, $c) = @_;

    # Display the account creation form
    $c->stash(template => '/user/create_account.tt');
}
sub do_create_account :Local {
    my ($self, $c) = @_;

    # Retrieve the form data
    my $username = $c->request->params->{username};
    my $password = $c->request->params->{password};
    my $password_confirm = $c->request->params->{password_confirm};  # Retrieve the confirmation password
    my $first_name = $c->request->params->{first_name};
    my $last_name = $c->request->params->{last_name};

    # Ensure all required fields are filled
    unless ($username && $password && $password_confirm && $first_name && $last_name) {
        $c->stash(
            error_msg => 'All fields are required to create an account',
            template  => 'user/create_account.tt',
        );
        return;
    }

    # Check if the passwords match
    if ($password ne $password_confirm) {
        $c->stash(
            error_msg => 'Passwords do not match',
            template  => 'user/create_account.tt',
        );
        return;
    }

    # Hash the password
    my $hashed_password = $self->hash_password($password);

    # Check if the username already exists in the database
    my $existing_user = $c->model('DBEncy::Ency::User')->find({ username => $username });
    if ($existing_user) {
        $c->stash(
            error_msg => 'Username already exists. Please choose another.',
            template  => 'user/create_account.tt',
        );
        return;
    }

    # Create the new user in the database
    eval {
        $c->model('DBEncy::Ency::User')->create({
            username    => $username,
            password    => $hashed_password,
            first_name  => $first_name,
            last_name   => $last_name,
        });
    };

    if ($@) {
        # Handle any database errors
        $c->stash(
            error_msg => "An error occurred while creating the account: $@",
            template  => 'user/create_account.tt',
        );
        return;
    }

    # Redirect to the login page on success
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

    # Retrieve the user ID from the URL
    my $user_id = $c->request->arguments->[0];

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object
    my $rs = $schema->resultset('User');

    # Find the user in the database
    my $user = $rs->find($user_id);

    if ($user) {
        # The user was found, so store the user object in the stash
        $c->stash(user => $user);

        # Set the template for the response
        $c->stash(template => 'user/edit_user.tt');
    } else {
        # The user was not found, so display an error message
        $c->response->body('User not found');
    }
}
sub do_edit_user :Local :Args(1) {
    my ($self, $c) = @_;

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

        # Print the form data
        print "Form data: " . Dumper($form_data);

        # Update the user record with the new data
        $user->update({
            username   => $form_data->{username},
            first_name => $form_data->{first_name},
            last_name  => $form_data->{last_name},
            email      => $form_data->{email},
            roles      => $form_data->{roles},
        });

        # Redirect the user back to the list of users
        $c->response->redirect($c->uri_for($self->action_for('list_users')));
    } else {
        # The user was not found, so display an error message
        $c->response->body('User not found');
    }
}
sub register :Local {
    my ($self, $c) = @_;

    # Display the registration form
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

__PACKAGE__->meta->make_immutable;

1;
