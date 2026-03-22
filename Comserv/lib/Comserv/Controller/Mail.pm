package Comserv::Controller::Mail;
use Moose;
use namespace::autoclean;
use Try::Tiny;
use Comserv::Util::Logging;
BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub index :Path :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "Accessing mail index page");

    $c->stash(template => 'user/mail.tt');
    $c->forward($c->view('TT'));
}

sub send_welcome_email :Local {
    my ($self, $c, $user) = @_;

    my $site_id = $user->site_id;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_welcome_email',
        "Sending welcome email to " . $user->email);

    try {
        my $mail_model = $c->model('Mail');
        my $subject    = "Welcome to the Application";
        my $body       = "Hello " . $user->first_name . ",\n\nWelcome to our application!";

        my $result = $mail_model->send_email($c, $user->email, $subject, $body, $site_id);

        unless ($result) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'send_welcome_email',
                "Failed to send welcome email to " . $user->email);
            $c->stash->{debug_msg} = "Could not send welcome email";
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'send_welcome_email',
            "Welcome email error: $_");
        $c->stash->{debug_msg} = "Welcome email failed: $_";
    };
}

sub smtp_settings :Local {
    my ($self, $c) = @_;

    my $site_name = $c->req->param('site_name') || $c->session->{SiteName};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'smtp_settings',
        "Displaying SMTP settings for site: " . ($site_name // 'undef'));

    my $smtp_config = {};

    if ($site_name) {
        try {
            my $site = $c->model('DBEncy')->resultset('Site')->find({ name => $site_name });
            if ($site) {
                my $site_id  = $site->id;
                my $cfg_rs   = $c->model('DBEncy')->resultset('SiteConfig');

                for my $key (qw(smtp_host smtp_port smtp_user smtp_password smtp_from smtp_ssl)) {
                    my $row = $cfg_rs->find({ site_id => $site_id, config_key => $key });
                    $smtp_config->{$key} = $row ? $row->config_value : '';
                }
            }
        } catch {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'smtp_settings',
                "Error loading SMTP settings: $_");
            $c->stash->{error_msg} = "Error loading SMTP settings: $_";
        };
    }

    $c->stash(
        smtp_config => $smtp_config,
        site_name   => $site_name,
        template    => 'mail/smtp_settings.tt',
    );
    $c->forward($c->view('TT'));
}

sub save_smtp_settings :Local {
    my ($self, $c) = @_;

    my $params    = $c->req->params;
    my $site_name = $params->{site_name} || $c->session->{SiteName};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'save_smtp_settings',
        "Saving SMTP settings for site: " . ($site_name // 'undef'));

    unless ($site_name) {
        $c->stash->{error_msg} = "Site name is required";
        $c->res->redirect($c->uri_for($self->action_for('smtp_settings')));
        return;
    }

    unless ($params->{smtp_host} && $params->{smtp_port}) {
        $c->stash->{error_msg} = "SMTP host and port are required";
        $c->res->redirect($c->uri_for($self->action_for('smtp_settings'), { site_name => $site_name }));
        return;
    }

    try {
        my $site = $c->model('DBEncy')->resultset('Site')->find({ name => $site_name });

        unless ($site) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'save_smtp_settings',
                "Site not found: $site_name");
            $c->stash->{error_msg} = "Site '$site_name' not found";
            $c->res->redirect($c->uri_for($self->action_for('smtp_settings'), { site_name => $site_name }));
            return;
        }

        my $site_id  = $site->id;
        my $cfg_rs   = $c->model('DBEncy')->resultset('SiteConfig');

        for my $key (qw(smtp_host smtp_port smtp_user smtp_password smtp_from smtp_ssl)) {
            next unless defined $params->{$key};
            $cfg_rs->update_or_create({
                site_id      => $site_id,
                config_key   => $key,
                config_value => $params->{$key},
            });
        }

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'save_smtp_settings',
            "SMTP settings saved for site: $site_name");
        $c->flash->{status_msg} = "SMTP settings saved successfully";
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'save_smtp_settings',
            "Failed to save SMTP settings: $_");
        $c->flash->{error_msg} = "Failed to save settings: $_";
    };

    $c->res->redirect($c->uri_for($self->action_for('smtp_settings'), { site_name => $site_name }));
}

