package Comserv::Util::EmailNotification;
use Moose;
use Email::MIME;
use Email::Sender::Simple;
use Email::Sender::Transport::SMTP;

has 'logging' => (
    is => 'ro',
    required => 1,
);

sub send_verification_email {
    my ($self, $c, $user, $code) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_verification_email',
        "Sending verification email to: " . $user->email);
    
    my $sitename = $c->stash->{SiteName} || 'CSC';
    my $smtp_config = $self->get_smtp_config($c, $sitename);
    
    unless ($smtp_config->{smtp_host}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'send_verification_email',
            "No SMTP configuration found for site $sitename - email not sent");
        return 0;
    }
    
    my $body = qq{
Hello,

Thank you for registering an account with us!

Your verification code is: $code

Please enter this code on the verification page to complete your registration.

This code will expire in 24 hours.

If you did not request this registration, please ignore this email.

Regards,
$sitename Team
};
    
    my $email = Email::MIME->create(
        header_str => [
            From => $smtp_config->{smtp_from} || 'noreply@' . $smtp_config->{smtp_host},
            To => $user->email,
            Subject => "Email Verification Code - $sitename",
        ],
        attributes => {
            encoding => 'quoted-printable',
            charset  => 'UTF-8',
        },
        body_str => $body,
    );
    
    return $self->send_email($c, $email, $smtp_config);
}

sub send_error_notification {
    my ($self, $c, $admin_email, $subject, $error_details) = @_;
    
    unless ($admin_email) {
        $admin_email = 'helpdesk@computersystemconsulting.ca';
    }
    
    my $sitename = $c->stash->{SiteName} || 'CSC';
    my $smtp_config = $self->get_smtp_config($c, $sitename);
    
    unless ($smtp_config->{smtp_host}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'send_error_notification',
            "No SMTP configuration found - error notification not sent");
        return 0;
    }
    
    my $timestamp = localtime();
    my $body = qq{
Error Notification - $sitename

Subject: $subject
Time: $timestamp

Details:
$error_details

This is an automated error notification.
};
    
    my $email = Email::MIME->create(
        header_str => [
            From => $smtp_config->{smtp_from} || 'noreply@' . $smtp_config->{smtp_host},
            To => $admin_email,
            Subject => "[$sitename] $subject",
        ],
        attributes => {
            encoding => 'quoted-printable',
            charset  => 'UTF-8',
        },
        body_str => $body,
    );
    
    return $self->send_email($c, $email, $smtp_config);
}

sub send_admin_registration_notification {
    my ($self, $c, $user) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_admin_notification',
        "Sending admin notification for user: " . $user->username);
    
    my $sitename = $c->stash->{SiteName} || 'CSC';
    my $smtp_config = $self->get_smtp_config($c, $sitename);
    
    unless ($smtp_config->{smtp_host}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'send_admin_notification',
            "No SMTP configuration found - admin notification not sent");
        return 0;
    }
    
    my $site = $c->model('DBEncy')->resultset('Site')->search({ name => $sitename })->single;
    my $admin_email = ($site && $site->mail_to_admin) ? $site->mail_to_admin : 'helpdesk@computersystemconsulting.ca';
    
    my $timestamp = localtime();
    my $body = qq{
New User Registration

A new user has registered on the $sitename system:

Username: } . $user->username . qq{
Email: } . $user->email . qq{
Status: } . $user->status . qq{
Registration Time: $timestamp
User ID: } . $user->id . qq{

The user must verify their email address before they can complete registration.

This is an automated notification.
};
    
    my $email = Email::MIME->create(
        header_str => [
            From => $smtp_config->{smtp_from} || 'noreply@' . $smtp_config->{smtp_host},
            To => $admin_email,
            Subject => "New User Registration: " . $user->username,
        ],
        attributes => {
            encoding => 'quoted-printable',
            charset  => 'UTF-8',
        },
        body_str => $body,
    );
    
    return $self->send_email($c, $email, $smtp_config);
}

