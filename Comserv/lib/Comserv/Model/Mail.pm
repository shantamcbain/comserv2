package Comserv::Model::Mail;
use Moose;
use namespace::autoclean;
use Try::Tiny;
use LWP::UserAgent;
use HTTP::Request;
use Comserv::Util::Logging;
extends 'Catalyst::Model';

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub send_email {
    my ($self, $c, $to, $subject, $body, $site_id_or_name, $opts) = @_;
    $opts //= {};

    my $site_identifier = $site_id_or_name
        // $c->session->{SiteName}
        // $c->session->{site_id};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_email',
        "Attempting to send email to $to (site: " . ($site_identifier // 'undef') . ")");

    my $smtp_config = $self->get_smtp_config($c, $site_identifier);

    unless ($smtp_config) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'send_email',
            "No SMTP config available for site: " . ($site_identifier // 'undef'));
        $c->stash->{debug_msg} = "Missing SMTP configuration";
        return;
    }

    require Net::SMTP;
    require MIME::Lite;

    my $from_addr = $opts->{from} || $smtp_config->{from};
    my $reply_to  = $opts->{reply_to};

    my $msg = MIME::Lite->new(
        From    => $from_addr,
        To      => $to,
        Subject => $subject,
        Type    => 'text/plain',
        Data    => $body
    );
    $msg->add('Reply-To' => $reply_to) if $reply_to;

    try {
        my $ssl_setting = lc($smtp_config->{ssl} // '');

        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'send_email',
            "SMTP: " . $smtp_config->{host} . ":" . $smtp_config->{port} . " ssl=" . ($ssl_setting || 'none'));

        my %smtp_args = (
            Port    => $smtp_config->{port},
            Debug   => 1,
            Timeout => 30,
        );

        if ($ssl_setting eq 'ssl') {
            $smtp_args{SSL} = 1;
        }

        my $smtp = Net::SMTP->new($smtp_config->{host}, %smtp_args);
        unless ($smtp) {
            die "Could not connect to SMTP server " . $smtp_config->{host} . ":" . $smtp_config->{port} . ": $!";
        }

        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'send_email',
            "Connected to SMTP server");

        if ($ssl_setting eq 'starttls') {
            $smtp->starttls() or die "STARTTLS failed: " . $smtp->message();
        }

        if ($smtp_config->{username} && $smtp_config->{password}) {
            require Authen::SASL;
            $smtp->auth($smtp_config->{username}, $smtp_config->{password})
                or die "Authentication failed: " . $smtp->message();
        }

        $smtp->mail($smtp_config->{from}) or die "FROM failed: " . $smtp->message();
        $smtp->to($to)                    or die "TO failed: "   . $smtp->message();
        $smtp->data()                     or die "DATA failed: " . $smtp->message();
        $smtp->datasend($msg->as_string()) or die "DATASEND failed: " . $smtp->message();
        $smtp->dataend()                  or die "DATAEND failed: " . $smtp->message();
        $smtp->quit();

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_email',
            "Email sent successfully to $to");
        return 1;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'send_email',
            "Failed to send email to $to: $_");
        $c->stash->{debug_msg} = "Email sending failed: $_";
        return;
    };
}

