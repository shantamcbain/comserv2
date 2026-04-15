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
    
    my $sitename = ($c && ref($c) && $c->stash) ? ($c->stash->{SiteName} || 'CSC') : 'CSC';
    my $smtp_config = $self->get_smtp_config($c, $sitename);
    
    # If no SMTP config was found (especially if $c was missing), try to load a default one
    unless ($smtp_config && $smtp_config->{smtp_host}) {
        $smtp_config = $self->_get_default_smtp_config();
    }
    
    unless ($smtp_config && $smtp_config->{smtp_host}) {
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

sub send_hosting_signup_notification {
    my ($self, $c, $account) = @_;

    my $smtp_config = $self->get_smtp_config($c, 'CSC');
    return 0 unless $smtp_config->{smtp_host};

    my $csc_site    = $c->model('DBEncy')->resultset('Site')->search({ name => 'CSC' })->single;
    my $csc_email   = ($csc_site && $csc_site->mail_to_admin)
        ? $csc_site->mail_to_admin
        : 'helpdesk@computersystemconsulting.ca';

    my $timestamp   = scalar localtime;
    my $approve_url = $c->uri_for('/membership/admin/hosting_accounts')->as_string;

    my $body = qq{
CSC Hosting Registration Request
Time: $timestamp

A SiteName admin has submitted a hosting registration request:

  SiteName      : ${\$account->sitename}
  Plan          : ${\($account->plan_slug || 'not selected')}
  Domain Type   : ${\($account->domain_type || 'subdomain')}
  Domain        : ${\($account->domain || 'not specified')}
  Contact Email : ${\($account->contact_email || 'not provided')}
  Notes         : ${\($account->notes || 'none')}

ACTION: Review and approve this request at:
  $approve_url

This is an automated notification from the Comserv platform.
};

    my $email = Email::MIME->create(
        header_str => [
            From    => $smtp_config->{smtp_from} || 'noreply@computersystemconsulting.ca',
            To      => $csc_email,
            Subject => "[CSC] Hosting registration request: " . $account->sitename,
        ],
        attributes => { encoding => 'quoted-printable', charset => 'UTF-8' },
        body_str   => $body,
    );

    return $self->send_email($c, $email, $smtp_config);
}

sub send_hosting_signup_confirmation {
    my ($self, $c, $account) = @_;

    my $contact_email = $account->contact_email;
    return 0 unless $contact_email;

    my $smtp_config = $self->get_smtp_config($c, 'CSC');
    return 0 unless $smtp_config->{smtp_host};

    my $timestamp  = scalar localtime;
    my $addons_str = $account->requested_addons || 'none';

    my $body = qq{
CSC Hosting — Registration Received
Time: $timestamp

Thank you for registering with CSC hosting!

  SiteName      : ${\$account->sitename}
  Plan          : ${\($account->plan_slug || 'N/A')}
  Domain        : ${\($account->domain || 'To be confirmed')}
  Domain Type   : ${\($account->domain_type || 'subdomain')}
  Add-ons       : $addons_str

Your registration is now pending CSC review. You will receive
another email once your account is approved and active.

If you have questions contact us at helpdesk\@computersystemconsulting.ca.

This is an automated notification from the Comserv platform.
};

    my $email = Email::MIME->create(
        header_str => [
            From    => $smtp_config->{smtp_from} || 'noreply@computersystemconsulting.ca',
            To      => $contact_email,
            Subject => "[CSC] Hosting registration received for " . $account->sitename,
        ],
        attributes => { encoding => 'quoted-printable', charset => 'UTF-8' },
        body_str   => $body,
    );

    return $self->send_email($c, $email, $smtp_config);
}

sub send_hosting_approval_notification {
    my ($self, $c, $account) = @_;

    my $contact_email = $account->contact_email;
    return 0 unless $contact_email;

    my $smtp_config = $self->get_smtp_config($c, 'CSC');
    return 0 unless $smtp_config->{smtp_host};

    my $timestamp   = scalar localtime;
    my $membership_url = $c->uri_for('/membership')->as_string;

    my $body = qq{
CSC Hosting — Registration Approved
Time: $timestamp

Your SiteName has been approved for CSC hosting!

  SiteName      : ${\$account->sitename}
  Plan          : ${\($account->plan_slug || 'N/A')}
  Domain        : ${\($account->domain || 'To be configured')}
  Status        : Active
  Monthly Cost  : CAD ${\$account->monthly_cost}/mo

Your members can now sign up for hosting plans at:
  $membership_url

If you have questions, contact CSC at helpdesk\@computersystemconsulting.ca.

This is an automated notification from the Comserv platform.
};

    my $email = Email::MIME->create(
        header_str => [
            From    => $smtp_config->{smtp_from} || 'noreply@computersystemconsulting.ca',
            To      => $contact_email,
            Subject => "[CSC] Your hosting for " . $account->sitename . " is now active",
        ],
        attributes => { encoding => 'quoted-printable', charset => 'UTF-8' },
        body_str   => $body,
    );

    return $self->send_email($c, $email, $smtp_config);
}

sub send_hosting_invoice_notification {
    my ($self, $c, %args) = @_;
    my $smtp_config = $self->get_smtp_config($c, 'CSC');
    return 0 unless $smtp_config->{smtp_host} && $args{contact_email};

    my $timestamp   = scalar localtime;
    my $invoice_url = $c->uri_for('/Inventory/invoice/view/' . $args{invoice_id})->as_string;
    my $status_line = $args{pts_paid}
        ? "PAID — $args{pts_paid} pts debited automatically"
        : "OUTSTANDING — please pay at the link below";

    my $body = qq{
CSC Hosting — Invoice
Time: $timestamp

A hosting invoice has been created for $args{sitename}.

  Invoice       : $args{invoice_number}
  Plan          : $args{plan_slug}
  Amount        : CAD $args{amount}/mo
  Due Date      : $args{due_date}
  Status        : $status_line

View and pay invoice:
  $invoice_url

Payment can be made with Points (1 pt = CAD 1.00) from your Inventory → Supplier Invoices page.

If you have questions contact helpdesk\@computersystemconsulting.ca.

This is an automated notification from the Comserv platform.
};

    my $email = Email::MIME->create(
        header_str => [
            From    => $smtp_config->{smtp_from} || 'noreply@computersystemconsulting.ca',
            To      => $args{contact_email},
            Subject => "[CSC] Hosting Invoice $args{invoice_number} — CAD $args{amount}",
        ],
        attributes => { encoding => 'quoted-printable', charset => 'UTF-8' },
        body_str   => $body,
    );
    $self->send_email($c, $email, $smtp_config);

    # CC to CSC helpdesk
    my $cc = Email::MIME->create(
        header_str => [
            From    => $smtp_config->{smtp_from} || 'noreply@computersystemconsulting.ca',
            To      => 'helpdesk@computersystemconsulting.ca',
            Subject => "[CSC] Invoice issued — $args{invoice_number} to $args{sitename}",
        ],
        attributes => { encoding => 'quoted-printable', charset => 'UTF-8' },
        body_str   => $body,
    );
    return $self->send_email($c, $cc, $smtp_config);
}

sub send_invoice_payment_notification {
    my ($self, $c, %args) = @_;
    # args: invoice_number, sitename (payer), amount, points, invoice_id

    my $smtp_config = $self->get_smtp_config($c, 'CSC');
    return 0 unless $smtp_config->{smtp_host};

    my $timestamp   = scalar localtime;
    my $invoice_url = $c->uri_for('/Inventory/invoice/view/' . $args{invoice_id})->as_string;

    my $body = qq{
CSC Hosting — Payment Received
Time: $timestamp

A hosting invoice has been paid.

  Invoice       : $args{invoice_number}
  Paid by       : $args{sitename}
  Amount        : CAD $args{amount}
  Points debited: $args{points} pts

View invoice: $invoice_url

This is an automated notification from the Comserv platform.
};

    my $csc_email = Email::MIME->create(
        header_str => [
            From    => $smtp_config->{smtp_from} || 'noreply@computersystemconsulting.ca',
            To      => 'helpdesk@computersystemconsulting.ca',
            Subject => "[CSC] Payment received — $args{invoice_number} from $args{sitename}",
        ],
        attributes => { encoding => 'quoted-printable', charset => 'UTF-8' },
        body_str   => $body,
    );
    $self->send_email($c, $csc_email, $smtp_config);

    # Receipt to the paying SiteName contact
    my $contact_email = $args{contact_email};
    if ($contact_email) {
        my $receipt = Email::MIME->create(
            header_str => [
                From    => $smtp_config->{smtp_from} || 'noreply@computersystemconsulting.ca',
                To      => $contact_email,
                Subject => "[CSC] Payment confirmed — $args{invoice_number}",
            ],
            attributes => { encoding => 'quoted-printable', charset => 'UTF-8' },
            body_str   => qq{
CSC Hosting — Payment Confirmed
Time: $timestamp

Your hosting invoice has been paid.

  Invoice       : $args{invoice_number}
  Amount        : CAD $args{amount}
  Points used   : $args{points} pts
  Status        : Paid

Thank you! If you have questions contact helpdesk\@computersystemconsulting.ca.

This is an automated notification from the Comserv platform.
},
        );
        $self->send_email($c, $receipt, $smtp_config);
    }

    return 1;
}

sub get_smtp_config {
    my ($self, $c, $sitename) = @_;
    
    my %config = ();
    
    # If $c is missing, we can't search the database easily via the model
    # Return empty config and let the caller handle it or use default
    return \%config unless $c && ref($c) && $c->can('model');

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
        # No DB config — fall back to harper for outbound delivery
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

sub _get_default_smtp_config {
    my ($self) = @_;

    my %config = (
        smtp_host     => $ENV{SMTP_HOST}     || '192.168.1.128',
        smtp_port     => $ENV{SMTP_PORT}     || 25,
        smtp_ssl      => $ENV{SMTP_SSL}      || 0,
        smtp_user     => $ENV{SMTP_USER}     || '',
        smtp_password => $ENV{SMTP_PASS}     || '',
        smtp_from     => $ENV{SMTP_FROM}     || 'helpdesk@computersystemconsulting.ca',
    );

    return \%config;
}

sub send_email {
    my ($self, $c, $email, $smtp_config) = @_;

    my $to      = $email->header('To');
    my $subject = $email->header('Subject');

    # body_str can die if content-transfer-encoding is not decoded text — guard it
    my $body = eval { $email->body_str } // do {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'send_email',
            "body_str failed for email to $to — falling back to raw body");
        $email->body;
    };

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_email',
        "EmailNotification delegating to Model::Mail: to=$to subject='$subject'");

    # Resolve site_id from stash SiteName
    my $site_id;
    if ($c && ref($c) && $c->can('model') && $c->stash && $c->stash->{SiteName}) {
        eval {
            my $site = $c->model('DBEncy')->resultset('Site')->find({ name => $c->stash->{SiteName} });
            $site_id = $site->id if $site;
        };
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'send_email',
            "Resolved site_id=" . ($site_id // 'undef') . " for SiteName=" . $c->stash->{SiteName});
    }

    if ($c && ref($c) && $c->can('model')) {
        my $result = eval {
            $c->model('Mail')->send_email($c, $to, $subject, $body, $site_id);
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'send_email',
                "Model::Mail->send_email threw exception for $to: $@");
            return 0;
        }
        unless ($result) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'send_email',
                "Model::Mail->send_email returned failure for $to (check SMTP logs above)");
        }
        return $result || 0;
    } else {
        $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'send_email',
            "No Catalyst context available for email to $to — using direct SMTP fallback");
        return $self->_direct_smtp_send($email, $smtp_config);
    }
}

sub _direct_smtp_send {
    my ($self, $email, $smtp_config) = @_;
    $smtp_config //= {};
    my $host = $smtp_config->{smtp_host} || '192.168.1.128';
    my $port = $smtp_config->{smtp_port} || 25;
    my $to   = $email->header('To') || 'unknown';

    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_direct_smtp_send',
        "Direct SMTP fallback: host=$host port=$port to=$to");

    my %transport_args = (
        host    => $host,
        port    => $port,
        timeout => 10,
    );
    if ($smtp_config->{smtp_user} && $smtp_config->{smtp_password}) {
        $transport_args{sasl_username} = $smtp_config->{smtp_user};
        $transport_args{sasl_password} = $smtp_config->{smtp_password};
    }

    my $result = eval {
        my $transport = Email::Sender::Transport::SMTP->new(\%transport_args);
        Email::Sender::Simple->send($email, { transport => $transport });
        1;
    };
    if ($@) {
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_direct_smtp_send',
            "Direct SMTP failed for $to via $host:$port: $@");
        return 0;
    }
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_direct_smtp_send',
        "Direct SMTP sent OK to $to via $host:$port");
    return 1;
}

__PACKAGE__->meta->make_immutable;
1;