sub send_invitation_email {
    my ($self, $c, $user, $code, $login_url, $admin_name) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_invitation_email',
        "Sending invitation email to: " . $user->email);

    my $sitename = $c->stash->{SiteName} || 'CSC';
    my $smtp_config = $self->get_smtp_config($c, $sitename);

    unless ($smtp_config->{smtp_host}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'send_invitation_email',
            "No SMTP configuration found for site $sitename - invitation email not sent");
        return 0;
    }

    my $inviter_line = $admin_name
        ? "$admin_name has created an account for you on $sitename."
        : "An account has been created for you on $sitename.";

    my $name = $user->first_name || 'there';
    my $roles = $user->roles || '';
    my $email_addr = $user->email;

    my $body = qq{
Hello $name,

$inviter_line

To activate your account and set your password, use the verification code below at the login page.

Your invitation code is: $code

Your account details:
  Email: $email_addr
} . ($roles ? "  Role(s): $roles\n" : '') . qq{
To get started:
1. Go to the login page: $login_url
2. Enter your email address and the invitation code above
3. Set your username and password to complete your account setup

This invitation code will expire in 24 hours.

If you did not expect this invitation, please ignore this email or contact support.

Regards,
$sitename Team
};

    my $email = Email::MIME->create(
        header_str => [
            From => $smtp_config->{smtp_from} || 'noreply@' . $smtp_config->{smtp_host},
            To => $user->email,
            Subject => "You Have Been Invited to $sitename",
        ],
        attributes => {
            encoding => 'quoted-printable',
            charset  => 'UTF-8',
        },
        body_str => $body,
    );

    return $self->send_email($c, $email, $smtp_config);
}

sub send_password_reset_email {
    my ($self, $c, $user, $reset_link) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_password_reset_email',
        "Sending password reset email to: " . $user->email);

    my $sitename = $c->stash->{SiteName} || 'CSC';
    my $smtp_config = $self->get_smtp_config($c, $sitename);

    unless ($smtp_config->{smtp_host}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'send_password_reset_email',
            "No SMTP configuration found for site $sitename - password reset email not sent");
        return 0;
    }

    my $name = $user->first_name || $user->username || 'there';

    my $body = qq{
Hello $name,

We received a request to reset the password for your $sitename account.

Click (or copy) the link below to reset your password:

$reset_link

This link will expire in 24 hours and can only be used once.

If you did not request a password reset, you can safely ignore this email. Your password will not be changed.

Regards,
$sitename Team
};

    my $email = Email::MIME->create(
        header_str => [
            From => $smtp_config->{smtp_from} || 'noreply@' . $smtp_config->{smtp_host},
            To => $user->email,
            Subject => "Password Reset Request - $sitename",
        ],
        attributes => {
            encoding => 'quoted-printable',
            charset  => 'UTF-8',
        },
        body_str => $body,
    );

    return $self->send_email($c, $email, $smtp_config);
}

sub send_welcome_email {
    my ($self, $c, $user, $login_url) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_welcome_email',
        "Sending welcome email to: " . $user->email);

    my $sitename = $c->stash->{SiteName} || 'CSC';
    my $smtp_config = $self->get_smtp_config($c, $sitename);

    unless ($smtp_config->{smtp_host}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'send_welcome_email',
            "No SMTP configuration found for site $sitename - welcome email not sent");
        return 0;
    }

    my $name     = $user->first_name || $user->username || 'there';
    my $username = $user->username   || '';
    my $email    = $user->email      || '';
    my $roles    = $user->roles      || '';

    my $body = qq{
Hello $name,

Your account has been successfully activated. Welcome to $sitename!

Your account details:
  Username: $username
  Email: $email
} . ($roles ? "  Role(s): $roles\n" : '') . qq{
You can now log in to your account at: $login_url

From your account you can:
  - View and update your profile
  - Change your password
  - Access $sitename features based on your role

If you have any questions or need assistance, please contact support.

Regards,
$sitename Team
};

    my $email_obj = Email::MIME->create(
        header_str => [
            From => $smtp_config->{smtp_from} || 'noreply@' . $smtp_config->{smtp_host},
            To => $user->email,
            Subject => "Welcome to $sitename!",
        ],
        attributes => {
            encoding => 'quoted-printable',
            charset  => 'UTF-8',
        },
        body_str => $body,
    );

    return $self->send_email($c, $email_obj, $smtp_config);
}

