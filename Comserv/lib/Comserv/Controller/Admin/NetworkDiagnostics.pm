package Comserv::Controller::Admin::NetworkDiagnostics;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use IPC::Run3;
use Try::Tiny;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

=head1 NAME

Comserv::Controller::Admin::NetworkDiagnostics - Network Diagnostics Controller

=head1 DESCRIPTION

Controller for network diagnostics and troubleshooting.

=head1 METHODS

=head2 index

Display the network diagnostics dashboard

=cut

sub index :Path('/admin/network_diagnostics') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        "Accessing network diagnostics dashboard");
    
    # Initialize debug messages array
    $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
    
    # Check if user is admin
    my $is_admin = 0;
    if (defined $c->session->{roles} && ref($c->session->{roles}) eq 'ARRAY') {
        $is_admin = grep { $_ eq 'admin' } @{$c->session->{roles}};
    }
    
    unless ($is_admin) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'index', 
            "Unauthorized access attempt by user: " . ($c->session->{username} || 'Guest'));
        $c->stash->{error_msg} = "You must be an admin to access network diagnostics.";
        $c->stash->{template} = 'admin/error.tt';
        $c->forward($c->view('TT'));
        return;
    }
    
    # Get local network information
    my $hostname = $self->_run_command("hostname -f");
    my $ip_info = $self->_run_command("ip addr");
    my $hosts_file = $self->_run_command("cat /etc/hosts");
    
    # Store in stash
    $c->stash->{hostname} = $hostname;
    $c->stash->{ip_info} = $ip_info;
    $c->stash->{hosts_file} = $hosts_file;
    
    # Set template
    $c->stash->{template} = 'admin/network_diagnostics.tt';
}

=head2 ping_host

Ping a remote host to check connectivity

=cut

sub ping_host :Path('/admin/network_diagnostics/ping') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ping_host', 
        "Starting ping host action");
    
    # Initialize debug messages array
    $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
    
    # Check if user is admin
    my $is_admin = 0;
    if (defined $c->session->{roles} && ref($c->session->{roles}) eq 'ARRAY') {
        $is_admin = grep { $_ eq 'admin' } @{$c->session->{roles}};
    }
    
    unless ($is_admin) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'ping_host', 
            "Unauthorized access attempt by user: " . ($c->session->{username} || 'Guest'));
        $c->stash->{error_msg} = "You must be an admin to perform network diagnostics.";
        $c->stash->{template} = 'admin/error.tt';
        $c->forward($c->view('TT'));
        return;
    }
    
    my $host = $c->req->params->{host};
    
    if ($host) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ping_host', 
            "Pinging host: $host");
        
        # Sanitize the hostname to prevent command injection
        $host =~ s/[^a-zA-Z0-9\.\-\_]//g;
        
        my $ping_result = $self->_run_command("ping -c 4 $host");
        
        $c->stash->{ping_result} = $ping_result;
        $c->stash->{ping_host} = $host;
        
        # Check if ping was successful
        if ($ping_result =~ /(\d+) received/) {
            my $packets_received = $1;
            if ($packets_received > 0) {
                $c->stash->{success_msg} = "Successfully pinged $host ($packets_received packets received)";
            } else {
                $c->stash->{error_msg} = "Failed to ping $host (0 packets received)";
            }
        } else {
            $c->stash->{error_msg} = "Failed to ping $host (unknown error)";
        }
    }
    
    # Get local network information for the dashboard
    my $hostname = $self->_run_command("hostname -f");
    my $ip_info = $self->_run_command("ip addr");
    my $hosts_file = $self->_run_command("cat /etc/hosts");
    
    # Store in stash
    $c->stash->{hostname} = $hostname;
    $c->stash->{ip_info} = $ip_info;
    $c->stash->{hosts_file} = $hosts_file;
    
    # Set template
    $c->stash->{template} = 'admin/network_diagnostics.tt';
}

=head2 dig_host

Perform DNS lookup on a host

=cut

