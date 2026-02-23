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
    my $admin_email = $site ? $site->mail_to_admin : 'admin@localhost';
    
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
    
    return \%config;
}

sub send_email {
    my ($self, $c, $email, $smtp_config) = @_;
    
    my $transport = Email::Sender::Transport::SMTP->new({
        host => $smtp_config->{smtp_host},
        port => $smtp_config->{smtp_port} || 587,
        ssl => ($smtp_config->{smtp_ssl} && $smtp_config->{smtp_ssl} ne '0') ? 1 : 0,
        sasl_username => $smtp_config->{smtp_username},
        sasl_password => $smtp_config->{smtp_password},
    });
    
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
