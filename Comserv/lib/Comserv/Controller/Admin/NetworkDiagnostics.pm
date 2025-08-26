package Comserv::Controller::Admin::NetworkDiagnostics;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use IPC::Run3;
use Try::Tiny;
use JSON;
use File::Slurp qw(read_file);

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has '_network_map_file' => (
    is => 'ro',
    default => '/home/shanta/PycharmProjects/comserv2/Comserv/config/network_map.json'
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
    
    # Load network map data
    my $network_map = $self->_load_network_map();
    
    # Get local network information
    my $hostname = $self->_run_command("hostname -f");
    my $ip_info = $self->_run_command("ip addr");
    my $hosts_file = $self->_run_command("cat /etc/hosts");
    
    # Check for virtualization and container technologies
    my $has_docker = $self->_run_command("which docker") ? 1 : 0;
    my $has_kubectl = $self->_run_command("which kubectl") ? 1 : 0;
    my $has_virsh = $self->_run_command("which virsh") ? 1 : 0;
    
    # Store in stash
    $c->stash->{hostname} = $hostname;
    $c->stash->{ip_info} = $ip_info;
    $c->stash->{hosts_file} = $hosts_file;
    $c->stash->{networks} = $network_map->{networks};
    $c->stash->{devices} = $network_map->{devices};
    $c->stash->{has_docker} = $has_docker;
    $c->stash->{has_kubectl} = $has_kubectl;
    $c->stash->{has_virsh} = $has_virsh;
    
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
        my $network_id = $c->req->params->{network_id};
        
        if ($ip && $hostname && $sudo_password) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_hosts_entry', 
                "Attempting to add hosts entry for $hostname ($ip)");
            
            # Validate IP address format
            unless ($ip =~ /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/ &&
                    $1 <= 255 && $2 <= 255 && $3 <= 255 && $4 <= 255) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_hosts_entry', 
                    "Invalid IP address format: $ip");
                $c->stash->{error_msg} = "Invalid IP address format. Please use a valid IPv4 address.";
                return;
            }
            
            # Validate hostname format
            unless ($hostname =~ /^[a-zA-Z0-9][a-zA-Z0-9\.\-\_]{0,253}$/) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_hosts_entry', 
                    "Invalid hostname format: $hostname");
                $c->stash->{error_msg} = "Invalid hostname format. Please use a valid hostname.";
                return;
            }
            
            # Check if IP already exists in network map
            my $network_map = $self->_load_network_map();
            my $ip_exists = 0;
            my $hostname_exists = 0;
            
            foreach my $device_id (keys %{$network_map->{devices}}) {
                my $device = $network_map->{devices}->{$device_id};
                if ($device->{ip} eq $ip) {
                    $ip_exists = 1;
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'add_hosts_entry', 
                        "IP address $ip already exists in network map as device $device_id");
                    $c->stash->{warning_msg} = "IP address $ip already exists in network map as device $device_id. Adding to hosts file anyway.";
                }
                
                if (lc($device->{device_name} || '') eq lc($hostname) || 
                    $device_id eq lc($hostname)) {
                    $hostname_exists = 1;
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'add_hosts_entry', 
                        "Hostname $hostname already exists in network map as device $device_id");
                    $c->stash->{warning_msg} = "Hostname $hostname already exists in network map. Adding to hosts file anyway.";
                }
            }
            
            # Create the hosts entry
            my $entry = "$ip\t$hostname";
            
            # Create a temporary file with the entry
            my $temp_file = "/tmp/hosts_entry_$$.txt";
            open my $fh, '>', $temp_file or do {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_hosts_entry', 
                    "Failed to create temporary file: $!");
                $c->stash->{error_msg} = "Failed to create temporary file: $!";
                return;
            };
            print $fh $entry;
            close $fh;
            
            # Add to hosts file using sudo
            # Note: This still requires sudo password, but doesn't pass it on command line
            my $command = "cat $temp_file | sudo -S tee -a /etc/hosts > /dev/null";
            my $result = '';
            
            # Use a pipe to send the password to sudo
            open(my $sudo_pipe, '|-', "sudo -S tee -a /etc/hosts > /dev/null") or do {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_hosts_entry', 
                    "Failed to open sudo pipe: $!");
                $c->stash->{error_msg} = "Failed to execute sudo command: $!";
                unlink $temp_file;
                return;
            };
            
            # Send password to sudo
            print $sudo_pipe "$sudo_password\n";
            
            # Send the hosts entry
            open my $entry_fh, '<', $temp_file or do {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_hosts_entry', 
                    "Failed to open temporary file: $!");
                close $sudo_pipe;
                unlink $temp_file;
                $c->stash->{error_msg} = "Failed to read temporary file: $!";
                return;
            };
            
            while (<$entry_fh>) {
                print $sudo_pipe $_;
            }
            
            close $entry_fh;
            my $exit_code = close $sudo_pipe;
            unlink $temp_file;
            
            # Check if there was an error
            if ($exit_code) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_hosts_entry', 
                    "Successfully added hosts entry for $hostname");
                $c->stash->{success_msg} = "Successfully added hosts entry for $hostname";
            } else {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_hosts_entry', 
                    "Failed to add hosts entry (exit code: $?)");
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

=head2 vm_info

Display virtual machine and container information

=cut

