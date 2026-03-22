package Comserv::Model::Mail;
use Moose;
use namespace::autoclean;
use Try::Tiny;
use LWP::UserAgent;
use HTTP::Request;
use Email::MIME;
use Encode qw(encode);
use Comserv::Util::Logging;
use Comserv::Util::HealthLogger;
extends 'Catalyst::Model';

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# Enhanced email sending with detailed logging and error handling
sub send_email {
    my ($self, $c, $to, $subject, $body, $site_id, $opts) = @_;
    $opts ||= {};
    
    # Use site_id from parameter or session — use || not // so empty string falls through
    $site_id ||= $c->session->{site_id};
    $site_id ||= $c->stash->{site_id};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_email',
        "Resolved site_id=" . ($site_id // 'undef') . " (will look up SMTP config from DB)");
    
    # Log the email attempt
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_email', 
        "Attempting to send email to $to for site_id $site_id");

    # Retrieve SMTP configuration from the database
    my $smtp_config = $self->get_smtp_config($c, $site_id);

    # Check if SMTP configuration is available
    unless ($smtp_config) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'send_email', 
            "No SMTP config for site_id $site_id");
        $c->stash->{debug_msg} = "Missing SMTP configuration";
        return;
    }

    # Use Net::SMTP for reliable email sending
    require Net::SMTP;

    my $system_from  = $smtp_config->{from} || 'noreply@computersystemconsulting.ca';
    my $leader_name  = $opts->{leader_name}  || '';
    my $leader_email = $opts->{reply_to}     || '';  # leader's real email

    # SMTP envelope MAIL FROM: use leader's email when provided so PMG relays correctly.
    # If leader has no email, fall back to system address.
    my $smtp_from = $leader_email || $system_from;

    # From: header — what recipients see in their email client.
    my $from_header = $leader_name
        ? qq{"$leader_name" <$smtp_from>}
        : $smtp_from;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_email',
        "Email envelope: MAIL FROM=<$smtp_from> From-header='$from_header' To=<$to>");

    # Build headers for Email::MIME
    my @headers = (
        From    => $from_header,
        To      => $to,
        Subject => $subject,
    );
    push @headers, ('Reply-To' => $leader_email) if $leader_email;

    # Create Email::MIME message (Email::MIME is installed; MIME::Lite is not)
    my $msg = Email::MIME->create(
        header_str => \@headers,
        attributes => {
            encoding => 'quoted-printable',
            charset  => 'UTF-8',
        },
        body_str => $body,
    );

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_email',
        "Message built: From='$from_header' To='$to' Subject='$subject'" .
        ($leader_email ? " Reply-To='$leader_email'" : ''));

    try {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_email',
            "Connecting to SMTP: " . $smtp_config->{host} . ":" . $smtp_config->{port} .
            " ssl=" . ($smtp_config->{ssl} || 'none') .
            " auth=" . ($smtp_config->{user} ? 'yes('.$smtp_config->{user}.')' : 'no'));

        # Determine SSL mode:
        #   ssl='ssl' or port 465 → SSL at connect time (implicit TLS)
        #   ssl='starttls' or port 587 → plain connect then STARTTLS
        #   anything else → plain (port 25, no encryption — LAN relay only)
        my $ssl_setting = lc($smtp_config->{ssl} // '');
        my $port        = $smtp_config->{port} || 25;
        my $use_ssl     = ($ssl_setting eq 'ssl' || $port == 465) ? 1 : 0;
        my $use_starttls = ($ssl_setting eq 'starttls' || $port == 587) ? 1 : 0;

        # Connect to the SMTP server
        my $smtp = Net::SMTP->new(
            $smtp_config->{host},
            Port    => $port,
            SSL     => $use_ssl,
            Debug   => 1,
            Timeout => 15
        );
        
        unless ($smtp) {
            die "CONNECT failed: Could not connect to " . $smtp_config->{host} . ":$port"
              . ($use_ssl ? " (SSL)" : "") . ": $!";
        }
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'send_email',
            "SMTP CONNECT OK: " . $smtp_config->{host} . ":$port" . ($use_ssl ? " (SSL)" : ""));
        
        # STARTTLS upgrade if needed (port 587 / explicit TLS)
        if ($use_starttls) {
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'send_email',
                "SMTP STARTTLS begin");
            $smtp->starttls() or die "STARTTLS failed: " . $smtp->message();
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'send_email',
                "SMTP STARTTLS OK");
        }
        
        # Authenticate if credentials are provided (PMG relay at port 25 needs no auth)
        if ($smtp_config->{user} && $smtp_config->{password}) {
            require Authen::SASL;
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'send_email',
                "SMTP AUTH as " . $smtp_config->{user});
            $smtp->auth($smtp_config->{user}, $smtp_config->{password})
                or die "AUTH failed: " . $smtp->message();
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'send_email',
                "SMTP AUTH OK");
        } else {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'send_email',
                "SMTP no-auth: user='" . ($smtp_config->{user} // '') . "' password=" .
                ($smtp_config->{password} ? '(set)' : '(NOT SET)') .
                " — harper will reject if auth required");
        }
        
        # MAIL FROM
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_email',
            "SMTP MAIL FROM: <$smtp_from>");
        $smtp->mail($smtp_from) or die "MAIL FROM failed: " . $smtp->message();
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'send_email',
            "SMTP MAIL FROM accepted");

        # RCPT TO
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_email',
            "SMTP RCPT TO: <$to>");
        $smtp->to($to) or do {
            my $msg_detail = $smtp->message() || 'no response';
            $smtp->quit();
            die "RCPT TO failed for [$to]: $msg_detail";
        };
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'send_email',
            "SMTP RCPT TO accepted for <$to>");

        # DATA
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'send_email',
            "SMTP DATA begin for <$to>");
        $smtp->data() or die "DATA cmd failed: " . $smtp->message();
        # Encode to UTF-8 bytes — Net::SMTP::datasend cannot handle wide-character Perl strings
        $smtp->datasend(encode('UTF-8', $msg->as_string())) or die "DATASEND failed: " . $smtp->message();
        $smtp->dataend() or die "DATAEND failed: " . $smtp->message();
        $smtp->quit();
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'send_email',
            "SMTP QUIT OK for <$to>");
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_email', 
            "Email sent successfully to $to");
        Comserv::Util::HealthLogger->log_email($c,
            success => 1,
            to      => $to,
            message => "Email sent successfully to $to (subject: $subject)",
            file    => __FILE__,
            line    => __LINE__,
            sub     => 'send_email',
        );
        return 1;
    } catch {
        my $err = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'send_email', 
            "Failed to send email to $to: $err");
        Comserv::Util::HealthLogger->log_email($c,
            success => 0,
            to      => $to,
            message => "Email send failed to $to (subject: $subject): $err",
            details => "smtp_host=" . ($smtp_config->{host} // 'unknown') . " error=$err",
            file    => __FILE__,
            line    => __LINE__,
            sub     => 'send_email',
        );
        $c->stash->{debug_msg} = "Email sending failed: $err";
        return;
    };
}

