package Comserv::Controller::Mail;
use Moose;
use namespace::autoclean;
BEGIN { extends 'Catalyst::Controller'; }

sub index :Path :Args(0) {
    my ( $self, $c ) = @_;
     # Set the template to users/index .tt
    $c->stash(template => 'user/mail.tt');

    # Forward to the TT view to render the template
    $c->forward($c->view('TT'));
}

sub send_welcome_email :Local {
    my ($self, $c, $user) = @_;
    my $mail_model = $c->model('Mail');
    my $subject = "Welcome to the Application";
    my $body = "Hello " . $user->first_name . ",\n\nWelcome to our application!";
    $mail_model->send_email($user->email, $subject, $body);
}

sub add_mail_config_form :Local {
    my ($self, $c) = @_;
    $c->stash(template => 'mail/add_mail_config_form.tt');
}

sub add_mail_config :Local {
    my ($self, $c) = @_;
    my $site_id = $c->request->body_parameters->{site_id};
    my $smtp_host = $c->request->body_parameters->{smtp_host};
    my $smtp_port = $c->request->body_parameters->{smtp_port};
    my $smtp_username = $c->request->body_parameters->{smtp_username};
    my $smtp_password = $c->request->body_parameters->{smtp_password};

    my $schema = $c->model('DBEncy');
    my $site_config_rs = $schema->resultset('SiteConfig');

    for my $config (qw(smtp_host smtp_port smtp_username smtp_password)) {
        my $value = $c->request->body_parameters->{$config};
        $site_config_rs->update_or_create({
            site_id => $site_id,
            config_key => $config,
            config_value => $value,
        });
    }

    $c->flash->{message} = 'Mail configuration added successfully';
    $c->res->redirect($c->uri_for($self->action_for('add_mail_config_form')));
}

__PACKAGE__->meta->make_immutable;
1;