sub send_password_changed_email {
    my ($self, $c, $user, $forgot_password_url) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_password_changed_email',
        "Sending password changed notification to: " . $user->email);

    my $sitename = $c->stash->{SiteName} || 'CSC';
    my $smtp_config = $self->get_smtp_config($c, $sitename);

    unless ($smtp_config->{smtp_host}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'send_password_changed_email',
            "No SMTP configuration found for site $sitename - password changed email not sent");
        return 0;
    }

    my $name       = $user->first_name || $user->username || 'there';
    my $username   = $user->username   || '';
    my $email_addr = $user->email      || '';
    my $changed_at = scalar localtime();

    my $body = qq{
Hello $name,

This email confirms that the password for your $sitename account has been successfully changed.

  Account: $username ($email_addr)
  Changed at: $changed_at

If you made this change, no further action is required.

If you did NOT make this change, your account may have been compromised. Please use the forgot password feature immediately: $forgot_password_url

Then contact support.

Regards,
$sitename Team
};

    my $email = Email::MIME->create(
        header_str => [
            From => $smtp_config->{smtp_from} || 'noreply@' . $smtp_config->{smtp_host},
            To => $user->email,
            Subject => "Your Password Has Been Changed - $sitename",
        ],
        attributes => {
            encoding => 'quoted-printable',
            charset  => 'UTF-8',
        },
        body_str => $body,
    );

    return $self->send_email($c, $email, $smtp_config);
}

sub send_account_suspended_email {
    my ($self, $c, $user) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_account_suspended_email',
        "Sending account suspended notification to: " . $user->email);

    my $sitename = $c->stash->{SiteName} || 'CSC';
    my $smtp_config = $self->get_smtp_config($c, $sitename);

    unless ($smtp_config->{smtp_host}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'send_account_suspended_email',
            "No SMTP configuration found for site $sitename - account suspended email not sent");
        return 0;
    }

    my $name       = $user->first_name || $user->username || 'there';
    my $username   = $user->username   || '';
    my $email_addr = $user->email      || '';
    my $suspended_at = scalar localtime();

    my $body = qq{
Hello $name,

Your $sitename account has been suspended.

  Account: $username ($email_addr)
  Suspended at: $suspended_at

While your account is suspended, you will not be able to log in to $sitename.

If you believe this suspension was made in error or you would like to appeal, please contact the site administrator.

Regards,
$sitename Team
};

    my $email = Email::MIME->create(
        header_str => [
            From => $smtp_config->{smtp_from} || 'noreply@' . $smtp_config->{smtp_host},
            To => $user->email,
            Subject => "Your $sitename Account Has Been Suspended",
        ],
        attributes => {
            encoding => 'quoted-printable',
            charset  => 'UTF-8',
        },
        body_str => $body,
    );

    return $self->send_email($c, $email, $smtp_config);
}