sub get_smtp_config {
    my ($self, $c, $site_id_or_name) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_smtp_config',
        "Retrieving SMTP config for: " . ($site_id_or_name // 'undef'));

    my $site_id;

    if (defined $site_id_or_name && $site_id_or_name !~ /^\d+$/) {
        eval {
            my $site = $c->model('DBEncy')->resultset('Site')->find({ name => $site_id_or_name });
            $site_id = $site->id if $site;
        };
        if ($@ || !defined $site_id) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_smtp_config',
                "Could not resolve site_name '$site_id_or_name' to site_id: " . ($@ // 'not found'));
            return $self->_get_fallback_smtp_config($c, $site_id_or_name);
        }
    } else {
        $site_id = $site_id_or_name;
    }

    unless (defined $site_id) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_smtp_config',
            "No site_id available, using fallback");
        return $self->_get_fallback_smtp_config($c, 'unknown');
    }

    my $config_rs;
    eval {
        $config_rs = $c->model('DBEncy')->resultset('SiteConfig');
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_smtp_config',
            "Database access error: $@");
        return $self->_get_fallback_smtp_config($c, $site_id);
    }

    my %smtp_config;
    my %key_map = (
        host     => 'smtp_host',
        port     => 'smtp_port',
        username => 'smtp_user',
        password => 'smtp_password',
        from     => 'smtp_from',
        ssl      => 'smtp_ssl',
    );

    for my $internal_key (sort keys %key_map) {
        my $db_key = $key_map{$internal_key};
        my $config;
        eval {
            $config = $config_rs->find({ site_id => $site_id, config_key => $db_key });
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_smtp_config',
                "Error accessing $db_key for site_id $site_id: $@");
            return $self->_get_fallback_smtp_config($c, $site_id);
        }

        next if !$config && ($internal_key eq 'ssl' || $internal_key eq 'username' || $internal_key eq 'password');

        unless ($config) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_smtp_config',
                "Missing required SMTP config key: $db_key for site_id $site_id, using fallback");
            return $self->_get_fallback_smtp_config($c, $site_id);
        }

        $smtp_config{$internal_key} = $config->config_value;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_smtp_config',
        "Successfully retrieved SMTP config for site_id $site_id");

    return \%smtp_config;
}

sub _get_fallback_smtp_config {
    my ($self, $c, $site_identifier) = @_;

    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_get_fallback_smtp_config',
        "Using fallback SMTP config for: " . ($site_identifier // 'undef'));

    my $app_cfg = $c->config->{FallbackSMTP} // {};

    return {
        host     => $app_cfg->{host}     // 'harper.whc.ca',
        port     => $app_cfg->{port}     // 465,
        username => $app_cfg->{username} // '',
        password => $app_cfg->{password} // '',
        from     => $app_cfg->{from}     // $c->stash->{mail_from} // 'noreply@localhost',
        ssl      => $app_cfg->{ssl}      // 'ssl',
    };
}

sub test_send_email {
    my ($self, $c, $site_name, $to) = @_;

    $to //= $c->session->{email} || 'admin@localhost';

    return $self->send_email(
        $c,
        $to,
        'SMTP Test Email',
        "This is a test email from the Comserv mail system.\n\nIf you received this, SMTP is configured correctly for site: $site_name\n",
        $site_name
    );
}

sub create_mail_account {
    my ($self, $c, $email, $password, $domain) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_mail_account',
        "Creating mail account $email for domain $domain");

    my $virtualmin_host = $c->config->{Virtualmin}->{host} // '192.168.1.129';
    my $virtualmin_user = $c->config->{Virtualmin}->{username} // 'admin';
    my $virtualmin_pass = $c->config->{Virtualmin}->{password};

    unless ($virtualmin_pass) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_mail_account',
            "Virtualmin password not configured");
        $c->stash->{debug_msg} = "Virtualmin API credentials not configured";
        return;
    }

    if ($virtualmin_host eq 'mail1.ht.home') {
        $virtualmin_host = '192.168.1.129';
    }

    my $ua  = LWP::UserAgent->new(ssl_opts => { verify_hostname => 0 });
    my $req = HTTP::Request->new(POST => "https://$virtualmin_host:10000/virtual-server/remote.cgi");
    $req->authorization_basic($virtualmin_user, $virtualmin_pass);

    my ($user) = split(/@/, $email);
    $req->content("program=create-user&domain=$domain&user=$user&pass=$password&mail=on");

    try {
        my $res = $ua->request($req);
        if ($res->is_success) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_mail_account',
                "Created mail account $email successfully");
            return 1;
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_mail_account',
                "Failed to create mail account $email: " . $res->status_line);
            $c->stash->{debug_msg} = "Mail account creation failed: " . $res->status_line;
            return;
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_mail_account',
            "Virtualmin API error: $_");
        $c->stash->{debug_msg} = "Virtualmin API error: $_";
        return;
    };
}

__PACKAGE__->meta->make_immutable;

1;
