package Comserv::Controller::User;
use Moose;
use namespace::autoclean;
use Digest::SHA qw(sha256_hex);  # For hashing passwords
use MIME::Base64 qw(encode_base64url decode_base64url);  # Import the necessary module
use Data::Dumper;
use Email::Sender::Simple qw(sendmail);
use Email::Simple;
use Email::Simple::Creator;
use Email::Sender::Transport::SMTP qw();

BEGIN { extends 'Catalyst::Controller'; }

sub base :Chained('/') :PathPart('user') :CaptureArgs(0) {
    my ( $self, $c ) = @_;
    # This will capture /user in the URL
}

sub login :Chained('base') :PathPart('login') :Args(0) {
    my ($self, $c) = @_;

    # Handle the login functionality here
    # For example, you can check the user's credentials and start a session

    # Set the template for the login page
    $c->stash(template => 'user/login.tt');
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
            # Store the user's roles in the session
            $c->session->{roles} = $user->roles;
            $c->session->{username} = $user->username;
            $c->session->{first_name} = $user->first_name;
            $c->session->{last_name} = $user->last_name;
            $c->session->{email} = $user->email;

            # Store the user object in the session
            $c->set_authenticated(Comserv::Model::User->new(_user => $user));

            # Place the user's roles in the stash
            $c->stash->{roles} = $user->roles;

            # Retrieve the referrer URL and form data from the session
            my $referer = $c->session->{referer} || $c->uri_for('/');  # Default to home if no referrer

            # Redirect to the previous page
            $c->res->redirect($referer);
            return;
        } else {
            # The passwords don't match, so the login is unsuccessful
            $c->stash->{error_msg} = 'Invalid password';
        }
    } else {
        # The user was not found in the database
        $c->stash->{error_msg} = 'Invalid username';
    }

    # If we reach here, authentication failed, so display the login form again
    $c->stash(template => 'user/login.tt');
    $c->forward($c->view('TT'));
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

    # Retrieve form data
    my $email = $c->request->params->{email};
    my $first_name = $c->request->params->{first_name};
    my $last_name = $c->request->params->{last_name};
    my $password = $c->request->params->{password};
    my $username = $c->request->params->{username};

    # Debug: Print form data
    $c->log->debug("Form data: email=$email, first_name=$first_name, last_name=$last_name, password=$password, username=$username");

    # Check if first_name is defined
    if (!defined $first_name || $first_name eq '') {
        $c->stash->{error_msg} = "First name is required. Received values: email=$email, first_name=$first_name, last_name=$last_name, password=$password, username=$username";
        $c->stash(template => 'user/register.tt');
        $c->forward($c->view('TT'));
        return;
    }

    # Insert user into the database
    eval {
        # Call the create_user subroutine from the User model
        my $user_model = $c->model('User');
        die "User model not found" unless $user_model;

        $user_model->create_user({
            email      => $email,
            first_name => $first_name,
            last_name  => $last_name,
            password   => $password,
            username   => $username,
        });

    # Email sending logic
    my $email = Email::Simple->create(
        header => [
            To      => '$email',
            From    => 'admin@computersystemconsulting.ca',
            Subject => 'Welcome!',
        ],
        body => 'Welcome to our service!',
    );

        # Send email to admin
        my $email = Email::Simple->create(
            header => [
                To      => 'shanta@computersystemconsulting.ca',
                From    => 'noreply@computersystemconsulting.ca',
                Subject => 'New User Registration',
            ],
            body => "A new user has registered with the username: $username",
        );
      my $transport = Email::Sender::Transport::SMTP->new({
        host => 'localhost',
        port => 25,
    });

    };
    if ($@) {
        $c->stash->{error_msg} = "Failed to create user: $@. Received values: email=$email, first_name=$first_name, last_name=$last_name, password=$password, username=$username";
        $c->stash(template => 'user/register.tt');
    } else {
        $c->stash->{success_msg} = "User created successfully.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    # Forward to the view
    $c->forward($c->view('TT'));
}

