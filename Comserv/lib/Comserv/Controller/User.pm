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

sub login :Chained('base') :PathPart('login') :Args(0) {
    my ($self, $c) = @_;

    # Handle the login functionality here
    # For example, you can check the user's credentials and start a session

    # Set the template for the login page
    $c->stash(template => 'User/login.tt');
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
   # Store the referrer URL and form data in the session
    $c->session->{referer} = $c->req->header('referer');
    $c->session->{form_data} = $c->req->body_params;

    # Display the login form
    $c->stash(template => 'user/login.tt');
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
            # Retrieve the referrer URL and form data from the session
            my $referer = $c->session->{referer};
            my $form_data = $c->session->{form_data};

            # Redirect to the previous page
            $c->res->redirect($referer);
        } else {
            # The passwords don't match, so the login is unsuccessful
            $c->stash(template => 'user/login.tt', error => 'Invalid username or password');
            $c->forward($c->view('TT'));
        }
    } else {
        # The user was not found in the database
        $c->stash(template => 'user/login.tt', error => 'Invalid username or password');
        $c->forward($c->view('TT'));
    }
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