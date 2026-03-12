package Comserv::Model::Mail;
use Moose;
use namespace::autoclean;
use Email::Simple;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTP;
use Try::Tiny;
use LWP::UserAgent;
use HTTP::Request;
use Comserv::Util::Logging;
use Comserv::Util::HealthLogger;
extends 'Catalyst::Model';

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# Enhanced email sending with detailed logging and error handling
sub send_email {
    my ($self, $c, $to, $subject, $body, $site_id) = @_;
    
    # Use site_id from parameter or session
    $site_id //= $c->session->{site_id};
    
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

    # Use Net::SMTP for more reliable email sending
    require Net::SMTP;
    require MIME::Lite;
    require Authen::SASL;
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'send_email',
        "Using Net::SMTP for email sending");
    
    # Create a MIME::Lite message
    my $msg = MIME::Lite->new(
        From    => $smtp_config->{from},
        To      => $to,
        Subject => $subject,
        Type    => 'text/plain',
        Data    => $body
    );
    
    try {
        # Log SMTP settings for debugging
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'send_email',
            "SMTP settings: " . $smtp_config->{host} . ":" . $smtp_config->{port} . 
            ", SSL: " . ($smtp_config->{ssl} // 'none'));
        
        # Connect to the SMTP server with debug enabled
        my $smtp = Net::SMTP->new(
            $smtp_config->{host},
            Port => $smtp_config->{port},
            Debug => 1,
            Timeout => 30
        );
        
        unless ($smtp) {
            die "Could not connect to SMTP server " . $smtp_config->{host} . ":" . $smtp_config->{port} . ": $!";
        }
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'send_email',
            "Connected to SMTP server " . $smtp_config->{host} . ":" . $smtp_config->{port});
        
        # Start TLS if needed
        my $ssl_setting = $smtp_config->{ssl} // '';
        if ($ssl_setting eq 'starttls' || $ssl_setting eq '1') {
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'send_email',
                "Starting TLS");
            $smtp->starttls() or die "STARTTLS failed: " . $smtp->message();
        }
        
        # Authenticate if credentials are provided
        if ($smtp_config->{username} && $smtp_config->{password}) {
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'send_email',
                "Authenticating as " . $smtp_config->{username});
            $smtp->auth($smtp_config->{username}, $smtp_config->{password}) 
                or die "Authentication failed: " . $smtp->message();
        }
        
        # Send the email
        $smtp->mail($smtp_config->{from}) or die "FROM failed: " . $smtp->message();
        $smtp->to($to) or die "TO failed: " . $smtp->message();
        $smtp->data() or die "DATA failed: " . $smtp->message();
        $smtp->datasend($msg->as_string()) or die "DATASEND failed: " . $smtp->message();
        $smtp->dataend() or die "DATAEND failed: " . $smtp->message();
        $smtp->quit() or die "QUIT failed: " . $smtp->message();
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

    # Retrieve SMTP configuration for the given site_id
    my %smtp_config;
    for my $key (qw(host port username password from ssl)) {
        my $config;
        eval {
            $config = $config_rs->find({ site_id => $site_id, config_key => "smtp_$key" });
        };
        
        if ($@) {
            my $error_msg = $@;
            
            if ($error_msg =~ /Table.*ency\.site_config.*doesn.*exist/i) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_smtp_config', 
                    "CRITICAL: Table 'ency.site_config' doesn't exist when accessing smtp_$key for site_id $site_id. " .
                    "Mail system is incorrectly connecting to localhost instead of production database server (192.168.1.198). " .
                    "Full error: $error_msg");
            } else {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_smtp_config', 
                    "Database error accessing smtp_$key for site_id $site_id: $error_msg");
            }
            
            return $self->_get_fallback_smtp_config($c, $site_id);
        }
        
        # Skip optional fields like ssl
        next if !$config && $key eq 'ssl';
        
        # Return fallback if any required config is missing
        unless ($config) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_smtp_config', 
                "Missing SMTP config key: smtp_$key for site_id $site_id");
            return $self->_get_fallback_smtp_config($c, $site_id);
        }
        
        $smtp_config{$key} = $config->config_value;
        
        # If host is mail1.ht.home, replace it with the mail server IP address
        if ($key eq 'host' && $smtp_config{$key} eq 'mail1.ht.home') {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_smtp_config', 
                "Replacing mail1.ht.home with mail server IP 192.168.1.129");
            $smtp_config{$key} = '192.168.1.129';
        }
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_smtp_config', 
        "Successfully retrieved SMTP config for site_id $site_id");
    
    return \%smtp_config;
}

# Fallback SMTP configuration when database config is unavailable
sub _get_fallback_smtp_config {
    my ($self, $c, $site_id) = @_;
    
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_get_fallback_smtp_config', 
        "Using fallback SMTP config for site_id $site_id");
    
    # Provide default mail server configuration
    my $fallback_config = {
        host => '192.168.1.129',  # Mail server IP
        port => 587,
        username => '',  # Will need to be configured
        password => '',  # Will need to be configured  
        from => "noreply\@comserv.local",
        ssl => 'starttls'
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