sub list_users :Chained('base') :PathPart('list_users') :Args(0) {
    my ($self, $c) = @_;

    # Fetch the list of users and pass it to the view
    my @users = $c->model('DBEncy::User')->all;
    $c->stash(users => \@users);

    # Display the list of users
    $c->stash(template => 'user/list_users.tt');
}


sub load_user :Chained('base') :PathPart('edit_user') :CaptureArgs(1) {
    my ($self, $c, $user_id) = @_;

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object
    my $rs = $schema->resultset('User');

    # Find the user in the database
    my $user = $rs->find($user_id);

    if ($user) {
        # The user was found, so store the user object in the stash
        $c->stash(user => $user);
    } else {
        # The user was not found, so display an error message
        $c->response->body('User not found');
        $c->detach();
    }
}

sub edit_user :Chained('load_user') :PathPart('') :Args(0) {
    my ($self, $c) = @_;

    # Set the template for the response
    $c->stash(template => 'user/edit_user.tt');
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

        # Update the user record with the new data
        my %update_data = (
            username   => $form_data->{username},
            first_name => $form_data->{first_name},
            last_name  => $form_data->{last_name},
            email      => $form_data->{email},
            roles      => $form_data->{roles},
        );

        # Check if the password field is provided and not empty
        if ($form_data->{password}) {
            # Hash the new password before storing it
            $update_data{password} = sha256_hex($form_data->{password});
        }

        $user->update(\%update_data);

        # Redirect the user back to the list of users
        $c->response->redirect($c->uri_for($self->action_for('list_users')));
    } else {
        # The user was not found, so display an error message
        $c->response->body('User not found');
    }
}
sub change_password_request :Path('/user/change_password_request') :Args(0) {
    my ($self, $c) = @_;
    $c->stash(template => 'user/change_password_request.tt');
}

sub do_change_password_request :Path('/user/do_change_password_request') :Args(0) {
    my ($self, $c) = @_;
    my $username = $c->request->params->{username};
    my $user = $c->model('DBEncy::User')->find({ username => $username });

    if ($user) {
        my $token = $self->generate_token($user->id);
        my $change_password_url = $c->uri_for('/user/change_password', { token => $token });

        my $subject = 'Password Change Request';
        my $body = "Click the following link to change your password: $change_password_url";

        if ($c->model('Mail')->send_email($user->email, $subject, $body)) {
            $c->stash->{success_msg} = 'An email has been sent with instructions to change your password.';
        } else {
            $c->stash->{error_msg} = 'Failed to send email. Please try again later.';
        }
    } else {
        $c->stash->{error_msg} = 'Username not found.';
    }

    $c->stash(template => 'user/change_password_request.tt');
}


sub change_password :Path('/user/change_password') :Args(0) {
    my ($self, $c) = @_;
    my $token = $c->request->params->{token};
    my $user_id = $self->validate_token($token);

    if ($user_id) {
        $c->stash(user_id => $user_id, template => 'user/change_password.tt');
    } else {
        $c->stash->{error_msg} = 'Invalid or expired token.';
        $c->stash(template => 'user/change_password_request.tt');
    }
}

sub do_change_password :Path('/user/do_change_password') :Args(0) {
    my ($self, $c) = @_;
    my $user_id = $c->request->params->{user_id};
    my $new_password = $c->request->params->{password};

    my $user = $c->model('DBEncy::User')->find($user_id);

    if ($user) {
        $user->update({ password => sha256_hex($new_password) });
        $c->stash->{success_msg} = 'Password changed successfully. Please log in with your new password.';
        $c->response->redirect($c->uri_for('/user/login'));
    } else {
        $c->stash->{error_msg} = 'User not found.';
        $c->stash(template => 'user/change_password.tt');
    }
}

sub generate_token {
    my ($self, $user_id) = @_;
    return encode_base64url($user_id . ':' . time);
}

sub validate_token {
    my ($self, $token) = @_;
    my ($user_id, $timestamp) = split(':', decode_base64url($token));
    return $user_id if $timestamp > time - 3600;
    return;
}


sub register :Local {
    my ($self, $c) = @_;

    # Display the registration form
    $c->stash(template => 'user/register.tt');
}

__PACKAGE__->meta->make_immutable;

1;