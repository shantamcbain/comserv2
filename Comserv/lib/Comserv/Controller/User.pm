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
sub base :Chained('/') :PathPart('user') :CaptureArgs(0) {
    my ( $self, $c ) = @_;
    # This will capture /user in the URL
}

sub login :Local {
    my ($self, $c) = @_;
   # Store the referrer URL and form data in the session
    $c->session->{referer} = $c->req->header('referer');
    $c->session->{form_data} = $c->req->body_params;

    # Display the login form
    $c->stash(template => 'user/login.tt');
    $c->forward($c->view('TT'));

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

sub do_login :Local {
    my ($self, $c) = @_;

    # Retrieve the username and password from the form data
    my $username = $c->request->params->{username};
    my $password = $c->request->params->{password};

    # Debugging: Print login attempt
    print "Attempting login for: $username\n";

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object
    my $rs = $schema->resultset('User');

    # Find the user in the database
    my $user = $rs->find({ username => $username });

    if ($user) {
        # Hash the submitted password
        my $hashed_password = $self->hash_password($password);

        # Compare the hashed password with the one stored in the database
        if ($hashed_password eq $user->password) {
            # The passwords match, so the login is successful
            print "Login successful for: $username\n";

            # Store the user's roles and other details in the session
            $c->session->{roles} = $user->roles;
            $c->session->{username} = $user->username;
            $c->session->{first_name} = $user->first_name;
            $c->session->{last_name} = $user->last_name;
            $c->session->{email} = $user->email;
            $c->session->{user_id} = $user->id;  # Store user_id in the session

            # Store the user object in the session
            $c->set_authenticated(Comserv::Model::User->new(_user => $user));

            # Retrieve the referrer URL and form data from the session
            my $referer = $c->session->{referer};
            my $form_data = $c->session->{form_data};

            # Redirect to the previous page
            $c->res->redirect($referer);
        } else {
            # The passwords don't match, so the login is unsuccessful
            print "Invalid password for: $username\n";
            $c->stash(template => 'user/login.tt', error => 'Invalid username or password');
            $c->forward($c->view('TT'));
        }
    } else {
        # The user was not found in the database
        print "User not found: $username\n";
        $c->stash(template => 'user/login.tt', error => 'Invalid username or password');
        $c->forward($c->view('TT'));
    }
}

sub hash_password {
    my ($self, $password) = @_;
    return sha256_hex($password);
}
sub do_create_account :Local {
    my ($self, $c) = @_;

    # Retrieve the form data
    my $username = $c->request->params->{username};
    my $password = $c->request->params->{password};
    my $password_confirm = $c->request->params->{password_confirm};
    my $first_name = $c->request->params->{first_name};
    my $last_name = $c->request->params->{last_name};
    my $email = $c->request->params->{email};

    # Initialize an error hash
    my %errors;

    # Check if all required fields are present
    unless ($username && $password && $password_confirm && $first_name && $last_name && $email) {
        $errors{general} = 'All fields are required';
    }

    # Check if the password and confirmation password match
    if ($password ne $password_confirm) {
        $errors{password} = 'Passwords do not match';
    }

    # Validate email format
    unless ($email =~ /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/) {
        $errors{email} = 'Invalid email format';
    }

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object
    my $rs = $schema->resultset('User');

    # Check if the username is already taken
    if ($rs->find({ username => $username })) {
        $errors{username} = 'Username is already taken';
    }

    # If there are any errors, set them in the stash and return
    if (%errors) {
        $c->stash(
            template => 'user/register.tt',
            errors   => \%errors,
            username => $username,
            email    => $email,
            first_name => $first_name,
            last_name  => $last_name,
        );
        $c->forward($c->view('TT'));
        return;
    }

    # Hash the password
    my $hashed_password = $self->hash_password($password);

    # Create a new user in the database
    my $user;
    eval {
        $user = $rs->create({
            username   => $username,
            password   => $hashed_password,
            first_name => $first_name,
            last_name  => $last_name,
            email      => $email,
            roles      => 'normal',
        });
    };

    if ($@) {
        warn "Error creating user: $@";
        $c->stash(template => 'user/register.tt', error => "An error occurred while creating the account: $@");
        $c->forward($c->view('TT'));
        return;
    }

    # Debugging: Confirm user creation
    print "User created: " . Dumper($user);

    # Retrieve email addresses from the stash
    my $admin_email = $c->stash->{mail_to_admin};
    my $user_email = $email;
    my $mail_from = $c->stash->{mail_from};

    # Send welcome email to the user
    my $user_email_obj = Email::Simple->create(
        header => [
            To      => $user_email,
            From    => $mail_from,
            Subject => "Welcome to the Application",
        ],
        body => "Hello $first_name,\n\nWelcome to our application! Your account has been successfully created.\n\nBest regards,\nThe Team",
    );

    eval { sendmail($user_email_obj) };
    if ($@) {
        warn "Failed to send email to user: $@";
    }

    # Send notification email to the admin
    my $admin_email_obj = Email::Simple->create(
        header => [
            To      => $admin_email,
            From    => $mail_from,
            Subject => "New User Account Created",
        ],
        body => "A new user account has been created for $first_name $last_name ($username).",
    );

    eval { sendmail($admin_email_obj) };
    if ($@) {
        warn "Failed to send email to admin: $@";
    }

    # Set a success message in the session
    $c->session->{success_msg} = "Welcome, $first_name! Your account has been created successfully. Please log in.";

    # Redirect to the welcome page
    $c->res->redirect($c->uri_for('/user/welcome'));
}

sub logout :Local {
    my ($self, $c) = @_;

    # Remove specific user information from the session
    delete $c->session->{roles};
    delete $c->session->{username};
    delete $c->session->{first_name};
    delete $c->session->{last_name};
    delete $c->session->{email};
    delete $c->session->{user_id};

    # Clear the entire session
    $c->logout;

    # Retrieve the referrer URL from the session
    my $referer = $c->session->{referer} || $c->uri_for('/'); # Default to home if no referrer

    # Redirect to the referrer URL
    $c->res->redirect($referer);
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

__PACKAGE__->meta->make_immutable;

1;