sub send_admin_verification_alert {
    my ($self, $c, $user, $reason) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_admin_verification_alert',
        "Sending verification alert to admin for user: " . $user->username);

    my $sitename    = $c->stash->{SiteName} || 'CSC';
    my $smtp_config = $self->get_smtp_config($c, $sitename);

    unless ($smtp_config->{smtp_host}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'send_admin_verification_alert',
            "No SMTP configuration — alert not sent");
        return 0;
    }

    my $site        = $c->model('DBEncy')->resultset('Site')->search({ name => $sitename })->single;
    my $admin_email = ($site && $site->mail_to_admin)
        ? $site->mail_to_admin
        : 'helpdesk@computersystemconsulting.ca';

    my $timestamp  = scalar localtime;
    my $admin_link = $c->uri_for('/user/admin_resend_verification', { user_id => $user->id })->as_string;

    my $body = qq{
Verification Problem — $sitename
Time: $timestamp

A user is having trouble completing email verification:

  Username : } . $user->username . qq{
  Email    : } . $user->email . qq{
  User ID  : } . $user->id . qq{
  Status   : } . ($user->status || 'unknown') . qq{
  Reason   : $reason

ACTION: You can resend a verification code for this user via:
  $admin_link

Or log in to the admin panel and resend from the user management page.

This is an automated notification.
};

    my $email = Email::MIME->create(
        header_str => [
            From    => $smtp_config->{smtp_from} || 'noreply@' . $smtp_config->{smtp_host},
            To      => $admin_email,
            Subject => "[$sitename] Verification problem: " . $user->username,
        ],
        attributes => {
            encoding => 'quoted-printable',
            charset  => 'UTF-8',
        },
        body_str => $body,
    );

    return $self->send_email($c, $email, $smtp_config);
}

sub get_smtp_config {
    my ($self, $c, $sitename) = @_;
    
    my %config = ();
    my $site = $c->model('DBEncy')->resultset('Site')->search({ name => $sitename })->single;
    
    if ($site) {
        my $configs = $c->model('DBEncy')->resultset('SiteConfig')->search({
            site_id => $site->id,
            config_key => { -like => 'smtp_%' }
        });
        
        while (my $cfg = $configs->next) {
            $config{$cfg->config_key} = $cfg->config_value;
        }
    }

    if ($config{smtp_host}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_smtp_config',
            "Using configured smtp_host '$config{smtp_host}' for site '$sitename'");
    } else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_smtp_config',
            "No smtp_host in DB for site '$sitename' — using harper fallback");
        $config{smtp_host} = 'harper.whc.ca';
        $config{smtp_port} = 465;
        $config{smtp_ssl}  = 'ssl';
        $config{smtp_from} = $config{smtp_from} || 'noreply@computersystemconsulting.ca';
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_smtp_config',
        "SMTP config for '$sitename': host=$config{smtp_host} port=" . ($config{smtp_port}||25) .
        " from=" . ($config{smtp_from}||'(none)'));

    return \%config;
}

sub send_email {
    my ($self, $c, $email, $smtp_config) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_email',
        "Attempting to send email to: " . $email->header('To') . 
        " via SMTP: " . $smtp_config->{smtp_host} . ":" . ($smtp_config->{smtp_port} || 587));
    
    my $use_ssl = ($smtp_config->{smtp_ssl} && $smtp_config->{smtp_ssl} ne '0') ? 1 : 0;
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'send_email',
        "SMTP Config: host=" . $smtp_config->{smtp_host} . 
        ", port=" . ($smtp_config->{smtp_port} || 587) . 
        ", ssl=" . ($use_ssl ? 'yes' : 'no') .
        ", username=" . ($smtp_config->{smtp_username} || 'none'));
    
    my $transport;
    eval {
        $transport = Email::Sender::Transport::SMTP->new({
            host => $smtp_config->{smtp_host},
            port => $smtp_config->{smtp_port} || 587,
            ssl => $use_ssl,
            sasl_username => $smtp_config->{smtp_username},
            sasl_password => $smtp_config->{smtp_password},
        });
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'send_email',
            "SMTP transport created successfully");
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'send_email',
            "Failed to create SMTP transport: $@");
        return 0;
    }
    
    eval {
        Email::Sender::Simple->send($email, { transport => $transport });
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_email',
            "Email sent successfully to: " . $email->header('To'));
        return 1;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'send_email',
            "Failed to send email: $@");
        return 0;
    }
}

__PACKAGE__->meta->make_immutable;
1;
