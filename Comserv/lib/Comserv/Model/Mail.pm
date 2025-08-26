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
        return 1;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'send_email', 
            "Failed to send email to $to: $_");
        $c->stash->{debug_msg} = "Email sending failed: $_";
        return;
    };
}

# Renamed from _get_smtp_config to get_smtp_config for better accessibility
sub get_smtp_config {
    my ($self, $c, $site_id) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_smtp_config', 
        "Retrieving SMTP config for site_id $site_id");
    
    my $config_rs = $c->model('DBEncy')->resultset('SiteConfig');

    # Retrieve SMTP configuration for the given site_id
    my %smtp_config;
    for my $key (qw(host port username password from ssl)) {
        my $config = $config_rs->find({ site_id => $site_id, config_key => "smtp_$key" });
        
        # Skip optional fields like ssl
        next if !$config && $key eq 'ssl';
        
        # Return undef if any required config is missing
        unless ($config) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_smtp_config', 
                "Missing SMTP config key: smtp_$key for site_id $site_id");
            return;
        }
        
        $smtp_config{$key} = $config->config_value;
        
        # If host is mail1.ht.home, replace it with the IP address
        if ($key eq 'host' && $smtp_config{$key} eq 'mail1.ht.home') {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_smtp_config', 
                "Replacing mail1.ht.home with 192.168.1.129");
            $smtp_config{$key} = '192.168.1.129';
        }
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_smtp_config', 
        "Successfully retrieved SMTP config for site_id $site_id");
    
    return \%smtp_config;
}

# New method to create mail accounts via Virtualmin API
sub create_mail_account {
    my ($self, $c, $email, $password, $domain) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_mail_account', 
        "Creating mail account $email for domain $domain");

    # Get Virtualmin credentials from configuration
    my $virtualmin_host = $c->config->{Virtualmin}->{host} // '192.168.1.129';
    my $virtualmin_user = $c->config->{Virtualmin}->{username} // 'admin';
    my $virtualmin_pass = $c->config->{Virtualmin}->{password};
    
    unless ($virtualmin_pass) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_mail_account', 
            "Virtualmin password not configured");
        $c->stash->{debug_msg} = "Virtualmin API credentials not configured";
        return;
    }

    # Use IP address directly if hostname is mail1.ht.home
    if ($virtualmin_host eq 'mail1.ht.home') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_mail_account', 
            "Replacing mail1.ht.home with 192.168.1.129 for Virtualmin API");
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