# Renamed from _get_smtp_config to get_smtp_config for better accessibility
sub get_smtp_config {
    my ($self, $c, $site_id) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_smtp_config', 
        "Retrieving SMTP config for site_id $site_id");
    
    # Use system database access through DBEncy model (database server connection)
    my $config_rs;
    eval {
        $config_rs = $c->model('DBEncy')->resultset('SiteConfig');
    };
    
    if ($@) {
        # Enhanced error logging for specific database issues
        my $error_msg = $@;
        
        if ($error_msg =~ /Table.*ency\.site_config.*doesn.*exist/i) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_smtp_config', 
                "CRITICAL: Database connection error - Table 'ency.site_config' doesn't exist. " .
                "This indicates the mail system is connecting to localhost instead of production database server (192.168.1.198). " .
                "Full error: $error_msg");
        } elsif ($error_msg =~ /Can.*t connect to.*server/i) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_smtp_config', 
                "CRITICAL: Cannot connect to database server. " .
                "Check if database server (192.168.1.198) is accessible. " .
                "Full error: $error_msg");
        } elsif ($error_msg =~ /Access denied for user/i) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_smtp_config', 
                "CRITICAL: Database authentication failed. " .
                "Check database credentials in db_config.json or fallback settings. " .
                "Full error: $error_msg");
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_smtp_config', 
                "Database access error when retrieving SMTP config: $error_msg");
        }
        
        return $self->_get_fallback_smtp_config($c, $site_id);
    }

    # Retrieve SMTP configuration for the given site_id.
    # DB keys: smtp_host, smtp_port, smtp_user, smtp_password, smtp_from, smtp_ssl
    # Internal keys (in returned hashref): host, port, user, password, from, ssl
    # NOTE: user, password, ssl are optional — PMG relay (192.168.1.128:25) needs no auth
    my %smtp_config;
    for my $key (qw(host port user password from ssl)) {
        my $db_key = "smtp_$key";
        my $config;
        eval {
            $config = $config_rs->find({ site_id => $site_id, config_key => $db_key });
        };

        if ($@) {
            my $error_msg = $@;
            if ($error_msg =~ /Table.*ency\.site_config.*doesn.*exist/i) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_smtp_config',
                    "CRITICAL: Table 'ency.site_config' doesn't exist when accessing $db_key for site_id $site_id. " .
                    "Mail system is incorrectly connecting to localhost instead of production database server (192.168.1.198). " .
                    "Full error: $error_msg");
            } else {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_smtp_config',
                    "Database error accessing $db_key for site_id $site_id: $error_msg — using PMG fallback");
            }
            return $self->_get_fallback_smtp_config($c, $site_id);
        }

        # user, password, ssl are optional — skip if not configured.
        # Also check legacy key 'smtp_username' for backwards compatibility with old DB data.
        if (!$config && $key eq 'user') {
            eval {
                $config = $config_rs->find({ site_id => $site_id, config_key => 'smtp_username' });
            };
            if ($config) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_smtp_config',
                    "Found legacy key 'smtp_username' for site_id $site_id (should be 'smtp_user')");
            }
        }
        if (!$config && ($key eq 'ssl' || $key eq 'user' || $key eq 'password')) {
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'get_smtp_config',
                "Optional $db_key not set for site_id $site_id — skipping");
            $smtp_config{$key} = '' if $key eq 'ssl';
            next;
        }

        # Required fields: host, port, from — fall back to PMG if missing
        unless ($config) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_smtp_config',
                "Required $db_key missing for site_id $site_id — using PMG fallback");
            return $self->_get_fallback_smtp_config($c, $site_id);
        }

        $smtp_config{$key} = $config->config_value;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_smtp_config',
        "SMTP config resolved for site_id $site_id: host=" . ($smtp_config{host} // 'undef') .
        " port=" . ($smtp_config{port} // 'undef') .
        " from=" . ($smtp_config{from} // 'undef') .
        " ssl=" . ($smtp_config{ssl} // 'none') .
        " auth=" . ($smtp_config{user} ? 'yes' : 'no'));

    return \%smtp_config;
}

# Fallback SMTP configuration when database config is unavailable
sub _get_fallback_smtp_config {
    my ($self, $c, $site_id) = @_;
    
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_get_fallback_smtp_config', 
        "Using fallback SMTP config for site_id $site_id");
    
    # Provide default mail server configuration - relay through PMG
    my $fallback_config = {
        host => 'harper.whc.ca',  # outbound SMTP server
        port => 465,
        ssl  => 'ssl',
        user => '',
        password => '',
        from => "noreply\@computersystemconsulting.ca",
    };
    
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_get_fallback_smtp_config', 
        "Fallback config provided - mail server: " . $fallback_config->{host});
    
    return $fallback_config;
}

# New method to create mail accounts via Virtualmin API
sub create_mail_account {
    my ($self, $c, $email, $password, $domain) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_mail_account', 
        "Creating mail account $email for domain $domain");

    # Get Virtualmin credentials from configuration - use mail server IP
    my $virtualmin_host = $c->config->{Virtualmin}->{host} // '192.168.1.129';
    my $virtualmin_user = $c->config->{Virtualmin}->{username} // 'admin';
    my $virtualmin_pass = $c->config->{Virtualmin}->{password};
    
    unless ($virtualmin_pass) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_mail_account', 
            "Virtualmin password not configured");
        $c->stash->{debug_msg} = "Virtualmin API credentials not configured";
        return;
    }

    # Use mail server IP address directly if hostname is mail1.ht.home
    if ($virtualmin_host eq 'mail1.ht.home') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_mail_account', 
            "Replacing mail1.ht.home with mail server IP 192.168.1.129 for Virtualmin API");
        $virtualmin_host = '192.168.1.129';
    }
    
    my $ua = LWP::UserAgent->new(ssl_opts => { verify_hostname => 0 });
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
