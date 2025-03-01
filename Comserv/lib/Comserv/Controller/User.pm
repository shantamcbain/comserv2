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

# perl
sub begin : Private {
    my ( $self, $c ) = @_;
    warn "Entering Comserv::Controller::Admin::begin\n";
    # Debug logging for begin action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', "Starting begin action");
    $c->stash->{debug_errors} //= []; # Ensure debug_errors is initialized

    # Check if the user is logged in
    if ( !$c->user_exists ) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', "User not logged in, redirecting to home.");
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Fetch the roles from the session
    my $roles = $c->session->{roles};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', "Roles: " . Dumper($roles));

    # Check if roles is defined and is an array reference
    if ( defined $roles && ref $roles eq 'ARRAY' ) {
        # Log the roles being checked
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', "Checking roles: " . join(", ", @$roles));

        # Directly check for 'admin' role using grep
        if ( grep { $_ eq 'admin' } @$roles ) {
            # User is admin, proceed with accessing the admin area
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', "Admin user detected, proceeding.");
            return; # Important: Return to allow admin to proceed
        } else {
            # User is not admin, redirect to home
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', "Non-admin user, redirecting to home. Roles found: " . join(", ", @$roles));
            $c->response->redirect($c->uri_for('/'));
            return;
        }
    } else {
        # Log that roles are not defined or not an array
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', "No roles defined or roles is not an array, redirecting to home.");
        $c->response->redirect($c->uri_for('/'));
        return;
    }
}

sub index :Path :Args(0) {
    my ($self, $c) = @_;

    # Access the User model
    my $user_model = $c->model('DBEncy::Ency::User');

    # Use the User model to retrieve user data
    my $user_data = $user_model->search({});

    # Store the user data in the stash
    $c->stash(users => $user_data);

    # Display the user index page
    $c->stash(template => 'user/index.tt');
    $c->forward($c->view('TT'));
}
sub login :Local {
    my ($self, $c) = @_;

    # Store the referer URL if it hasn't been stored already
    my $referer = $c->req->referer || $c->uri_for('/');
    if (!$c->session->{referer}) {
        $c->session->{referer} = $referer;
    }

    # Display the login form
    $c->stash(template => 'user/login.tt');
    $c->forward($c->view('TT'));
}
sub do_login : Local {
    my ($self, $c) = @_;

    # Check if logging is available
    if (not $self->logging || not $self->logging->can('log_with_details')) {
        print STDERR "ERROR: Logging object or method `log_with_details` is missing in User controller\n";
    }

    # Start login process
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_login', 'Login process initiated.');

    # Get user input
    my $username = $c->req->params->{username} || '';
    my $password = $c->req->params->{password} || '';

    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'do_login',
        "Attempting login for username: $username"
    );

    # Get redirect path
    my $redirect_path = $c->stash->{forwarder} || '/';
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

        $c->stash->{error_msg} = 'Invalid username or password.';
        $c->detach('/login');
    }

    # Verify password
    if ($self->hash_password($password) ne $user->password) {
        $self->logging->log_with_details(
            $c, 'warn', __FILE__, __LINE__, 'do_login',
            "Login failed: Password mismatch for username '$username'."
        );

        $c->stash->{error_msg} = 'Invalid username or password.';
        $c->detach('/login');
    }

    # Success
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_login', "User '$username' successfully authenticated.");

    # Set session
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

    # Redirect after successful login
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'do_login', "Redirecting user '$username' to: $redirect_path");
    $c->res->redirect($redirect_path);
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
    my ($self, $c) = @_;}

__PACKAGE__->meta->make_immutable;

1;