sub vm_info :Path('/admin/network_diagnostics/vm_info') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'vm_info', 
        "Starting VM info action");
    
    # Initialize debug messages array
    $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
    
    # Check if user is admin
    my $is_admin = 0;
    if (defined $c->session->{roles} && ref($c->session->{roles}) eq 'ARRAY') {
        $is_admin = grep { $_ eq 'admin' } @{$c->session->{roles}};
    }
    
    unless ($is_admin) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'vm_info', 
            "Unauthorized access attempt by user: " . ($c->session->{username} || 'Guest'));
        $c->stash->{error_msg} = "You must be an admin to view VM information.";
        $c->stash->{template} = 'admin/error.tt';
        $c->forward($c->view('TT'));
        return;
    }
    
    # Load network map data
    my $network_map = $self->_load_network_map();
    
    # Gather VM and container information
    my $vm_status = $self->_run_command("virsh list --all");
    my $docker_status = $self->_run_command("docker ps -a");
    my $docker_images = $self->_run_command("docker images");
    my $docker_networks = $self->_run_command("docker network ls");
    my $kubectl_nodes = $self->_run_command("kubectl get nodes");
    my $kubectl_pods = $self->_run_command("kubectl get pods --all-namespaces");
    my $kubectl_services = $self->_run_command("kubectl get services --all-namespaces");
    
    # Get basic system information
    my $hostname = $self->_run_command("hostname -f");
    my $ip_info = $self->_run_command("ip addr");
    
    # Store in stash
    $c->stash->{hostname} = $hostname;
    $c->stash->{ip_info} = $ip_info;
    $c->stash->{vm_status} = $vm_status;
    $c->stash->{docker_status} = $docker_status;
    $c->stash->{docker_images} = $docker_images;
    $c->stash->{docker_networks} = $docker_networks;
    $c->stash->{kubectl_nodes} = $kubectl_nodes;
    $c->stash->{kubectl_pods} = $kubectl_pods;
    $c->stash->{kubectl_services} = $kubectl_services;
    $c->stash->{networks} = $network_map->{networks};
    $c->stash->{devices} = $network_map->{devices};
    
    # Set template
    $c->stash->{template} = 'admin/network_diagnostics_vm_info.tt';
}

=head2 system_info

Get detailed system information

=cut

sub system_info :Path('/admin/network_diagnostics/system_info') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'system_info', 
        "Starting system info action");
    
    # Initialize debug messages array
    $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
    
    # Check if user is admin
    my $is_admin = 0;
    if (defined $c->session->{roles} && ref($c->session->{roles}) eq 'ARRAY') {
        $is_admin = grep { $_ eq 'admin' } @{$c->session->{roles}};
    }
    
    unless ($is_admin) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'system_info', 
            "Unauthorized access attempt by user: " . ($c->session->{username} || 'Guest'));
        $c->stash->{error_msg} = "You must be an admin to view system information.";
        $c->stash->{template} = 'admin/error.tt';
        $c->forward($c->view('TT'));
        return;
    }
    
    # Gather system information
    my $hostname = $self->_run_command("hostname -f");
    my $kernel = $self->_run_command("uname -a");
    my $os_info = $self->_run_command("cat /etc/os-release");
    my $ip_info = $self->_run_command("ip addr");
    my $routing_table = $self->_run_command("ip route");
    my $dns_config = $self->_run_command("cat /etc/resolv.conf");
    my $hosts_file = $self->_run_command("cat /etc/hosts");
    my $disk_usage = $self->_run_command("df -h");
    my $memory_info = $self->_run_command("free -h");
    my $network_connections = $self->_run_command("netstat -tuln");
    
    # Store in stash
    $c->stash->{hostname} = $hostname;
    $c->stash->{kernel} = $kernel;
    $c->stash->{os_info} = $os_info;
    $c->stash->{ip_info} = $ip_info;
    $c->stash->{routing_table} = $routing_table;
    $c->stash->{dns_config} = $dns_config;
    $c->stash->{hosts_file} = $hosts_file;
    $c->stash->{disk_usage} = $disk_usage;
    $c->stash->{memory_info} = $memory_info;
    $c->stash->{network_connections} = $network_connections;
    
    # Set template
    $c->stash->{template} = 'admin/network_diagnostics_system_info.tt';
}

=head2 _load_network_map

Helper method to load the network map data from JSON

=cut

sub _load_network_map {
    my ($self) = @_;
    
    my $network_map = { networks => {}, devices => {} };
    
    try {
        if (-e $self->_network_map_file) {
            my $json_text = read_file($self->_network_map_file);
            $network_map = decode_json($json_text);
        }
    } catch {
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_load_network_map', 
            "Error loading network map: $_");
    };
    
    return $network_map;
}

=head2 _run_command

Helper method to run shell commands safely

=cut

sub _run_command {
    my ($self, $command) = @_;
    
    my $output = '';
    my $error = '';
    
    try {
        # If command is a string, convert to array to avoid shell interpretation
        if (!ref($command)) {
            # Split the command into an array, preserving quoted strings
            my @cmd_array = ();
            if ($command =~ /^(ping|dig|hostname|ip|cat|uname|df|free|netstat|docker|kubectl)\b/) {
                # For safe commands, we can split by spaces
                @cmd_array = split(/\s+/, $command);
            } else {
                # For other commands, use the shell but log it
                $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_run_command', 
                    "Running potentially unsafe command via shell: $command");
                run3($command, \undef, \$output, \$error);
                return $error ? "$output\n$error" : $output;
            }
            run3(\@cmd_array, \undef, \$output, \$error);
        } else {
            # Command is already an array reference
            run3($command, \undef, \$output, \$error);
        }
    } catch {
        $error = "Error executing command: $_";
    };
    
    return $error ? "$output\n$error" : $output;
}

__PACKAGE__->meta->make_immutable;

1;