sub test_send :Local {
    my ($self, $c) = @_;

    my $params    = $c->req->params;
    my $site_name = $params->{site_name} || $c->session->{SiteName};
    my $to        = $params->{test_to}   || $c->session->{email};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_send',
        "Sending test email for site: " . ($site_name // 'undef') . " to: " . ($to // 'undef'));

    unless ($to && $to =~ /\@/) {
        $c->flash->{error_msg} = "Please provide a valid recipient email address for the test";
        $c->res->redirect($c->uri_for($self->action_for('smtp_settings'), { site_name => $site_name }));
        return;
    }

    my $result = $c->model('Mail')->test_send_email($c, $site_name, $to);

    if ($result) {
        $c->flash->{status_msg} = "Test email sent successfully to $to";
    } else {
        $c->flash->{error_msg} = "Test email failed — check the SMTP settings and server logs";
    }

    $c->res->redirect($c->uri_for($self->action_for('smtp_settings'), { site_name => $site_name }));
}

sub add_mail_config_form :Local {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_mail_config_form',
        "Displaying mail configuration form");

    $c->stash(template => 'mail/add_mail_config_form.tt');
    $c->forward($c->view('TT'));
}

sub add_mail_config :Local {
    my ($self, $c) = @_;

    my $params    = $c->req->params;
    my $site_name = $params->{site_name};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_mail_config',
        "Processing mail configuration for site: " . ($site_name // 'undef'));

    unless ($params->{smtp_host} && $params->{smtp_port}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_mail_config',
            "Incomplete SMTP config");
        $c->stash->{debug_msg} = "Please provide SMTP host and port";
        $c->stash(template => 'mail/add_mail_config_form.tt');
        return;
    }

    unless ($site_name) {
        $c->stash->{debug_msg} = "Site name is required";
        $c->stash(template => 'mail/add_mail_config_form.tt');
        return;
    }

    try {
        my $site = $c->model('DBEncy')->resultset('Site')->find({ name => $site_name });

        unless ($site) {
            $c->stash->{debug_msg} = "Site '$site_name' not found";
            $c->stash(template => 'mail/add_mail_config_form.tt');
            return;
        }

        my $site_id = $site->id;
        my $cfg_rs  = $c->model('DBEncy')->resultset('SiteConfig');

        for my $key (qw(smtp_host smtp_port smtp_user smtp_password smtp_from smtp_ssl)) {
            next unless defined $params->{$key};
            $cfg_rs->update_or_create({
                site_id      => $site_id,
                config_key   => $key,
                config_value => $params->{$key},
            });
        }

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_mail_config',
            "SMTP config saved for site: $site_name");
        $c->stash->{status_msg} = "SMTP configuration saved successfully";
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_mail_config',
            "Failed to save SMTP config: $_");
        $c->stash->{debug_msg} = "Failed to save configuration: $_";
    };

    $c->res->redirect($c->uri_for($self->action_for('add_mail_config_form')));
}

sub create_mail_account :Local {
    my ($self, $c) = @_;

    my $params   = $c->req->params;
    my $email    = $params->{email};
    my $password = $params->{password};
    my $domain   = $params->{domain};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_mail_account',
        "Creating mail account for $email on domain $domain");

    unless ($email && $password && $domain) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_mail_account',
            "Missing required parameters for mail account creation");
        $c->stash->{debug_msg} = "Email, password, and domain are required";
        return;
    }

    unless ($email =~ /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_mail_account',
            "Invalid email format: $email");
        $c->stash->{debug_msg} = "Invalid email format";
        return;
    }

    try {
        my $result = $c->model('Mail')->create_mail_account($c, $email, $password, $domain);

        if ($result) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_mail_account',
                "Mail account created successfully for $email");
            $c->stash->{status_msg} = "Mail account created successfully";
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_mail_account',
                "Failed to create mail account for $email");
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_mail_account',
            "Error creating mail account: $_");
        $c->stash->{debug_msg} = "Error creating mail account: $_";
    };

    if ($c->req->params->{redirect_url}) {
        $c->res->redirect($c->req->params->{redirect_url});
    } else {
        $c->res->redirect($c->uri_for('/mail'));
    }
}

__PACKAGE__->meta->make_immutable;
1;