sub dig_host :Path('/admin/network_diagnostics/dig') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'dig_host', 
        "Starting dig host action");
    
    # Initialize debug messages array
    $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
    
    # Check if user is admin
    my $is_admin = 0;
    if (defined $c->session->{roles} && ref($c->session->{roles}) eq 'ARRAY') {
        $is_admin = grep { $_ eq 'admin' } @{$c->session->{roles}};
    }
    
    unless ($is_admin) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'dig_host', 
            "Unauthorized access attempt by user: " . ($c->session->{username} || 'Guest'));
        $c->stash->{error_msg} = "You must be an admin to perform network diagnostics.";
        $c->stash->{template} = 'admin/error.tt';
        $c->forward($c->view('TT'));
        return;
    }
    
    my $host = $c->req->params->{host};
    
    if ($host) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'dig_host', 
            "Performing DNS lookup for host: $host");
        
        # Sanitize the hostname to prevent command injection
        $host =~ s/[^a-zA-Z0-9\.\-\_]//g;
        
        my $dig_result = $self->_run_command("dig $host");
        
        $c->stash->{dig_result} = $dig_result;
        $c->stash->{dig_host} = $host;
        
        # Check if dig was successful
        if ($dig_result =~ /ANSWER SECTION/) {
            $c->stash->{success_msg} = "Successfully performed DNS lookup for $host";
        } else {
            $c->stash->{warning_msg} = "DNS lookup for $host did not return any answers";
        }
    }
    
    # Get local network information for the dashboard
    my $hostname = $self->_run_command("hostname -f");
    my $ip_info = $self->_run_command("ip addr");
    my $hosts_file = $self->_run_command("cat /etc/hosts");
    
    # Store in stash
    $c->stash->{hostname} = $hostname;
    $c->stash->{ip_info} = $ip_info;
    $c->stash->{hosts_file} = $hosts_file;
    
    # Set template
    $c->stash->{template} = 'admin/network_diagnostics.tt';
}

=head2 add_hosts_entry

Add an entry to the hosts file

=cut

sub add_hosts_entry :Path('/admin/network_diagnostics/add_hosts_entry') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_hosts_entry', 
        "Starting add hosts entry action");
    
    # Initialize debug messages array
    $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
    
    # Check if user is admin
    my $is_admin = 0;
    if (defined $c->session->{roles} && ref($c->session->{roles}) eq 'ARRAY') {
        $is_admin = grep { $_ eq 'admin' } @{$c->session->{roles}};
    }
    
    unless ($is_admin) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'add_hosts_entry', 
            "Unauthorized access attempt by user: " . ($c->session->{username} || 'Guest'));
        $c->stash->{error_msg} = "You must be an admin to modify hosts file.";
        $c->stash->{template} = 'admin/error.tt';
        $c->forward($c->view('TT'));
        return;
    }
    
    if ($c->req->method eq 'POST') {
        my $ip = $c->req->params->{ip};
        my $hostname = $c->req->params->{hostname};
        my $sudo_password = $c->req->params->{sudo_password};
        
        if ($ip && $hostname && $sudo_password) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_hosts_entry', 
                "Attempting to add hosts entry for $hostname ($ip)");
            
            # Sanitize inputs to prevent command injection
            $ip =~ s/[^0-9\.]//g;
            $hostname =~ s/[^a-zA-Z0-9\.\-\_]//g;
            $sudo_password =~ s/'/'\\''/g; # Escape single quotes
            
            # Create the hosts entry
            my $entry = "$ip\t$hostname";
            
            # Add to hosts file using sudo
            my $command = "echo '$sudo_password' | sudo -S bash -c \"echo '$entry' >> /etc/hosts\"";
            my $result = $self->_run_command($command);
            
            # Check if there was an error
            if ($? == 0) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_hosts_entry', 
                    "Successfully added hosts entry for $hostname");
                $c->stash->{success_msg} = "Successfully added hosts entry for $hostname";
            } else {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_hosts_entry', 
                    "Failed to add hosts entry: $result");
                $c->stash->{error_msg} = "Failed to add hosts entry. Check your sudo password and try again.";
            }
            
            # Clear the password from memory
            delete $c->req->params->{sudo_password};
        } else {
            $c->stash->{error_msg} = "Please provide IP address, hostname, and sudo password.";
        }
    }
    
    # Get local network information for the dashboard
    my $hostname = $self->_run_command("hostname -f");
    my $ip_info = $self->_run_command("ip addr");
    my $hosts_file = $self->_run_command("cat /etc/hosts");
    
    # Store in stash
    $c->stash->{hostname} = $hostname;
    $c->stash->{ip_info} = $ip_info;
    $c->stash->{hosts_file} = $hosts_file;
    
    # Set template
    $c->stash->{template} = 'admin/network_diagnostics.tt';
}

=head2 _run_command

Helper method to run shell commands safely

=cut

sub _run_command {
    my ($self, $command) = @_;
    
    my $output = '';
    my $error = '';
    
    try {
        run3($command, \undef, \$output, \$error);
    } catch {
        $error = "Error executing command: $_";
    };
    
    return $error ? "$output\n$error" : $output;
}

__PACKAGE__->meta->make_immutable;

1;