# Proxmox.pm - Model for interacting with the Proxmox VE API
#
# This model provides methods for connecting to and retrieving data from
# Proxmox VE servers. It supports multiple authentication methods and
# includes fallback mechanisms for different API endpoints.
#
# See /docs/proxmox_api.md for detailed API documentation.
#
# Author: Comserv Development Team
# Last Updated: 2024

package Comserv::Model::Proxmox;
use Moose;
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)
use LWP::UserAgent;
use HTTP::Request;
use HTTP::Request::Common qw(POST);
use URI::Escape qw(uri_escape);
use JSON;
use Data::Dumper;
use Try::Tiny;
use Comserv::Util::Logging;
use Comserv::Util::ProxmoxCredentials;

extends 'Catalyst::Model';

has 'server_id' => (
    is => 'rw',
    default => 'default'
);

has 'api_url_base' => (
    is => 'rw',
    default => ''
);

has 'node' => (
    is => 'rw',
    default => 'proxmox'
);

has 'token_user' => (
    is => 'rw',
    default => ''
);

has 'token_value' => (
    is => 'rw',
    default => ''
);

has 'api_token' => (
    is => 'rw',
    default => ''
);

has 'token' => (
    is => 'rw',
    default => ''
);

has 'credentials_loaded' => (
    is => 'rw',
    default => 0
);

has 'debug_info' => (
    is => 'rw',
    default => sub { {} }
);

# Modified get_vms method to stop using mock data
sub get_vms {
    my ($self, $server_id) = @_;

    # Get the logging instance
    my $logging = Comserv::Util::Logging->instance;

    # Set the server ID if provided
    if ($server_id) {
        $self->set_server_id($server_id);
    } else {
        $server_id = $self->{server_id};
    }

    # Debug log
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'get_vms',
        "Getting VMs for server: $server_id");

    # Make sure credentials are loaded
    $self->_load_credentials() unless $self->{credentials_loaded};

    # Check if we have valid credentials
    if (!$self->{api_url_base}) {
        $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'get_vms',
            "No valid API URL found for server: $server_id");
        # Return empty array instead of mock data
        return [];
    }

    # Check if we're already authenticated, if not, try to authenticate
    if (!$self->{api_token} && !$self->{token}) {
        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'get_vms',
            "Not authenticated yet, attempting to authenticate");

        my $auth_success = $self->check_connection();

        if (!$auth_success) {
            $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'get_vms',
                "Failed to authenticate with Proxmox server: $server_id");

            # Log the debug info
            if ($self->{debug_info}) {
                $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'get_vms',
                    "Debug info: " . Data::Dumper::Dumper($self->{debug_info}));
            }

            # Return empty array instead of mock data
            return [];
        }
    }

    # Initialize debug info
    $self->{debug_info} = {};

    # Try to get real VM data from the Proxmox API
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'get_vms',
        "Attempting to get real VM data from Proxmox API");

    my $vms;

    eval {
        $vms = $self->_get_real_vms_new($server_id);
    };

    # If there was an error, log it and return empty array
    if ($@) {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'get_vms',
            "Error getting real VM data: $@");
        # Return empty array instead of mock data
        return [];
    }

    # If we got real VM data, return it
    if ($vms && @$vms > 0) {
        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'get_vms',
            "Successfully retrieved " . scalar(@$vms) . " real VMs from server: $server_id. " .
                "First VM: " . ($vms->[0]->{name} || $vms->[0]->{vmid} || 'unknown'));
        return $vms;
    }

    # If we didn't get any real VM data, check if we at least have a node
    $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'get_vms',
        "No real VMs found for server: $server_id");
        
    # Try to get the node information to at least show that
    my $ua = LWP::UserAgent->new;
    $ua->ssl_opts(verify_hostname => 0, SSL_verify_mode => 0);
    $ua->timeout(10);
    
    my $node_url = $self->{api_url_base} . '/nodes';
    my $node_req = HTTP::Request->new(GET => $node_url);
    
    # Add the API token header if available
    if ($self->{token_user} && $self->{token_value}) {
        my $token = "PVEAPIToken=" . $self->{token_user} . "=" . $self->{token_value};
        $node_req->header('Authorization' => $token);
    } elsif ($self->{api_token}) {
        $node_req->header('Authorization' => $self->{api_token});
    }
    
    # Send the request
    my $node_res = $ua->request($node_req);
    
    # If successful, try to create a placeholder for the node
    if ($node_res->is_success) {
        eval {
            my $node_data = decode_json($node_res->content);
            if ($node_data && $node_data->{data} && ref($node_data->{data}) eq 'ARRAY' && @{$node_data->{data}} > 0) {
                # Create a placeholder for the node
                my @nodes;
                foreach my $node (@{$node_data->{data}}) {
                    my $node_obj = {
                        vmid => 0,  # Use 0 to indicate it's a node, not a VM
                        name => "Node: " . $node->{node},
                        status => $node->{status} || 'unknown',
                        type => 'node',
                        node => $node->{node},
                        server_id => $server_id,
                        is_node => 1,  # Flag to indicate this is a node entry
                    };
                    push @nodes, $node_obj;
                    
                    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'get_vms',
                        "Added node placeholder: " . $node->{node});
                }
                
                if (@nodes > 0) {
                    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'get_vms',
                        "Returning " . scalar(@nodes) . " node placeholders instead of empty array");
                    return \@nodes;
                }
            }
        };
    }
    
    # If all else fails, return empty array
    $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'get_vms',
        "No nodes or VMs found for server: $server_id");
    return [];
}

# Load credentials from the credentials file
sub _load_credentials {
    my ($self) = @_;

    my $logging = Comserv::Util::Logging->instance;
    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_load_credentials',
        "Loading credentials for server: " . $self->{server_id});

    # Get credentials from the credentials file
    my $credentials = Comserv::Util::ProxmoxCredentials::get_credentials($self->{server_id});

    # Set the credentials
    $self->{api_url_base} = $credentials->{api_url_base} || '';

    my $node_name = $credentials->{node} || 'proxmox';
    $self->{node} = $node_name;
    $self->{token_user} = $credentials->{token_user} || '';
    $self->{token_value} = $credentials->{token_value} || '';

    # Log the node name we're using
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_load_credentials',
        "Using node name '" . $node_name . "' for Proxmox API calls");

    # Log the credentials (without sensitive info)
    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_load_credentials',
        "Loaded credentials: api_url_base=" . ($self->{api_url_base} || 'undef') .
        ", node=" . ($self->{node} || 'undef') .
        ", token_user=" . ($self->{token_user} || 'undef') .
        ", token_value=" . ($self->{token_value} ? 'set' : 'not set'));

    # Mark credentials as loaded
    $self->{credentials_loaded} = 1;

    return 1;
}

sub _make_ua {
    my ($self, $timeout) = @_;
    my $ua = LWP::UserAgent->new;
    $ua->ssl_opts(verify_hostname => 0, SSL_verify_mode => 0);
    $ua->timeout($timeout || 15);
    return $ua;
}

sub _auth_header {
    my ($self) = @_;
    if ($self->{token_user} && $self->{token_value}) {
        return "PVEAPIToken=" . $self->{token_user} . "=" . $self->{token_value};
    } elsif ($self->{api_token}) {
        return $self->{api_token};
    }
    return '';
}

sub _resolve_node {
    my ($self, $ua, $auth_header) = @_;
    my $req = HTTP::Request->new(GET => $self->{api_url_base} . '/nodes');
    $req->header(Authorization => $auth_header);
    my $res = $ua->request($req);
    if ($res->is_success) {
        my $nd = eval { decode_json($res->decoded_content) };
        return $nd->{data}[0]{node}
            if $nd && $nd->{data} && @{$nd->{data}};
    }
    return $self->{node} || 'proxmox';
}

# Get credentials for a specific server
sub get_credentials {
    my ($self, $server_id) = @_;

    my $logging = Comserv::Util::Logging->instance;
    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'get_credentials',
        "Getting credentials for server: $server_id");

    # Get the credentials from the credentials file
    my $credentials = Comserv::Util::ProxmoxCredentials::get_credentials($server_id);

    return $credentials;
}

# Duplicate method removed to fix declaration error

# Set the server ID
sub set_server_id {
    my ($self, $server_id) = @_;

    my $logging = Comserv::Util::Logging->instance;
    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'set_server_id',
        "Setting server ID: $server_id");

    # Set the server ID
    $self->{server_id} = $server_id;

    # Reset credentials loaded flag
    $self->{credentials_loaded} = 0;

    # Reset API token
    $self->{api_token} = '';
    $self->{token} = '';  # For backward compatibility

    return 1;
}

# Check connection to the Proxmox server
sub check_connection {
    my ($self) = @_;

    my $logging = Comserv::Util::Logging->instance;
    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'check_connection',
        "Checking connection to Proxmox server: " . $self->{server_id});

    # Make sure credentials are loaded
    $self->_load_credentials() unless $self->{credentials_loaded};

    # Check if we have valid credentials
    if (!$self->{api_url_base}) {
        $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'check_connection',
            "No valid API URL found for server: " . $self->{server_id});
        return 0;
    }

    # Create a user agent
    my $ua = LWP::UserAgent->new;
    $ua->ssl_opts(verify_hostname => 0, SSL_verify_mode => 0);
    $ua->timeout(10);

    # Create the request
    my $url = $self->{api_url_base} . '/version';
    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'check_connection',
        "Checking connection to URL: $url");

    my $req = HTTP::Request->new(GET => $url);

    # Add the API token header if available
    if ($self->{token_user} && $self->{token_value}) {
        $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'check_connection',
            "Using API token for authentication");

        # Log token details for debugging (without showing the full token)
        $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'check_connection',
            "Token user: " . $self->{token_user} . 
            ", Token value length: " . length($self->{token_value}));

        my $token = "PVEAPIToken=" . $self->{token_user} . "=" . $self->{token_value};
        $req->header('Authorization' => $token);

        # Store the token for future use
        $self->{api_token} = $token;
        $self->{token} = $token;  # For backward compatibility

        $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'check_connection',
            "Stored API token for future use");
    } elsif ($self->{api_token}) {
        $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'check_connection',
            "Using stored API token for authentication");

        $req->header('Authorization' => $self->{api_token});
    } else {
        $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'check_connection',
            "No API token available for authentication");
        return 0;
    }

    # Send the request
    my $res = $ua->request($req);

    # Check if the request was successful
    if ($res->is_success) {
        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'check_connection',
            "Successfully connected to Proxmox server: " . $self->{server_id});

        # Parse the response
        my $response_data;
        eval {
            $response_data = decode_json($res->content);
        };

        if ($@) {
            $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'check_connection',
                "Failed to parse response: $@");
            return 0;
        }

        # The API token is already stored above

        # Store debug info
        $self->{debug_info} = {
            response_code => $res->code,
            response_status => $res->status_line,
            response_data => $response_data,
        };

        return 1;
    } else {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'check_connection',
            "Failed to connect to Proxmox server: " . $res->status_line);

        # Store debug info
        $self->{debug_info} = {
            response_code => $res->code,
            response_status => $res->status_line,
            response_content => $res->content,
        };

        return 0;
    }
}

# Test direct connection to the 'proxmox' node
sub test_proxmox_node {
    my ($self) = @_;

    my $logging = Comserv::Util::Logging->instance;
    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'test_proxmox_node',
        "Testing direct connection to 'proxmox' node");

    # Make sure credentials are loaded
    $self->_load_credentials() unless $self->{credentials_loaded};

    # Check if we have valid credentials
    if (!$self->{api_url_base}) {
        $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'test_proxmox_node',
            "No valid API URL found for server: " . $self->{server_id});
        return [];
    }

    # Create a user agent
    my $ua = LWP::UserAgent->new;
    $ua->ssl_opts(verify_hostname => 0, SSL_verify_mode => 0);
    $ua->timeout(30);

    # Construct the URL for QEMU VMs on the 'proxmox' node
    my $proxmox_url = $self->{api_url_base} . '/nodes/proxmox/qemu';
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'test_proxmox_node',
        "Trying to get VMs from URL: $proxmox_url");

    # Create the request
    my $proxmox_req = HTTP::Request->new(GET => $proxmox_url);

    # Add the API token header if available
    if ($self->{token_user} && $self->{token_value}) {
        $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'test_proxmox_node',
            "Using API token for authentication");
            
        # Log token details for debugging (without showing the full token)
        $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'test_proxmox_node',
            "Token user: " . $self->{token_user} . 
            ", Token value length: " . length($self->{token_value}));
            
        my $token = "PVEAPIToken=" . $self->{token_user} . "=" . $self->{token_value};
        $proxmox_req->header('Authorization' => $token);
    } elsif ($self->{api_token}) {
        $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'test_proxmox_node',
            "Using stored API token for authentication");
            
        $proxmox_req->header('Authorization' => $self->{api_token});
    } else {
        $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'test_proxmox_node',
            "No API token available for authentication");
        return [];
    }

    # Send the request
    my $proxmox_res = $ua->request($proxmox_req);

    # Log the response status
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'test_proxmox_node',
        "Direct 'proxmox' node API response status: " . $proxmox_res->status_line);

    # Store the response for debugging
    $self->{debug_info}->{direct_proxmox_url} = $proxmox_url;
    $self->{debug_info}->{direct_proxmox_response_code} = $proxmox_res->code;
    $self->{debug_info}->{direct_proxmox_response_status} = $proxmox_res->status_line;
    $self->{debug_info}->{direct_proxmox_response_content} = substr($proxmox_res->content, 0, 1000);

    # If we got a successful response, try to parse the VMs
    if ($proxmox_res->is_success) {
        eval {
            my $proxmox_data = decode_json($proxmox_res->content);
            if ($proxmox_data && $proxmox_data->{data} && ref($proxmox_data->{data}) eq 'ARRAY') {
                # Process the VM data
                my @vms;
                foreach my $vm (@{$proxmox_data->{data}}) {
                    # Extract the VM ID
                    my $vmid = $vm->{vmid};

                    # Log the VM being processed
                    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'test_proxmox_node',
                        "Processing VM from 'proxmox' node: ID=$vmid, Name=" . ($vm->{name} || 'unnamed'));

                    # Create a VM object
                    my $vm_obj = {
                        vmid => $vmid,
                        name => $vm->{name} || "VM $vmid",
                        status => $vm->{status} || 'unknown',
                        type => 'qemu',
                        node => 'proxmox',
                        maxmem => $vm->{maxmem} || 0,
                        maxdisk => $vm->{maxdisk} || 0,
                        uptime => $vm->{uptime} || 0,
                        cpu => $vm->{cpu} || 0,
                        server_id => $self->{server_id},
                    };

                    # Add the VM to the list
                    push @vms, $vm_obj;
                }

                $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'test_proxmox_node',
                    "Successfully retrieved " . scalar(@vms) . " VMs directly from 'proxmox' node");

                # Return the VMs
                return \@vms;
            } else {
                $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'test_proxmox_node',
                    "No VMs found in direct 'proxmox' node response");
            }
        };
        if ($@) {
            $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'test_proxmox_node',
                "Error parsing direct 'proxmox' node response: $@");
        }
    } else {
        $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'test_proxmox_node',
            "Failed to get VMs directly from 'proxmox' node: " . $proxmox_res->status_line);
    }

    # Try to get LXC containers from the 'proxmox' node
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'test_proxmox_node',
        "Trying to get LXC containers from 'proxmox' node");
        
    # Construct the URL for LXC containers on the 'proxmox' node
    my $lxc_url = $self->{api_url_base} . '/nodes/proxmox/lxc';
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'test_proxmox_node',
        "Trying to get LXC containers from URL: $lxc_url");
        
    # Store the URL in debug info
    $self->{debug_info}->{direct_lxc_url} = $lxc_url;
    
    # Create the request
    my $lxc_req = HTTP::Request->new(GET => $lxc_url);
    
    # Add the API token header if available
    if ($self->{token_user} && $self->{token_value}) {
        my $token = "PVEAPIToken=" . $self->{token_user} . "=" . $self->{token_value};
        $lxc_req->header('Authorization' => $token);
    } elsif ($self->{api_token}) {
        $lxc_req->header('Authorization' => $self->{api_token});
    }
    
    # Send the request
    my $lxc_res = $ua->request($lxc_req);
    
    # Log the response status
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'test_proxmox_node',
        "Direct 'proxmox' node LXC API response status: " . $lxc_res->status_line);
        
    # Store the response for debugging
    $self->{debug_info}->{direct_lxc_response_code} = $lxc_res->code;
    $self->{debug_info}->{direct_lxc_response_status} = $lxc_res->status_line;
    $self->{debug_info}->{direct_lxc_response_content} = substr($lxc_res->content, 0, 1000);
    
    # If we got a successful response, try to parse the LXC containers
    if ($lxc_res->is_success) {
        eval {
            my $lxc_data = decode_json($lxc_res->content);
            if ($lxc_data && $lxc_data->{data} && ref($lxc_data->{data}) eq 'ARRAY') {
                # Process the LXC container data
                my @containers;
                foreach my $container (@{$lxc_data->{data}}) {
                    # Extract the container ID
                    my $vmid = $container->{vmid};
                    
                    # Log the container being processed
                    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'test_proxmox_node',
                        "Processing LXC container from 'proxmox' node: ID=$vmid, Name=" . ($container->{name} || 'unnamed'));
                        
                    # Create a container object
                    my $container_obj = {
                        vmid => $vmid,
                        name => $container->{name} || "Container $vmid",
                        status => $container->{status} || 'unknown',
                        type => 'lxc',
                        node => 'proxmox',
                        maxmem => $container->{maxmem} || 0,
                        maxdisk => $container->{maxdisk} || 0,
                        uptime => $container->{uptime} || 0,
                        cpu => $container->{cpu} || 0,
                        server_id => $self->{server_id},
                    };
                    
                    # Add the container to the list
                    push @containers, $container_obj;
                }
                
                $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'test_proxmox_node',
                    "Successfully retrieved " . scalar(@containers) . " LXC containers directly from 'proxmox' node");
                    
                # Return the containers
                return \@containers;
            } else {
                $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'test_proxmox_node',
                    "No LXC containers found in direct 'proxmox' node response");
            }
        };
        if ($@) {
            $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'test_proxmox_node',
                "Error parsing direct 'proxmox' node LXC response: $@");
        }
    } else {
        $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'test_proxmox_node',
            "Failed to get LXC containers directly from 'proxmox' node: " . $lxc_res->status_line);
    }
    
    # Return an empty array if we couldn't get any VMs or containers
    return [];
}

# Get the list of VMs from the Proxmox API
sub _get_real_vms_new {
    my ($self, $server_id) = @_;

    my $logging = Comserv::Util::Logging->instance;
    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_get_real_vms_new',
        "Getting real VMs from Proxmox API for server: $server_id");

    # Make sure credentials are loaded
    $self->_load_credentials() unless $self->{credentials_loaded};

    # Check if we have valid credentials
    if (!$self->{api_url_base}) {
        $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_get_real_vms_new',
            "No valid API URL found for server: $server_id");
        return [];
    }

    # Log the credentials being used (without sensitive info)
    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_get_real_vms_new',
        "Using credentials: api_url_base=" . ($self->{api_url_base} || 'undef') .
        ", node=" . ($self->{node} || 'undef') .
        ", token_user=" . ($self->{token_user} || 'undef') .
        ", token_value=" . ($self->{token_value} ? 'set' : 'not set'));

    # Create a user agent
    my $ua = LWP::UserAgent->new;
    $ua->ssl_opts(verify_hostname => 0, SSL_verify_mode => 0);
    $ua->timeout(30);
    
    # CHANGED: First try the cluster/resources endpoint with type=vm as recommended
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
        "Trying cluster/resources endpoint with type=vm first (recommended approach)");
    
    my $resources_vms = $self->_try_get_cluster_resources($ua, 'vm');
    if ($resources_vms && @$resources_vms > 0) {
        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
            "Successfully retrieved " . scalar(@$resources_vms) . " VMs from cluster resources with type=vm");
        return $resources_vms;
    }
    
    # If the cluster/resources endpoint failed, try directly with the 'proxmox' node
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
        "Cluster resources endpoint failed, trying direct access to 'proxmox' node");

    # Construct the URL for QEMU VMs on the 'proxmox' node
    my $proxmox_url = $self->{api_url_base} . '/nodes/proxmox/qemu';
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
        "Trying to get VMs from URL: $proxmox_url");

    # Store the URL in debug info
    $self->{debug_info}->{direct_proxmox_url} = $proxmox_url;

    # Create the request
    my $proxmox_req = HTTP::Request->new(GET => $proxmox_url);

    # Add the API token header if available
    if ($self->{token_user} && $self->{token_value}) {
        my $token = "PVEAPIToken=" . $self->{token_user} . "=" . $self->{token_value};
        $proxmox_req->header('Authorization' => $token);
    } elsif ($self->{api_token}) {
        $proxmox_req->header('Authorization' => $self->{api_token});
    }

    # Send the request
    my $proxmox_res = $ua->request($proxmox_req);

    # Log the response status
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
        "Direct 'proxmox' node API response status: " . $proxmox_res->status_line);

    # Store the response for debugging
    $self->{debug_info}->{direct_proxmox_response_code} = $proxmox_res->code;
    $self->{debug_info}->{direct_proxmox_response_status} = $proxmox_res->status_line;
    $self->{debug_info}->{direct_proxmox_response_content} = substr($proxmox_res->content, 0, 1000);

    # If we got a successful response, try to parse the VMs
    if ($proxmox_res->is_success) {
        eval {
            my $proxmox_data = decode_json($proxmox_res->content);
            if ($proxmox_data && $proxmox_data->{data} && ref($proxmox_data->{data}) eq 'ARRAY') {
                # Process the VM data
                my @vms;
                foreach my $vm (@{$proxmox_data->{data}}) {
                    # Extract the VM ID
                    my $vmid = $vm->{vmid};

                    # Log the VM being processed
                    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
                        "Processing VM from 'proxmox' node: ID=$vmid, Name=" . ($vm->{name} || 'unnamed'));

                    # Create a VM object
                    my $vm_obj = {
                        vmid => $vmid,
                        name => $vm->{name} || "VM $vmid",
                        status => $vm->{status} || 'unknown',
                        type => 'qemu',
                        node => 'proxmox',
                        maxmem => $vm->{maxmem} || 0,
                        maxdisk => $vm->{maxdisk} || 0,
                        uptime => $vm->{uptime} || 0,
                        cpu => $vm->{cpu} || 0,
                        server_id => $self->{server_id},
                    };

                    # Add the VM to the list
                    push @vms, $vm_obj;
                }

                $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
                    "Successfully retrieved " . scalar(@vms) . " VMs directly from 'proxmox' node");

                # Return the VMs
                return \@vms;
            } else {
                $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_get_real_vms_new',
                    "No VMs found in direct 'proxmox' node response");
            }
        };
        if ($@) {
            $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_get_real_vms_new',
                "Error parsing direct 'proxmox' node response: $@");
        }
    } else {
        $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_get_real_vms_new',
            "Failed to get VMs directly from 'proxmox' node: " . $proxmox_res->status_line);
    }

    # Try to get LXC containers from the 'proxmox' node
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
        "Trying to get LXC containers from 'proxmox' node");
        
    # Construct the URL for LXC containers on the 'proxmox' node
    my $lxc_url = $self->{api_url_base} . '/nodes/proxmox/lxc';
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
        "Trying to get LXC containers from URL: $lxc_url");
        
    # Store the URL in debug info
    $self->{debug_info}->{direct_lxc_url} = $lxc_url;
    
    # Create the request
    my $lxc_req = HTTP::Request->new(GET => $lxc_url);
    
    # Add the API token header if available
    if ($self->{token_user} && $self->{token_value}) {
        my $token = "PVEAPIToken=" . $self->{token_user} . "=" . $self->{token_value};
        $lxc_req->header('Authorization' => $token);
    } elsif ($self->{api_token}) {
        $lxc_req->header('Authorization' => $self->{api_token});
    }
    
    # Send the request
    my $lxc_res = $ua->request($lxc_req);
    
    # Log the response status
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
        "Direct 'proxmox' node LXC API response status: " . $lxc_res->status_line);
        
    # Store the response for debugging
    $self->{debug_info}->{direct_lxc_response_code} = $lxc_res->code;
    $self->{debug_info}->{direct_lxc_response_status} = $lxc_res->status_line;
    $self->{debug_info}->{direct_lxc_response_content} = substr($lxc_res->content, 0, 1000);
    
    # If we got a successful response, try to parse the LXC containers
    if ($lxc_res->is_success) {
        eval {
            my $lxc_data = decode_json($lxc_res->content);
            if ($lxc_data && $lxc_data->{data} && ref($lxc_data->{data}) eq 'ARRAY') {
                # Process the LXC container data
                my @containers;
                foreach my $container (@{$lxc_data->{data}}) {
                    # Extract the container ID
                    my $vmid = $container->{vmid};
                    
                    # Log the container being processed
                    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
                        "Processing LXC container from 'proxmox' node: ID=$vmid, Name=" . ($container->{name} || 'unnamed'));
                        
                    # Create a container object
                    my $container_obj = {
                        vmid => $vmid,
                        name => $container->{name} || "Container $vmid",
                        status => $container->{status} || 'unknown',
                        type => 'lxc',
                        node => 'proxmox',
                        maxmem => $container->{maxmem} || 0,
                        maxdisk => $container->{maxdisk} || 0,
                        uptime => $container->{uptime} || 0,
                        cpu => $container->{cpu} || 0,
                        server_id => $self->{server_id},
                    };
                    
                    # Add the container to the list
                    push @containers, $container_obj;
                }
                
                $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
                    "Successfully retrieved " . scalar(@containers) . " LXC containers directly from 'proxmox' node");
                    
                # Return the containers
                return \@containers;
            } else {
                $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_get_real_vms_new',
                    "No LXC containers found in direct 'proxmox' node response");
            }
        };
        if ($@) {
            $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_get_real_vms_new',
                "Error parsing direct 'proxmox' node LXC response: $@");
        }
    } else {
        $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_get_real_vms_new',
            "Failed to get LXC containers directly from 'proxmox' node: " . $lxc_res->status_line);
    }
    
    # If direct access to 'proxmox' node failed for both QEMU and LXC, try the nodes endpoint to get a list of all nodes
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
        "Direct access to 'proxmox' node failed for both QEMU and LXC, trying nodes endpoint");

    my $nodes_url = $self->{api_url_base} . '/nodes';
    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_get_real_vms_new',
        "Getting nodes list from URL: $nodes_url");

    # Store the URL in debug info
    $self->{debug_info}->{nodes_url} = $nodes_url;
    $self->{debug_info}->{api_url_base} = $self->{api_url_base};
    $self->{debug_info}->{configured_node} = $self->{node};

    # If the configured node is not 'proxmox', log a warning
    if ($self->{node} ne 'proxmox') {
        $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_get_real_vms_new',
            "Configured node is '" . $self->{node} . "', but your Proxmox node might be named 'proxmox'");
    }

    my $nodes_req = HTTP::Request->new(GET => $nodes_url);

    # Add the API token header if available
    if ($self->{token_user} && $self->{token_value}) {
        my $token = "PVEAPIToken=" . $self->{token_user} . "=" . $self->{token_value};
        $nodes_req->header('Authorization' => $token);
    } elsif ($self->{api_token}) {
        $nodes_req->header('Authorization' => $self->{api_token});
    }

    # Send the request
    my $nodes_res = $ua->request($nodes_req);

    # Log the response status
    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_get_real_vms_new',
        "Nodes API response status: " . $nodes_res->status_line);

    # Store the nodes response for debugging
    $self->{debug_info}->{nodes_response_code} = $nodes_res->code;
    $self->{debug_info}->{nodes_response_status} = $nodes_res->status_line;
    $self->{debug_info}->{nodes_response_content} = substr($nodes_res->content, 0, 1000);

    # If we got a successful response, try to parse the nodes
    my @node_names = ($self->{node}); # Default to the configured node

    if ($nodes_res->is_success) {
        eval {
            my $nodes_data = decode_json($nodes_res->content);
            if ($nodes_data && $nodes_data->{data} && ref($nodes_data->{data}) eq 'ARRAY') {
                # Extract node names from the response
                @node_names = map { $_->{node} } @{$nodes_data->{data}};

                # Log the nodes we found
                $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
                    "Found " . scalar(@node_names) . " nodes: " . join(", ", @node_names));

                # Store the node names in debug info
                $self->{debug_info}->{found_nodes} = \@node_names;

                # If we found 'proxmox' in the node list, make sure it's used first
                if (grep { $_ eq 'proxmox' } @node_names) {
                    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
                        "Found node named 'proxmox', prioritizing it");

                    # Remove 'proxmox' from the array and add it to the front
                    @node_names = grep { $_ ne 'proxmox' } @node_names;
                    unshift @node_names, 'proxmox';
                }
            } else {
                $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_get_real_vms_new',
                    "No nodes found in response, using default node: " . $self->{node});
            }
        };
        if ($@) {
            $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_get_real_vms_new',
                "Error parsing nodes response: $@");
        }
    } else {
        $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_get_real_vms_new',
            "Failed to get nodes list, using default node: " . $self->{node});
    }

    # Try each discovered node first (auto-discovered from /nodes API)
    for my $node_name (@node_names) {
        next unless $node_name;
        my $discovered_vms = $self->_try_get_node_vms($ua, $node_name);
        if ($discovered_vms && @$discovered_vms > 0) {
            $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
                "Successfully retrieved " . scalar(@$discovered_vms) . " VMs from discovered node '$node_name'");
            return $discovered_vms;
        }
    }

    # Fall back to common default node names
    for my $fallback_node ('proxmox', 'pve') {
        next if grep { $_ eq $fallback_node } @node_names;
        my $fallback_vms = $self->_try_get_node_vms($ua, $fallback_node);
        if ($fallback_vms && @$fallback_vms > 0) {
            $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
                "Successfully retrieved " . scalar(@$fallback_vms) . " VMs from fallback node '$fallback_node'");
            return $fallback_vms;
        }
    }

    # Don't try with type=qemu as it's not a valid parameter according to the API error
    # Instead, try with the hostname as a node parameter
    my $hostname = '';
    if ($self->{api_url_base} =~ m{https?://([^:/]+)}) {
        $hostname = $1;
        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
            "Extracted hostname from API URL: $hostname");
            
        # Try to get VMs from this hostname as a node
        if ($hostname ne '' && $hostname ne '172.30.236.89') {
            $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
                "Trying to use hostname '$hostname' as a node name");
                
            my $hostname_vms = $self->_try_get_node_vms($ua, $hostname);
            if ($hostname_vms && @$hostname_vms > 0) {
                $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
                    "Successfully retrieved " . scalar(@$hostname_vms) . " VMs directly from node '$hostname'");
                return $hostname_vms;
            }
        } elsif ($hostname eq '172.30.236.89') {
            # If the hostname is an IP address, try to get the node name from the credentials
            my $credentials = Comserv::Util::ProxmoxCredentials::get_credentials($self->{server_id});
            if ($credentials && $credentials->{node}) {
                my $node_name = $credentials->{node};
                $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
                    "Using node name '$node_name' from credentials instead of IP address");
                    
                my $node_vms = $self->_try_get_node_vms($ua, $node_name);
                if ($node_vms && @$node_vms > 0) {
                    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
                        "Successfully retrieved " . scalar(@$node_vms) . " VMs directly from node '$node_name'");
                    return $node_vms;
                }
            }
        }
    }

    # Try with the node parameter instead of qemu (which is not valid)
    my $resources_node = $self->_try_get_cluster_resources($ua, 'node');
    if ($resources_node && @$resources_node > 0) {
        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
            "Successfully retrieved " . scalar(@$resources_node) . " resources from cluster resources with type=node");
        return $resources_node;
    }
    
    # If type=node didn't work, try without a type parameter
    my $resources_all = $self->_try_get_cluster_resources($ua, '');
    if ($resources_all && @$resources_all > 0) {
        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
            "Successfully retrieved " . scalar(@$resources_all) . " resources from cluster resources with no type filter");
        return $resources_all;
    }

    # If we didn't get any VMs from the cluster resources endpoints, try each node individually
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
        "No VMs found from cluster resources endpoints, trying individual nodes");
        
    # Check if the resources response contains any nodes at all
    my $resources_all_check = $self->_try_get_cluster_resources($ua, '');
    if ($resources_all_check && @$resources_all_check > 0) {
        my $has_nodes = 0;
        my $has_vms = 0;
        my @node_names = ();
        
        foreach my $resource (@$resources_all_check) {
            if ($resource->{type} eq 'node') {
                $has_nodes = 1;
                push @node_names, $resource->{node};
            }
            if ($resource->{type} eq 'qemu' || $resource->{type} eq 'lxc') {
                $has_vms = 1;
            }
        }
        
        if ($has_nodes) {
            $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
                "Found " . scalar(@node_names) . " nodes in cluster: " . join(", ", @node_names));
        } else {
            $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_get_real_vms_new',
                "No nodes found in cluster resources response");
        }
        
        if ($has_vms) {
            $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
                "Found VMs/containers in cluster resources response");
        } else {
            $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_get_real_vms_new',
                "No VMs/containers found in cluster resources response");
        }
    }

    # Placeholder for a fake request to keep the rest of the code working
    my $url = $self->{api_url_base} . '/version';
    my $req = HTTP::Request->new(GET => $url);

    # Add the API token header if available
    if ($self->{token_user} && $self->{token_value}) {
        $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_get_real_vms_new',
            "Using API token for authentication");

        # Format the token correctly
        my $token = "PVEAPIToken=" . $self->{token_user} . "=" . $self->{token_value};
        $req->header('Authorization' => $token);

        # Log the token format (without the actual value)
        $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_get_real_vms_new',
            "Token format: PVEAPIToken=" . $self->{token_user} . "=xxxxx");
    } elsif ($self->{api_token}) {
        # Use the stored API token if available
        $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_get_real_vms_new',
            "Using stored API token for authentication");

        $req->header('Authorization' => $self->{api_token});

        # Log that we're using the stored token
        $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_get_real_vms_new',
            "Using stored token from previous authentication");
    } else {
        $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_get_real_vms_new',
            "No API token available for authentication");
    }

    # Send the request
    my $res = $ua->request($req);

    # Log the response status
    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_get_real_vms_new',
        "API response status: " . $res->status_line);

    # Check if the request was successful
    if ($res->is_success) {
        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
            "Successfully retrieved response from Proxmox API");

        # Log the response content (first 200 chars)
        my $content_snippet = substr($res->content, 0, 200);
        $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_get_real_vms_new',
            "Response content (first 200 chars): $content_snippet...");

        # Parse the response
        my $response_data;
        eval {
            $response_data = decode_json($res->content);
        };

        if ($@) {
            $logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_get_real_vms_new',
                "Failed to parse response: $@");

            # Store debug info
            $self->{debug_info} = {
                response_code => $res->code,
                response_status => $res->status_line,
                response_content => $res->content,
                parse_error => "$@",
            };

            return [];
        }

        # Check if we have data
        if (!$response_data) {
            $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_get_real_vms_new',
                "No data found in response");

            # Store debug info
            $self->{debug_info} = {
                response_code => $res->code,
                response_status => $res->status_line,
                response_content => $res->content,
                error => "No data in response",
            };

            return [];
        }

        # Log the response data structure
        $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_get_real_vms_new',
            "Response data keys: " . join(', ', keys %$response_data));

        # Check if we have the data array
        if (!$response_data->{data}) {
            $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_get_real_vms_new',
                "No 'data' field found in response");

            # Store debug info
            $self->{debug_info} = {
                response_code => $res->code,
                response_status => $res->status_line,
                response_data => $response_data,
                error => "No 'data' field in response",
            };

            return [];
        }

        # Log the number of items in the data array
        $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_get_real_vms_new',
            "Number of items in data array: " . scalar(@{$response_data->{data}}));

        # Process the VM data
        my @vms;
        foreach my $vm (@{$response_data->{data}}) {
            # Log each item's type
            $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_get_real_vms_new',
                "Processing item of type: " . ($vm->{type} || 'unknown'));

            # Skip if not a VM or container
            next unless $vm->{type} eq 'qemu' || $vm->{type} eq 'lxc';

            # Extract the VM ID from the VMID field
            my $vmid = $vm->{vmid};

            # Log the VM being processed
            $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_get_real_vms_new',
                "Processing VM: ID=$vmid, Name=" . ($vm->{name} || 'unnamed') .
                ", Status=" . ($vm->{status} || 'unknown'));

            # Create a VM object
            my $vm_obj = {
                vmid => $vmid,
                name => $vm->{name} || "VM $vmid",
                status => $vm->{status} || 'unknown',
                type => $vm->{type} || 'unknown',
                maxmem => $vm->{maxmem} || 0,
                maxdisk => $vm->{maxdisk} || 0,
                uptime => $vm->{uptime} || 0,
                cpu => $vm->{cpu} || 0,
                server_id => $server_id,
            };

            # Add the VM to the list
            push @vms, $vm_obj;

            # Log that we added this VM
            $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_get_real_vms_new',
                "Added VM to list: ID=$vmid, Name=" . $vm_obj->{name});
        }

        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
            "Processed " . scalar(@vms) . " VMs from Proxmox API");

        # Store debug info
        $self->{debug_info} = {
            response_code => $res->code,
            response_status => $res->status_line,
            response_data => $response_data,
            processed_vms => scalar(@vms),
        };

        return \@vms;
    } else {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_get_real_vms_new',
            "Failed to retrieve VMs from cluster resources endpoint: " . $res->status_line);

        # Log the response content for debugging
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_get_real_vms_new',
            "Error response content: " . $res->content);

        # Try each node individually
        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
            "Trying to get VMs from each node individually");

        my @all_vms = ();

        # Loop through each node
        foreach my $node_name (@node_names) {
            $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
                "Trying to get VMs from node: $node_name");

            # Try to get QEMU VMs from this node
            my $node_url = $self->{api_url_base} . '/nodes/' . $node_name . '/qemu';
            $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_get_real_vms_new',
                "Getting QEMU VMs from URL: $node_url");

            my $node_req = HTTP::Request->new(GET => $node_url);

            # Add the API token header if available
            if ($self->{token_user} && $self->{token_value}) {
                my $token = "PVEAPIToken=" . $self->{token_user} . "=" . $self->{token_value};
                $node_req->header('Authorization' => $token);
            } elsif ($self->{api_token}) {
                $node_req->header('Authorization' => $self->{api_token});
            }

            # Send the request
            my $node_res = $ua->request($node_req);

            # Log the response status
            $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_get_real_vms_new',
                "Node $node_name QEMU API response status: " . $node_res->status_line);

            # Store this node's response for debugging
            $self->{debug_info}->{"node_${node_name}_qemu_response_code"} = $node_res->code;
            $self->{debug_info}->{"node_${node_name}_qemu_response_status"} = $node_res->status_line;

            if ($node_res->is_success) {
                $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
                    "Successfully retrieved QEMU VMs from node: $node_name");

                # Parse the response
                my $response_data;
                eval {
                    $response_data = decode_json($node_res->content);
                };

                if ($@) {
                    $logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_get_real_vms_new',
                        "Failed to parse QEMU response from node $node_name: $@");
                    next; # Try the next node
                }

                # Check if we have data
                if (!$response_data || !$response_data->{data}) {
                    $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_get_real_vms_new',
                        "No QEMU VM data found in response from node $node_name");
                    next; # Try the next node
                }

                # Process the VM data from this node
                foreach my $vm (@{$response_data->{data}}) {
                    # Extract the VM ID
                    my $vmid = $vm->{vmid};

                    # Log the VM being processed
                    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_get_real_vms_new',
                        "Processing QEMU VM from node $node_name: ID=$vmid, Name=" . ($vm->{name} || 'unnamed'));

                    # Create a VM object
                    my $vm_obj = {
                        vmid => $vmid,
                        name => $vm->{name} || "VM $vmid",
                        status => $vm->{status} || 'unknown',
                        type => 'qemu',
                        node => $node_name,
                        maxmem => $vm->{maxmem} || 0,
                        maxdisk => $vm->{maxdisk} || 0,
                        uptime => $vm->{uptime} || 0,
                        cpu => $vm->{cpus} || 0,  # Note: might be 'cpus' instead of 'cpu'
                        server_id => $server_id,
                    };

                    # Add the VM to the list
                    push @all_vms, $vm_obj;

                    # Log that we added this VM
                    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_get_real_vms_new',
                        "Added QEMU VM to list from node $node_name: ID=$vmid, Name=" . $vm_obj->{name});
                }

                $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
                    "Processed " . scalar(@{$response_data->{data}}) . " QEMU VMs from node $node_name");
            }

            # Now try to get LXC containers from this node
            my $lxc_url = $self->{api_url_base} . '/nodes/' . $node_name . '/lxc';
            $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_get_real_vms_new',
                "Getting LXC containers from URL: $lxc_url");

            my $lxc_req = HTTP::Request->new(GET => $lxc_url);

            # Add the API token header if available
            if ($self->{token_user} && $self->{token_value}) {
                my $token = "PVEAPIToken=" . $self->{token_user} . "=" . $self->{token_value};
                $lxc_req->header('Authorization' => $token);
            } elsif ($self->{api_token}) {
                $lxc_req->header('Authorization' => $self->{api_token});
            }

            # Send the request
            my $lxc_res = $ua->request($lxc_req);

            # Log the response status
            $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_get_real_vms_new',
                "Node $node_name LXC API response status: " . $lxc_res->status_line);

            # Store this node's LXC response for debugging
            $self->{debug_info}->{"node_${node_name}_lxc_response_code"} = $lxc_res->code;
            $self->{debug_info}->{"node_${node_name}_lxc_response_status"} = $lxc_res->status_line;

            if ($lxc_res->is_success) {
                $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
                    "Successfully retrieved LXC containers from node: $node_name");

                # Parse the response
                my $response_data;
                eval {
                    $response_data = decode_json($lxc_res->content);
                };

                if ($@) {
                    $logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_get_real_vms_new',
                        "Failed to parse LXC response from node $node_name: $@");
                    next; # Try the next node
                }

                # Check if we have data
                if (!$response_data || !$response_data->{data}) {
                    $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_get_real_vms_new',
                        "No LXC container data found in response from node $node_name");
                    next; # Try the next node
                }

                # Process the LXC container data from this node
                foreach my $container (@{$response_data->{data}}) {
                    # Extract the container ID
                    my $vmid = $container->{vmid};

                    # Log the container being processed
                    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_get_real_vms_new',
                        "Processing LXC container from node $node_name: ID=$vmid, Name=" . ($container->{name} || 'unnamed'));

                    # Create a VM object
                    my $vm_obj = {
                        vmid => $vmid,
                        name => $container->{name} || "Container $vmid",
                        status => $container->{status} || 'unknown',
                        type => 'lxc',
                        node => $node_name,
                        maxmem => $container->{maxmem} || 0,
                        maxdisk => $container->{maxdisk} || 0,
                        uptime => $container->{uptime} || 0,
                        cpu => $container->{cpus} || 0,
                        server_id => $server_id,
                    };

                    # Add the container to the list
                    push @all_vms, $vm_obj;

                    # Log that we added this container
                    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_get_real_vms_new',
                        "Added LXC container to list from node $node_name: ID=$vmid, Name=" . $vm_obj->{name});
                }

                $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
                    "Processed " . scalar(@{$response_data->{data}}) . " LXC containers from node $node_name");
            }
        }

        # After trying all nodes, check if we found any VMs
        if (@all_vms) {
            $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
                "Found a total of " . scalar(@all_vms) . " VMs/containers across all nodes");

            # Store debug info
            $self->{debug_info}->{processed_vms} = scalar(@all_vms);
            $self->{debug_info}->{original_error} = "First API request failed: " . $res->status_line;
            $self->{debug_info}->{used_node_endpoints} = 1;

            return \@all_vms;
        } else {
            # No VMs found on any node
            $logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_get_real_vms_new',
                "Failed to find any VMs or containers on any node");

            # Store debug info
            $self->{debug_info}->{error} = "No VMs found on any node";
            $self->{debug_info}->{original_error} = "First API request failed: " . $res->status_line;

            return [];
        }
    }
}

# This duplicate test_proxmox_node method has been removed to fix declaration errors

# Helper function to try getting VMs from a specific node
sub _try_get_node_vms {
    my ($self, $ua, $node_name) = @_;

    my $logging = Comserv::Util::Logging->instance;

    # Construct the URL for QEMU VMs on this node
    my $url = $self->{api_url_base} . '/nodes/' . $node_name . '/qemu';

    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_try_get_node_vms',
        "Trying to get QEMU VMs from node $node_name URL: $url");

    # Create the request
    my $req = HTTP::Request->new(GET => $url);

    # Add the API token header if available
    if ($self->{token_user} && $self->{token_value}) {
        my $token = "PVEAPIToken=" . $self->{token_user} . "=" . $self->{token_value};
        $req->header('Authorization' => $token);
    } elsif ($self->{api_token}) {
        $req->header('Authorization' => $self->{api_token});
    }

    # Send the request
    my $res = $ua->request($req);

    # Log the response status
    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_try_get_node_vms',
        "API response status for node $node_name: " . $res->status_line);

    # Store this response for debugging
    $self->{debug_info}->{"node_${node_name}_response_code"} = $res->code;
    $self->{debug_info}->{"node_${node_name}_response_status"} = $res->status_line;
    $self->{debug_info}->{"node_${node_name}_url"} = $url;

    if ($res->is_success) {
        # Parse the response
        my $response_data;
        eval {
            $response_data = decode_json($res->content);
        };

        if ($@) {
            $logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_try_get_node_vms',
                "Failed to parse response for node $node_name: $@");
            return [];
        }

        # Check if we have data
        if (!$response_data || !$response_data->{data}) {
            $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_try_get_node_vms',
                "No data found in response for node $node_name");
            return [];
        }

        # Process the VM data
        my @vms;
        foreach my $vm (@{$response_data->{data}}) {
            # Extract the VM ID
            my $vmid = $vm->{vmid};

            # Log the VM being processed
            $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_try_get_node_vms',
                "Processing VM from node $node_name: ID=$vmid, Name=" . ($vm->{name} || 'unnamed'));

            # Create a VM object
            my $vm_obj = {
                vmid => $vmid,
                name => $vm->{name} || "VM $vmid",
                status => $vm->{status} || 'unknown',
                type => 'qemu',
                node => $node_name,
                maxmem => $vm->{maxmem} || 0,
                maxdisk => $vm->{maxdisk} || 0,
                uptime => $vm->{uptime} || 0,
                cpu => $vm->{cpu} || 0,
                server_id => $self->{server_id},
            };

            # Add the VM to the list
            push @vms, $vm_obj;

            # Log that we added this VM
            $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_try_get_node_vms',
                "Added VM to list from node $node_name: ID=$vmid, Name=" . $vm_obj->{name});
        }

        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_try_get_node_vms',
            "Processed " . scalar(@vms) . " VMs from node $node_name");

        return \@vms;
    }

    # If the request failed, log the error and return an empty array
    $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_try_get_node_vms',
        "Failed to get VMs from node $node_name: " . $res->status_line);

    return [];
}

# Helper function to try getting cluster resources with different type parameters
sub _try_get_cluster_resources {
    my ($self, $ua, $type) = @_;

    my $logging = Comserv::Util::Logging->instance;

    # Construct the URL with or without the type parameter
    my $url = $self->{api_url_base} . '/cluster/resources';
    
    # Check if the type is valid (according to API error, valid types are: vm, storage, node, sdn)
    # If 'qemu' is passed, use 'vm' instead as that's the correct parameter for VMs
    if ($type) {
        if ($type eq 'qemu') {
            $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_try_get_cluster_resources',
                "Converting invalid type 'qemu' to valid type 'vm'");
            $url .= "?type=vm";
        } else {
            $url .= "?type=$type";
        }
    }

    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_try_get_cluster_resources',
        "Trying to get resources from URL: $url");

    # Create the request
    my $req = HTTP::Request->new(GET => $url);

    # Add the API token header if available
    if ($self->{token_user} && $self->{token_value}) {
        my $token = "PVEAPIToken=" . $self->{token_user} . "=" . $self->{token_value};
        $req->header('Authorization' => $token);
    } elsif ($self->{api_token}) {
        $req->header('Authorization' => $self->{api_token});
    }

    # Send the request
    my $res = $ua->request($req);

    # Log the response status
    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_try_get_cluster_resources',
        "API response status for type=$type: " . $res->status_line);

    # Store this response for debugging
    $self->{debug_info}->{"resources_${type}_response_code"} = $res->code;
    $self->{debug_info}->{"resources_${type}_response_status"} = $res->status_line;
    $self->{debug_info}->{"resources_${type}_url"} = $url;
    $self->{debug_info}->{"resources_${type}_response_content"} = substr($res->content, 0, 1000);

    if ($res->is_success) {
        # Parse the response
        my $response_data;
        eval {
            $response_data = decode_json($res->content);
        };

        if ($@) {
            $logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_try_get_cluster_resources',
                "Failed to parse response for type=$type: $@");
            return [];
        }

        # Check if we have data
        if (!$response_data || !$response_data->{data}) {
            $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_try_get_cluster_resources',
                "No data found in response for type=$type");
            return [];
        }

        # Process the resource data
        my @vms;
        foreach my $resource (@{$response_data->{data}}) {
            # Skip resources that are not VMs or containers
            # When using type=vm, the resources will have type=qemu or type=lxc
            # But we need to check for vmid to make sure it's actually a VM/container
            next unless ($resource->{type} eq 'qemu' || $resource->{type} eq 'lxc') && $resource->{vmid};

            # Extract the VM ID
            my $vmid = $resource->{vmid};

            # Log the resource being processed
            $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_try_get_cluster_resources',
                "Processing resource: ID=$vmid, Name=" . ($resource->{name} || 'unnamed') . ", Type=" . $resource->{type});

            # Create a VM object
            my $vm_obj = {
                vmid => $vmid,
                name => $resource->{name} || "VM $vmid",
                status => $resource->{status} || 'unknown',
                type => $resource->{type},
                node => $resource->{node},
                maxmem => $resource->{maxmem} || 0,
                maxdisk => $resource->{maxdisk} || 0,
                uptime => $resource->{uptime} || 0,
                cpu => $resource->{cpu} || 0,
                server_id => $self->{server_id},
            };

            # Add the VM to the list
            push @vms, $vm_obj;

            # Log that we added this VM
            $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_try_get_cluster_resources',
                "Added resource to list: ID=$vmid, Name=" . $vm_obj->{name} . ", Type=" . $vm_obj->{type});
        }

        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_try_get_cluster_resources',
            "Processed " . scalar(@vms) . " VMs/containers from resources with type=$type");

        return \@vms;
    }

    # If the request failed, log the error and return an empty array
    $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_try_get_cluster_resources',
        "Failed to get resources with type=$type: " . $res->status_line);

    return [];
}

# Get the list of available Proxmox servers
sub get_servers {
    my ($self) = @_;

    my $logging = Comserv::Util::Logging->instance;
    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'get_servers',
        "Getting list of available Proxmox servers");

    # Get the list of servers from the credentials file
    my $servers = Comserv::Util::ProxmoxCredentials::get_all_servers();

    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'get_servers',
        "Found " . scalar(@$servers) . " Proxmox servers");

    return $servers;
}

# Authenticate with the Proxmox server
sub authenticate {
    my ($self) = @_;

    my $logging = Comserv::Util::Logging->instance;
    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'authenticate',
        "Authenticating with Proxmox server: " . $self->{server_id});

    # Check connection to the Proxmox server
    my $auth_success = $self->check_connection();

    if ($auth_success) {
        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'authenticate',
            "Successfully authenticated with Proxmox server: " . $self->{server_id});
        return 1;
    } else {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'authenticate',
            "Failed to authenticate with Proxmox server: " . $self->{server_id});
        return 0;
    }
}

# Get the list of available VM templates
sub get_available_templates {
    my ($self) = @_;

    my $logging = Comserv::Util::Logging->instance;
    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'get_available_templates',
        "Getting list of available VM templates");

    $self->_load_credentials() unless $self->{credentials_loaded};

    my @templates;

    return \@templates unless $self->{api_url_base};
    my $ua          = $self->_make_ua(10);
    my $auth_header = $self->_auth_header() or return \@templates;
    my $node_name   = $self->_resolve_node($ua, $auth_header);

    my $storage_req = HTTP::Request->new(GET => $self->{api_url_base} . "/nodes/$node_name/storage");
    $storage_req->header(Authorization => $auth_header);
    my $storage_res = $ua->request($storage_req);
    if ($storage_res->is_success) {
        my $sd = eval { decode_json($storage_res->decoded_content) };
        for my $store (@{ $sd->{data} || [] }) {
            my $sname = $store->{storage} or next;
            my $content = $store->{content} || '';
            next unless $content =~ /iso/;

            my $content_req = HTTP::Request->new(GET =>
                $self->{api_url_base} . "/nodes/$node_name/storage/$sname/content?content=iso");
            $content_req->header(Authorization => $auth_header);
            my $content_res = $ua->request($content_req);
            if ($content_res->is_success) {
                my $cd = eval { decode_json($content_res->decoded_content) };
                for my $item (@{ $cd->{data} || [] }) {
                    my $volid = $item->{volid} or next;
                    (my $fname = $volid) =~ s{.*/}{};
                    $fname =~ s/\.iso$//i;
                    push @templates, {
                        id      => $volid,
                        name    => $fname,
                        storage => $sname,
                    };
                }
            }
        }
    }

    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'get_available_templates',
        "Found " . scalar(@templates) . " ISO images from Proxmox");

    return \@templates;
}

# Create a new VM
sub create_vm {
    my ($self, $params) = @_;

    my $logging = Comserv::Util::Logging->instance;
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'create_vm',
        "Creating new VM with hostname: " . $params->{hostname});

    $self->_load_credentials() unless $self->{credentials_loaded};

    if (!$self->{api_url_base}) {
        $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'create_vm',
            "No valid API URL found for server: " . $self->{server_id});
        return { success => 0, error => "No valid API URL found" };
    }

    my $ua          = $self->_make_ua(30);
    my $auth_header = $self->_auth_header()
        or return { success => 0, error => "No authentication credentials available" };
    my $node_name = $self->_resolve_node($ua, $auth_header);

    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'create_vm',
        "Resolved node name: $node_name");

    my $nextid_req = HTTP::Request->new(GET => $self->{api_url_base} . '/cluster/nextid');
    $nextid_req->header(Authorization => $auth_header);
    my $nextid_res = $ua->request($nextid_req);
    my $vmid;
    if ($nextid_res->is_success) {
        my $data = eval { decode_json($nextid_res->decoded_content) };
        $vmid = $data->{data} if $data && $data->{data};
    }
    $vmid ||= int(rand(900)) + 100;

    my $disk_size   = $params->{disk_size}  || 20;
    my $memory      = $params->{memory}     || 2048;
    my $cpu         = $params->{cpu}        || 2;
    my $hostname    = $params->{hostname}   || "vm-$vmid";
    my $template    = $params->{template}   || '';
    my $network_type = $params->{network_type} || 'dhcp';

    my %post_params = (
        vmid     => $vmid,
        name     => $hostname,
        cores    => $cpu,
        memory   => $memory,
        scsihw   => 'virtio-scsi-pci',
        ostype   => 'l26',
        agent    => ($params->{enable_qemu_agent} ? '1' : '0'),
        onboot   => ($params->{start_on_boot}     ? '1' : '0'),
    );

    $post_params{scsi0} = "local-lvm:$disk_size";
    if ($template) {
        my $ide2_val = "$template,media=cdrom";
        if ($template =~ m{^([^:]+):iso/(.+)$}) {
            my ($storage_name, $iso_file) = ($1, $2);
            my $content_url = $self->{api_url_base} . "/nodes/$node_name/storage/$storage_name/content?content=iso";
            my $sz_req = HTTP::Request->new(GET => $content_url);
            $sz_req->header(Authorization => $auth_header);
            my $sz_res = $ua->request($sz_req);
            if ($sz_res->is_success) {
                my $sz_data = eval { decode_json($sz_res->decoded_content) };
                for my $item (@{ $sz_data->{data} || [] }) {
                    if (($item->{volid} || '') eq $template && $item->{size}) {
                        my $size_kb = int($item->{size} / 1024);
                        $ide2_val = "$template,media=cdrom,size=${size_kb}K";
                        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'create_vm',
                            "Found ISO size: ${size_kb}K for $template");
                        last;
                    }
                }
            }
        }
        $post_params{ide2} = $ide2_val;
        $post_params{boot} = 'order=ide2;scsi0';
    } else {
        $post_params{boot} = 'order=scsi0';
    }

    $post_params{net0} = 'virtio,bridge=vmbr0';

    my $create_url = $self->{api_url_base} . "/nodes/$node_name/qemu";
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'create_vm',
        "POSTing VM creation to $create_url with vmid=$vmid, name=$hostname");

    my $create_req = HTTP::Request->new(POST => $create_url);
    $create_req->header(Authorization   => $auth_header);
    $create_req->header('Content-Type'  => 'application/x-www-form-urlencoded');

    my $body = join('&', map { uri_escape($_) . '=' . uri_escape($post_params{$_}) } keys %post_params);
    $create_req->content($body);

    my $create_res = $ua->request($create_req);

    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'create_vm',
        "Proxmox API response: " . $create_res->status_line . " — " . substr($create_res->decoded_content, 0, 500));

    if ($create_res->is_success) {
        my $resp_data = eval { decode_json($create_res->decoded_content) };
        my $task_id   = ($resp_data && $resp_data->{data}) ? $resp_data->{data} : '';
        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'create_vm',
            "VM created successfully: vmid=$vmid, task=$task_id");
        if ($params->{start_after_creation}) {
            my $start_req = HTTP::Request->new(POST =>
                $self->{api_url_base} . "/nodes/$node_name/qemu/$vmid/status/start");
            $start_req->header(Authorization  => $auth_header);
            $start_req->content('');
            $ua->request($start_req);
        }
        return { success => 1, vmid => $vmid, task_id => $task_id };
    } else {
        my $err = $create_res->decoded_content || $create_res->status_line;
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'create_vm',
            "VM creation failed: $err");
        return { success => 0, error => "Proxmox API error (${\$create_res->code}): $err" };
    }
}

sub get_vm_config {
    my ($self, $vmid) = @_;

    my $logging = Comserv::Util::Logging->instance;
    $self->_load_credentials() unless $self->{credentials_loaded};

    return undef unless $self->{api_url_base};

    my $ua          = $self->_make_ua(10);
    my $auth_header = $self->_auth_header() or return undef;
    my $node_name   = $self->_resolve_node($ua, $auth_header);

    my $req = HTTP::Request->new(GET => $self->{api_url_base} . "/nodes/$node_name/qemu/$vmid/config");
    $req->header(Authorization => $auth_header);
    my $res = $ua->request($req);

    if ($res->is_success) {
        my $data = eval { decode_json($res->decoded_content) };
        return ($data && $data->{data}) ? $data->{data} : undef;
    }
    $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'get_vm_config',
        "Failed to get config for VM $vmid: " . $res->status_line);
    return undef;
}

sub set_vm_cdrom {
    my ($self, $vmid, $iso_volid) = @_;

    my $logging = Comserv::Util::Logging->instance;
    $self->_load_credentials() unless $self->{credentials_loaded};

    return { success => 0, error => 'No API URL' } unless $self->{api_url_base};

    my $ua          = $self->_make_ua(15);
    my $auth_header = $self->_auth_header()
        or return { success => 0, error => 'No credentials' };
    my $node_name = $self->_resolve_node($ua, $auth_header);

    my $config_url = $self->{api_url_base} . "/nodes/$node_name/qemu/$vmid/config";

    my $req = HTTP::Request->new(PUT => $config_url);
    $req->header(Authorization  => $auth_header);
    $req->header('Content-Type' => 'application/x-www-form-urlencoded');

    my $body;
    if ($iso_volid) {
        $body = uri_escape('ide2') . '=' . uri_escape("$iso_volid,media=cdrom");
    } else {
        $body = uri_escape('ide2') . '=' . uri_escape('none,media=cdrom');
    }
    $req->content($body);

    my $res = $ua->request($req);
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'set_vm_cdrom',
        "set_vm_cdrom vmid=$vmid iso=" . ($iso_volid||'(eject)') . " => " . $res->status_line);

    if ($res->is_success) {
        my $msg = $iso_volid ? "ISO attached: $iso_volid. Reboot or stop/start the VM to boot from it." : "ISO ejected";
        return { success => 1, message => $msg };
    } else {
        return { success => 0, error => "Proxmox API error (${\$res->code}): " . $res->decoded_content };
    }
}

sub resize_disk {
    my ($self, $vmid, $disk, $new_size_gb) = @_;

    my $logging = Comserv::Util::Logging->instance;
    $self->_load_credentials() unless $self->{credentials_loaded};

    return { success => 0, error => 'No API URL' }    unless $self->{api_url_base};
    return { success => 0, error => 'vmid required' } unless $vmid;
    return { success => 0, error => 'disk required' } unless $disk;
    return { success => 0, error => 'size must be a positive integer GB value' }
        unless $new_size_gb && $new_size_gb =~ /^\d+$/ && $new_size_gb > 0;

    my $ua          = $self->_make_ua(30);
    my $auth_header = $self->_auth_header()
        or return { success => 0, error => 'No credentials' };
    my $node_name   = $self->_resolve_node($ua, $auth_header);

    my $url = $self->{api_url_base} . "/nodes/$node_name/qemu/$vmid/resize";

    my $req = HTTP::Request->new(PUT => $url);
    $req->header(Authorization  => $auth_header);
    $req->header('Content-Type' => 'application/x-www-form-urlencoded');
    $req->content(uri_escape('disk') . '=' . uri_escape($disk) . '&'
                . uri_escape('size') . '=' . uri_escape("${new_size_gb}G"));

    my $res = $ua->request($req);
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'resize_disk',
        "resize_disk vmid=$vmid disk=$disk size=${new_size_gb}G => " . $res->status_line);

    if ($res->is_success) {
        return { success => 1, message => "Disk $disk resized to ${new_size_gb} GB. "
                                        . "The virtual disk is larger — resize the partition inside the OS to use the new space." };
    } else {
        my $err = $res->decoded_content || $res->status_line;
        return { success => 0, error => "Proxmox API error (${\$res->code}): $err" };
    }
}

sub update_vm_config {
    my ($self, $vmid, $params) = @_;

    my $logging = Comserv::Util::Logging->instance;
    $self->_load_credentials() unless $self->{credentials_loaded};

    return { success => 0, error => 'No API URL' } unless $self->{api_url_base};

    my $ua          = $self->_make_ua(15);
    my $auth_header = $self->_auth_header()
        or return { success => 0, error => 'No credentials' };
    my $node_name = $self->_resolve_node($ua, $auth_header);

    my %allowed = (name => 1, memory => 1, cores => 1, sockets => 1, description => 1,
                   onboot => 1, agent => 1, cpu => 1);
    my %put_params;
    for my $key (keys %$params) {
        next unless $allowed{$key};
        $put_params{$key} = $params->{$key} if defined $params->{$key} && $params->{$key} ne '';
    }

    return { success => 0, error => 'No valid fields to update' } unless %put_params;

    my $config_url = $self->{api_url_base} . "/nodes/$node_name/qemu/$vmid/config";
    my $req = HTTP::Request->new(PUT => $config_url);
    $req->header(Authorization  => $auth_header);
    $req->header('Content-Type' => 'application/x-www-form-urlencoded');

    my $body = join('&', map { uri_escape($_) . '=' . uri_escape($put_params{$_}) } keys %put_params);
    $req->content($body);

    my $res = $ua->request($req);
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'update_vm_config',
        "update_vm_config vmid=$vmid => " . $res->status_line);

    if ($res->is_success) {
        return { success => 1, message => "VM $vmid configuration updated" };
    } else {
        return { success => 0, error => "Proxmox API error (${\$res->code}): " . $res->decoded_content };
    }
}

sub vm_power_action {
    my ($self, $vmid, $action) = @_;

    my $logging = Comserv::Util::Logging->instance;
    $self->_load_credentials() unless $self->{credentials_loaded};

    return { success => 0, error => 'No API URL' } unless $self->{api_url_base};

    my $ua          = $self->_make_ua(15);
    my $auth_header = $self->_auth_header()
        or return { success => 0, error => 'No credentials' };
    my $node_name = $self->_resolve_node($ua, $auth_header);

    my %valid_actions = (start => 1, stop => 1, shutdown => 1, reboot => 1, reset => 1);
    unless ($valid_actions{$action}) {
        return { success => 0, error => "Invalid action: $action" };
    }

    my $url = $self->{api_url_base} . "/nodes/$node_name/qemu/$vmid/status/$action";
    my $req = HTTP::Request->new(POST => $url);
    $req->header(Authorization  => $auth_header);
    $req->header('Content-Type' => 'application/x-www-form-urlencoded');
    $req->content('');

    my $res = $ua->request($req);
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'vm_power_action',
        "vm_power_action vmid=$vmid action=$action => " . $res->status_line);

    if ($res->is_success) {
        my $data = eval { decode_json($res->decoded_content) };
        my $task_id = ($data && $data->{data}) ? $data->{data} : '';
        return { success => 1, message => "VM $action initiated", task_id => $task_id };
    } else {
        return { success => 0, error => "Proxmox API error (${\$res->code}): " . $res->decoded_content };
    }
}

sub get_power_progress {
    my ($self, $vmid, $upid) = @_;

    my $logging = Comserv::Util::Logging->instance;
    $self->_load_credentials() unless $self->{credentials_loaded};
    return { success => 0, error => 'No API URL' } unless $self->{api_url_base};
    return { success => 0, error => 'vmid required' } unless defined $vmid && $vmid =~ /^\d+$/;
    if (defined $upid && $upid ne '' && $upid !~ /\AUPID:[A-Za-z0-9_.:!\@-]+\z/) {
        return { success => 0, error => 'Invalid task id' };
    }

    my $ua          = $self->_make_ua(15);
    my $auth_header = $self->_auth_header()
        or return { success => 0, error => 'No credentials' };
    my $node_name = $self->_resolve_node($ua, $auth_header);

    my $api_get = sub {
        my ($path) = @_;
        my $req = HTTP::Request->new(GET => $self->{api_url_base} . $path);
        $req->header(Authorization => $auth_header);
        my $res = $ua->request($req);
        my $data;
        if ($res->is_success) {
            my $parsed = eval { decode_json($res->decoded_content) };
            $data = $parsed->{data} if $parsed && exists $parsed->{data};
        }
        return ($res, $data);
    };

    if (!$upid) {
        my ($tres, $tasks) = $api_get->("/nodes/$node_name/tasks?vmid=$vmid&limit=12");
        unless ($tres->is_success) {
            $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'get_power_progress',
                "task list failed for VM $vmid: " . $tres->status_line);
            return { success => 0, error => 'Could not list tasks: ' . $tres->status_line };
        }
        for my $t (@{ $tasks || [] }) {
            next unless ($t->{type} || '') =~ /^qm(?:reboot|start|stop|shutdown|reset)$/;
            $upid = $t->{upid} || '';
            last;
        }
    }

    my $task = {
        upid => $upid || '', log => [], running => 0,
        type => '', status => '', exitstatus => '',
    };
    if ($upid) {
        my ($sres, $sdata) = $api_get->("/nodes/$node_name/tasks/$upid/status");
        if ($sres->is_success && ref $sdata eq 'HASH') {
            $task->{type}       = $sdata->{type} || '';
            $task->{status}     = $sdata->{status} || '';
            $task->{exitstatus} = defined $sdata->{exitstatus} ? $sdata->{exitstatus} : '';
            $task->{user}       = $sdata->{user} || '';
            $task->{running}    = (($sdata->{status} || '') eq 'running') ? 1 : 0;
            $task->{starttime}  = $sdata->{starttime};
            $task->{endtime}    = $sdata->{endtime};
        } else {
            $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'get_power_progress',
                "task status failed for VM $vmid: " . $sres->status_line);
            $task->{error} = 'Task status unavailable: ' . $sres->status_line;
        }
        my ($lres, $ldata) = $api_get->("/nodes/$node_name/tasks/$upid/log?start=0&limit=80");
        if ($lres->is_success && ref $ldata eq 'ARRAY') {
            $task->{log} = [ map { ref $_ eq 'HASH' ? ($_->{t} // '') : "$_" } @$ldata ];
        } elsif (!$lres->is_success) {
            $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'get_power_progress',
                "task log failed for VM $vmid: " . $lres->status_line);
        }
    }

    my (undef, $pending) = $api_get->("/nodes/$node_name/qemu/$vmid/pending");
    my ($cres, $current) = $api_get->("/nodes/$node_name/qemu/$vmid/status/current");
    unless ($cres->is_success) {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'get_power_progress',
            "VM status failed for $vmid: " . $cres->status_line);
    }

    my ($mem_current, $mem_pending);
    if (ref $pending eq 'ARRAY') {
        for my $row (@$pending) {
            next unless ($row->{key} || '') eq 'memory';
            $mem_current = $row->{value} if defined $row->{value};
            if (defined $row->{pending} && $row->{pending} ne '') {
                $mem_pending = $row->{pending};
            }
        }
    }
    my $vm_status = (ref $current eq 'HASH') ? ($current->{status} || '') : '';
    my $maxmem_mb = 0;
    if (ref $current eq 'HASH' && $current->{maxmem}) {
        $maxmem_mb = int($current->{maxmem} / 1048576);
    }
    my $intended = defined $mem_pending ? $mem_pending : $mem_current;
    my $applied = 0;
    if ($vm_status eq 'running' && defined $intended && $intended =~ /^\d+$/
        && abs($maxmem_mb - $intended) < 128) {
        $applied = 1;
    }

    my $log_text = join "\n", @{ $task->{log} || [] };
    my $hint = '';
    my $exit = $task->{exitstatus} || '';
    if ($log_text =~ /Guest Agent is not running/i || $exit =~ /guest-ping|timeout/i) {
        $hint = 'Reboot asked the guest agent to power the VM off so QEMU would restart and pick up pending memory. The agent is not running, so Proxmox timed out. A failed reboot does not apply memory. If the VM is stopped, Start creates a new QEMU process and applies the pending value.';
    } elsif (defined $mem_pending && $vm_status eq 'stopped') {
        $hint = 'VM is stopped with memory still pending. Start applies it. Reboot will not, until a new QEMU process is created.';
    } elsif (defined $mem_pending && $vm_status eq 'running') {
        $hint = 'Pending memory is not live. The QEMU process is still the old one. Stop, then start.';
    }

    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'get_power_progress',
        "VM $vmid status=$vm_status mem=" . ($mem_current // '')
        . " pending=" . ($mem_pending // '')
        . " task=" . ($task->{type} || '-')
        . " exit=" . ($exit || $task->{status} || '-'));

    return {
        success           => 1,
        vmid              => 0 + $vmid,
        vm_status         => $vm_status,
        maxmem_mb         => $maxmem_mb,
        memory_current_mb => $mem_current,
        memory_pending_mb => $mem_pending,
        memory_applied    => $applied,
        hint              => $hint,
        task              => $task,
    };
}

sub get_storages_for_iso {
    my ($self) = @_;

    my $logging = Comserv::Util::Logging->instance;
    $self->_load_credentials() unless $self->{credentials_loaded};

    return [] unless $self->{api_url_base};

    my $ua          = $self->_make_ua(10);
    my $auth_header = $self->_auth_header() or return [];
    my $node_name   = $self->_resolve_node($ua, $auth_header);

    my $req = HTTP::Request->new(GET => $self->{api_url_base} . "/nodes/$node_name/storage");
    $req->header(Authorization => $auth_header);
    my $res = $ua->request($req);
    return [] unless $res->is_success;

    my $data = eval { decode_json($res->decoded_content) };
    return [] unless $data && $data->{data};

    my @storages;
    for my $s (@{ $data->{data} }) {
        my $content = $s->{content} || '';
        push @storages, { id => $s->{storage}, type => $s->{type} }
            if $content =~ /\biso\b/;
    }
    return \@storages;
}

sub upload_iso_to_proxmox {
    my ($self, $local_path, $storage) = @_;

    my $logging = Comserv::Util::Logging->instance;
    $self->_load_credentials() unless $self->{credentials_loaded};

    return { success => 0, error => 'No API URL' } unless $self->{api_url_base};
    return { success => 0, error => "File not found: $local_path" } unless -f $local_path;

    $storage ||= 'local';

    my $ua          = $self->_make_ua(300);
    my $auth_header = $self->_auth_header()
        or return { success => 0, error => 'No credentials' };
    my $node_name = $self->_resolve_node($ua, $auth_header);

    my $filename = $local_path;
    $filename =~ s{.*/}{};

    my $upload_url = $self->{api_url_base} . "/nodes/$node_name/storage/$storage/upload";

    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'upload_iso_to_proxmox',
        "Uploading $filename to $upload_url");

    my $req = POST($upload_url,
        Content_Type => 'form-data',
        Content => [
            content  => 'iso',
            filename => [ $local_path, $filename, 'Content-Type' => 'application/octet-stream' ],
        ],
    );
    $req->header(Authorization => $auth_header);

    my $res = $ua->request($req);

    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'upload_iso_to_proxmox',
        "Upload response: " . $res->status_line . " " . substr($res->decoded_content, 0, 300));

    if ($res->is_success) {
        my $data = eval { decode_json($res->decoded_content) };
        return { success => 1, message => "ISO '$filename' uploaded to Proxmox $storage storage",
                 task_id => ($data && $data->{data}) ? $data->{data} : '' };
    } else {
        return { success => 0, error => "Upload failed (${\$res->code}): " . $res->decoded_content };
    }
}

sub get_vm_status {
    my ($self, $vmid) = @_;

    my $logging = Comserv::Util::Logging->instance;
    $self->_load_credentials() unless $self->{credentials_loaded};
    return undef unless $self->{api_url_base};

    my $ua          = $self->_make_ua(10);
    my $auth_header = $self->_auth_header() or return undef;
    my $node_name   = $self->_resolve_node($ua, $auth_header);

    my $req = HTTP::Request->new(GET => $self->{api_url_base} . "/nodes/$node_name/qemu/$vmid/status/current");
    $req->header(Authorization => $auth_header);
    my $res = $ua->request($req);
    return undef unless $res->is_success;
    my $data = eval { decode_json($res->decoded_content) };
    return ($data && $data->{data}) ? $data->{data} : undef;
}

sub get_next_vmid {
    my ($self) = @_;

    $self->_load_credentials() unless $self->{credentials_loaded};
    return undef unless $self->{api_url_base};

    my $ua          = $self->_make_ua(10);
    my $auth_header = $self->_auth_header() or return undef;

    my $req = HTTP::Request->new(GET => $self->{api_url_base} . "/cluster/nextid");
    $req->header(Authorization => $auth_header);
    my $res = $ua->request($req);
    return undef unless $res->is_success;
    my $data = eval { decode_json($res->decoded_content) };
    return ($data && $data->{data}) ? $data->{data} : undef;
}

sub clone_vm {
    my ($self, $vmid, $newid, $name, $full, $storage) = @_;

    my $logging = Comserv::Util::Logging->instance;
    $self->_load_credentials() unless $self->{credentials_loaded};
    return { success => 0, error => 'No API URL' } unless $self->{api_url_base};

    my $ua          = $self->_make_ua(60);
    my $auth_header = $self->_auth_header()
        or return { success => 0, error => 'No credentials' };
    my $node_name = $self->_resolve_node($ua, $auth_header);

    my $url = $self->{api_url_base} . "/nodes/$node_name/qemu/$vmid/clone";
    my $req = HTTP::Request->new(POST => $url);
    $req->header(Authorization  => $auth_header);
    $req->header('Content-Type' => 'application/x-www-form-urlencoded');

    my @parts = ("newid=" . uri_escape($newid));
    push @parts, "name="    . uri_escape($name)    if $name;
    push @parts, "full="    . ($full ? '1' : '0');
    push @parts, "storage=" . uri_escape($storage)  if $storage;
    $req->content(join('&', @parts));

    my $res = $ua->request($req);
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'clone_vm',
        "clone_vm src=$vmid newid=$newid => " . $res->status_line);

    if ($res->is_success) {
        my $data = eval { decode_json($res->decoded_content) };
        return { success => 1, task_id => ($data && $data->{data}) ? $data->{data} : '', vmid => $newid };
    } else {
        return { success => 0, error => "Proxmox API error (${\$res->code}): " . $res->decoded_content };
    }
}

sub list_storages {
    my ($self, $content_filter) = @_;

    $self->_load_credentials() unless $self->{credentials_loaded};
    return [] unless $self->{api_url_base};

    my $ua          = $self->_make_ua(10);
    my $auth_header = $self->_auth_header() or return [];
    my $node_name   = $self->_resolve_node($ua, $auth_header);

    my $req = HTTP::Request->new(GET => $self->{api_url_base} . "/nodes/$node_name/storage");
    $req->header(Authorization => $auth_header);
    my $res = $ua->request($req);
    return [] unless $res->is_success;
    my $data = eval { decode_json($res->decoded_content) };
    return [] unless $data && $data->{data};

    my @storages = @{ $data->{data} };
    if ($content_filter) {
        @storages = grep { ($_->{content} || '') =~ /\b$content_filter\b/ } @storages;
    }
    return \@storages;
}

sub restore_as_new_vm {
    my ($self, $new_vmid, $volid, $storage, $name) = @_;

    my $logging = Comserv::Util::Logging->instance;
    $self->_load_credentials() unless $self->{credentials_loaded};
    return { success => 0, error => 'No API URL' } unless $self->{api_url_base};

    my $ua          = $self->_make_ua(120);
    my $auth_header = $self->_auth_header()
        or return { success => 0, error => 'No credentials' };
    my $node_name = $self->_resolve_node($ua, $auth_header);

    my $url = $self->{api_url_base} . "/nodes/$node_name/qemu";
    my $req = HTTP::Request->new(POST => $url);
    $req->header(Authorization  => $auth_header);
    $req->header('Content-Type' => 'application/x-www-form-urlencoded');

    my $body = "vmid=" . uri_escape($new_vmid)
             . "&archive=" . uri_escape($volid)
             . "&unique=1";
    $body .= "&storage=" . uri_escape($storage) if $storage;
    $body .= "&name="    . uri_escape($name)    if $name;
    $req->content($body);

    my $res = $ua->request($req);
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'restore_as_new_vm',
        "restore_as_new_vm newid=$new_vmid volid=$volid => " . $res->status_line);

    if ($res->is_success) {
        my $data = eval { decode_json($res->decoded_content) };
        return { success => 1, task_id => ($data && $data->{data}) ? $data->{data} : '', vmid => $new_vmid };
    } else {
        return { success => 0, error => "Proxmox API error (${\$res->code}): " . $res->decoded_content };
    }
}

sub unlock_vm {
    my ($self, $vmid) = @_;

    my $logging = Comserv::Util::Logging->instance;
    $self->_load_credentials() unless $self->{credentials_loaded};
    return { success => 0, error => 'No API URL' } unless $self->{api_url_base};

    my $ua          = $self->_make_ua(15);
    my $auth_header = $self->_auth_header()
        or return { success => 0, error => 'No credentials' };
    my $node_name = $self->_resolve_node($ua, $auth_header);

    my $url = $self->{api_url_base} . "/nodes/$node_name/qemu/$vmid/unlock";
    my $req = HTTP::Request->new(PUT => $url);
    $req->header(Authorization  => $auth_header);
    $req->header('Content-Type' => 'application/x-www-form-urlencoded');
    $req->content('');

    my $res = $ua->request($req);
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'unlock_vm',
        "unlock_vm vmid=$vmid => " . $res->status_line);

    if ($res->is_success) {
        return { success => 1 };
    } else {
        return { success => 0, error => "Proxmox API error (${\$res->code}): " . $res->decoded_content };
    }
}

sub set_vm_config {
    my ($self, $vmid, %params) = @_;

    my $logging = Comserv::Util::Logging->instance;
    $self->_load_credentials() unless $self->{credentials_loaded};
    return { success => 0, error => 'No API URL' } unless $self->{api_url_base};

    my $ua          = $self->_make_ua(30);
    my $auth_header = $self->_auth_header()
        or return { success => 0, error => 'No credentials' };
    my $node_name = $self->_resolve_node($ua, $auth_header);

    my $url = $self->{api_url_base} . "/nodes/$node_name/qemu/$vmid/config";
    my $req = HTTP::Request->new(PUT => $url);
    $req->header(Authorization  => $auth_header);
    $req->header('Content-Type' => 'application/x-www-form-urlencoded');

    my @parts;
    for my $key (keys %params) {
        push @parts, uri_escape($key) . '=' . uri_escape($params{$key});
    }
    $req->content(join('&', @parts));

    my $res = $ua->request($req);
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'set_vm_config',
        "set_vm_config vmid=$vmid => " . $res->status_line);

    if ($res->is_success) {
        return { success => 1 };
    } else {
        return { success => 0, error => "Proxmox API error (${\$res->code}): " . $res->decoded_content };
    }
}

sub list_snapshots {
    my ($self, $vmid) = @_;

    $self->_load_credentials() unless $self->{credentials_loaded};
    return [] unless $self->{api_url_base};

    my $ua          = $self->_make_ua(10);
    my $auth_header = $self->_auth_header() or return [];
    my $node_name   = $self->_resolve_node($ua, $auth_header);

    my $req = HTTP::Request->new(GET => $self->{api_url_base} . "/nodes/$node_name/qemu/$vmid/snapshot");
    $req->header(Authorization => $auth_header);
    my $res = $ua->request($req);
    return [] unless $res->is_success;
    my $data = eval { decode_json($res->decoded_content) };
    return ($data && $data->{data}) ? $data->{data} : [];
}

sub create_snapshot {
    my ($self, $vmid, $snapname, $description) = @_;

    my $logging = Comserv::Util::Logging->instance;
    $self->_load_credentials() unless $self->{credentials_loaded};
    return { success => 0, error => 'No API URL' } unless $self->{api_url_base};

    my $ua          = $self->_make_ua(30);
    my $auth_header = $self->_auth_header()
        or return { success => 0, error => 'No credentials' };
    my $node_name = $self->_resolve_node($ua, $auth_header);

    my $url = $self->{api_url_base} . "/nodes/$node_name/qemu/$vmid/snapshot";
    my $req = HTTP::Request->new(POST => $url);
    $req->header(Authorization  => $auth_header);
    $req->header('Content-Type' => 'application/x-www-form-urlencoded');
    my $body = "snapname=" . uri_escape($snapname);
    $body .= "&description=" . uri_escape($description) if $description;
    $req->content($body);

    my $res = $ua->request($req);
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'create_snapshot',
        "create_snapshot vmid=$vmid name=$snapname => " . $res->status_line);

    if ($res->is_success) {
        my $data = eval { decode_json($res->decoded_content) };
        return { success => 1, task_id => ($data && $data->{data}) ? $data->{data} : '' };
    } else {
        return { success => 0, error => "Proxmox API error (${\$res->code}): " . $res->decoded_content };
    }
}

sub rollback_snapshot {
    my ($self, $vmid, $snapname) = @_;

    my $logging = Comserv::Util::Logging->instance;
    $self->_load_credentials() unless $self->{credentials_loaded};
    return { success => 0, error => 'No API URL' } unless $self->{api_url_base};

    my $ua          = $self->_make_ua(60);
    my $auth_header = $self->_auth_header()
        or return { success => 0, error => 'No credentials' };
    my $node_name = $self->_resolve_node($ua, $auth_header);

    my $url = $self->{api_url_base} . "/nodes/$node_name/qemu/$vmid/snapshot/$snapname/rollback";
    my $req = HTTP::Request->new(POST => $url);
    $req->header(Authorization  => $auth_header);
    $req->header('Content-Type' => 'application/x-www-form-urlencoded');
    $req->content('');

    my $res = $ua->request($req);
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'rollback_snapshot',
        "rollback_snapshot vmid=$vmid snap=$snapname => " . $res->status_line);

    if ($res->is_success) {
        my $data = eval { decode_json($res->decoded_content) };
        return { success => 1, task_id => ($data && $data->{data}) ? $data->{data} : '' };
    } else {
        return { success => 0, error => "Proxmox API error (${\$res->code}): " . $res->decoded_content };
    }
}

sub list_backups {
    my ($self, $vmid) = @_;

    $self->_load_credentials() unless $self->{credentials_loaded};
    return [] unless $self->{api_url_base};

    my $ua          = $self->_make_ua(15);
    my $auth_header = $self->_auth_header() or return [];
    my $node_name   = $self->_resolve_node($ua, $auth_header);

    my $req = HTTP::Request->new(GET =>
        $self->{api_url_base} . "/nodes/$node_name/storage");
    $req->header(Authorization => $auth_header);
    my $res = $ua->request($req);
    return [] unless $res->is_success;
    my $sdata = eval { decode_json($res->decoded_content) };
    return [] unless $sdata && $sdata->{data};

    my @backups;
    for my $storage (@{ $sdata->{data} }) {
        next unless ($storage->{content} || '') =~ /\bbackup\b/;
        my $sid = $storage->{storage};
        my $breq = HTTP::Request->new(GET =>
            $self->{api_url_base} . "/nodes/$node_name/storage/$sid/content?content=backup");
        $breq->header(Authorization => $auth_header);
        my $bres = $ua->request($breq);
        next unless $bres->is_success;
        my $bdata = eval { decode_json($bres->decoded_content) };
        next unless $bdata && $bdata->{data};
        for my $item (@{ $bdata->{data} }) {
            next unless defined $vmid ? ($item->{volid} =~ /vzdump-qemu-$vmid-/) : 1;
            push @backups, { %$item, storage => $sid };
        }
    }
    return \@backups;
}

# ── Performance history (RRD) ────────────────────────────────────────────────
# The graphs on the Proxmox web UI's node/VM summary come from the RRD history
# endpoints:
#   /nodes/{node}/rrddata?timeframe=hour|day|week|month|year&cf=AVERAGE
#   /nodes/{node}/qemu/{vmid}/rrddata?timeframe=...&cf=AVERAGE
# Each row is one time step. Useful keys:
#   VM  : cpu (fraction 0..1), mem, maxmem, netin/netout (B/s),
#         diskread/diskwrite (B/s), time (epoch)
#   Node: cpu (fraction 0..1), memused, memtotal, loadavg, iowait, netin/netout,
#         time; "temperature" only when the platform reports thermal sensors
#         (PVE 9+ / hardware dependent). PVE 8.x has no per-VM temperature at all.
#
# These methods return raw row arrays; the controller serialises them for the
# browser and the template does the maths/plotting.

sub _valid_timeframe {
    my ($tf) = @_;
    return 'hour' unless defined $tf && length $tf;
    return $tf =~ /\A(?:hour|day|week|month|year)\z/ ? $tf : 'hour';
}

sub _fetch_rrd {
    my ($self, $url) = @_;

    $self->_load_credentials() unless $self->{credentials_loaded};
    return [] unless $self->{api_url_base};

    my $logging     = Comserv::Util::Logging->instance;
    my $ua          = $self->_make_ua(20);
    my $auth_header = $self->_auth_header() or return [];

    my $req = HTTP::Request->new(GET => $url);
    $req->header(Authorization => $auth_header);
    my $res = $ua->request($req);

    unless ($res->is_success) {
        $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_fetch_rrd',
            'RRD request failed (' . $res->code . ') for ' . $url . ': '
            . substr($res->decoded_content // '', 0, 200));
        return [];
    }

    my $data = eval { decode_json($res->decoded_content) };
    if ($@) {
        $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_fetch_rrd',
            'RRD JSON parse error for ' . $url . ': ' . $@);
        return [];
    }

    return ($data && $data->{data} && ref $data->{data} eq 'ARRAY')
        ? $data->{data}
        : [];
}

# Find the node a VM actually lives on. In a cluster the configured default
# node is not necessarily the VM's host, and RRD endpoints are node-scoped.
sub _resolve_vm_node {
    my ($self, $ua, $auth_header, $vmid) = @_;

    my $req = HTTP::Request->new(GET => $self->{api_url_base} . '/cluster/resources?type=vm');
    $req->header(Authorization => $auth_header);
    my $res = $ua->request($req);

    if ($res->is_success) {
        my $d = eval { decode_json($res->decoded_content) };
        if ($d && $d->{data} && ref $d->{data} eq 'ARRAY') {
            for my $vm (@{ $d->{data} }) {
                return $vm->{node}
                    if defined $vm->{vmid} && $vm->{vmid} == $vmid && $vm->{node};
            }
        }
    }

    return $self->_resolve_node($ua, $auth_header);
}

sub get_vm_rrd_data {
    my ($self, $vmid, $timeframe) = @_;

    my $tf = _valid_timeframe($timeframe);
    $self->_load_credentials() unless $self->{credentials_loaded};
    return [] unless $self->{api_url_base} && defined $vmid;

    my $ua          = $self->_make_ua(20);
    my $auth_header = $self->_auth_header() or return [];
    my $node        = $self->_resolve_vm_node($ua, $auth_header, $vmid);

    return $self->_fetch_rrd(
        $self->{api_url_base}
        . "/nodes/$node/qemu/$vmid/rrddata?timeframe=$tf&cf=AVERAGE"
    );
}

sub get_node_rrd_data {
    my ($self, $timeframe, $node) = @_;

    my $tf = _valid_timeframe($timeframe);
    $self->_load_credentials() unless $self->{credentials_loaded};
    return [] unless $self->{api_url_base};

    my $ua          = $self->_make_ua(20);
    my $auth_header = $self->_auth_header() or return [];
    $node ||= $self->_resolve_node($ua, $auth_header);

    return $self->_fetch_rrd(
        $self->{api_url_base} . "/nodes/$node/rrddata?timeframe=$tf&cf=AVERAGE"
    );
}

# One call for the VM detail page: VM history + host history + current status.
sub get_vm_graph_data {
    my ($self, $vmid, $timeframe) = @_;

    my $tf = _valid_timeframe($timeframe);

    $self->_load_credentials() unless $self->{credentials_loaded};
    my $ua          = $self->_make_ua(20);
    my $auth_header = $self->_auth_header();
    my $node        = $auth_header
        ? $self->_resolve_vm_node($ua, $auth_header, $vmid)
        : ($self->{node} || '');

    my $vm_rows   = $self->get_vm_rrd_data($vmid, $tf);
    my $node_rows = $self->get_node_rrd_data($tf, $node);
    my $current   = $self->get_vm_status($vmid);

    # Host temperature is only present when the platform exposes thermal
    # sensors; tell the UI so it can hide the tile instead of plotting zeros.
    my $has_temp = 0;
    for my $row (@$node_rows) {
        if (defined $row->{temperature}) { $has_temp = 1; last; }
    }

    return {
        vmid            => 0 + $vmid,
        node            => $node,
        timeframe       => $tf,
        vm              => $vm_rows,
        node_history    => $node_rows,
        current         => $current || {},
        has_temperature => $has_temp ? 1 : 0,
    };
}

# Compact RRD for the fleet page: one node plus each qemu guest.
# Percent and MB/s only. No credentials.
sub _downsample_rrd {
    my ($rows, $max) = @_;
    $max ||= 48;
    return [] unless $rows && ref $rows eq 'ARRAY';
    my @clean = grep { ref $_ eq 'HASH' && defined $_->{time} } @$rows;
    return \@clean if @clean <= $max;
    my @out;
    my $step = @clean / $max;
    for (my $i = 0; $i < $max; $i++) {
        push @out, $clean[int($i * $step)];
    }
    return \@out;
}

sub _round1 {
    my ($n) = @_;
    return 0 unless defined $n && $n =~ /\A-?\d/;
    return 0 + sprintf('%.1f', $n);
}

sub _series_from {
    my ($rows, $code) = @_;
    my @out;
    for my $row (@$rows) {
        my $n = eval { $code->($row) };
        push @out, _round1($@ ? 0 : $n);
    }
    return \@out;
}

sub _metric_meta {
    my ($key) = @_;
    my %meta = (
        cpu         => ['CPU', '%', sub { 100 * $_[0] }, 0],
        iowait      => ['IO wait', '%', sub { 100 * $_[0] }, 0],
        loadavg     => ['Load', '', undef, 0],
        maxcpu      => ['CPU count', '', undef, 1],
        memused     => ['Memory used', 'GB', sub { $_[0] / 1073741824 }, 0],
        memtotal    => ['Memory total', 'GB', sub { $_[0] / 1073741824 }, 1],
        netin       => ['Network in', 'MB/s', sub { $_[0] / 1048576 }, 0],
        netout      => ['Network out', 'MB/s', sub { $_[0] / 1048576 }, 0],
        rootused    => ['Root disk used', 'GB', sub { $_[0] / 1073741824 }, 0],
        roottotal   => ['Root disk total', 'GB', sub { $_[0] / 1073741824 }, 1],
        swapused    => ['Swap used', 'GB', sub { $_[0] / 1073741824 }, 0],
        swaptotal   => ['Swap total', 'GB', sub { $_[0] / 1073741824 }, 1],
        temperature => ['CPU temperature', '°C', undef, 0],
    );
    return @{ $meta{$key} } if $meta{$key};
    my $label = $key;
    $label =~ s/_/ /g;
    return ($label, '', undef, 0);
}

sub _node_metrics {
    my ($rows) = @_;
    return [] unless $rows && ref $rows eq 'ARRAY';

    my %seen;
    for my $row (@$rows) {
        next unless ref $row eq 'HASH';
        for my $key (keys %$row) {
            next if $key eq 'time';
            $seen{$key} = 1 if defined $row->{$key} && $row->{$key} =~ /\A-?\d/;
        }
    }

    my @preferred = qw(
        cpu iowait loadavg maxcpu temperature
        memused memtotal swapused swaptotal rootused roottotal netin netout
    );
    my %preferred = map { $_ => 1 } @preferred;
    my @keys = grep { $seen{$_} } @preferred;
    push @keys, sort grep { !$preferred{$_} } keys %seen;

    my @metrics;
    for my $key (@keys) {
        my ($label, $unit, $scale, $capacity) = _metric_meta($key);
        push @metrics, {
            key      => $key,
            label    => $label,
            unit     => $unit,
            capacity => $capacity ? 1 : 0,
            values   => _series_from($rows, sub {
                my $n = $_[0]->{$key};
                return 0 unless defined $n && $n =~ /\A-?\d/;
                return $scale ? $scale->($n) : $n;
            }),
        };
    }
    return \@metrics;
}

sub _node_status_snapshot {
    my ($self, $ua, $auth, $node) = @_;
    return {} unless $ua && $auth && $node && $self->{api_url_base};

    my $req = HTTP::Request->new(GET => $self->{api_url_base} . "/nodes/$node/status");
    $req->header(Authorization => $auth);
    my $res = $ua->request($req);
    return {} unless $res && $res->is_success;

    my $data = eval { decode_json($res->decoded_content) };
    my $st = ($data && ref $data->{data} eq 'HASH') ? $data->{data} : {};
    my $cpus = ($st->{cpuinfo} && $st->{cpuinfo}{cpus}) ? 0 + $st->{cpuinfo}{cpus} : 0;
    my $load = 0;
    if ($st->{loadavg} && ref $st->{loadavg} eq 'ARRAY' && defined $st->{loadavg}[0]) {
        $load = 0 + $st->{loadavg}[0];
    }
    return {
        uptime    => 0 + ($st->{uptime} || 0),
        cpu_pct   => _round1(100 * ($st->{cpu} || 0)),
        maxcpu    => $cpus,
        memused   => _round1(($st->{memory}{used} || 0) / 1073741824),
        memtotal  => _round1(($st->{memory}{total} || 0) / 1073741824),
        rootused  => _round1(($st->{rootfs}{used} || 0) / 1073741824),
        roottotal => _round1(($st->{rootfs}{total} || 0) / 1073741824),
        swapused  => _round1(($st->{swap}{used} || 0) / 1073741824),
        swaptotal => _round1(($st->{swap}{total} || 0) / 1073741824),
        iowait    => _round1(100 * ($st->{wait} || 0)),
        load      => _round1($load),
    };
}

sub get_activity_snapshot {
    my ($self, $timeframe, $history, $guests) = @_;
    $history = 1 unless defined $history;
    $guests = 1 unless defined $guests;

    my $tf = _valid_timeframe($timeframe);
    my $logging = Comserv::Util::Logging->instance;
    $self->_load_credentials() unless $self->{credentials_loaded};

    return { ok => 0, error => 'No API URL', vms => [] } unless $self->{api_url_base};
    my $auth = $self->_auth_header();
    return { ok => 0, error => 'No API token stored', vms => [] } unless $auth;

    unless ($history) {
        my $ua   = $self->_make_ua(12);
        my $node = $self->_resolve_node($ua, $auth);
        my $status = $self->_node_status_snapshot($ua, $auth, $node);
        return { ok => 0, error => 'Could not read node status', vms => [] }
            unless $status && $status->{maxcpu};
        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'get_activity_snapshot',
            "node snapshot node=$node cpus=$status->{maxcpu}");
        return {
            ok => 1, node => $node, timeframe => 'snapshot',
            status => $status, metrics => [], vms => [],
        };
    }

    my $ua   = $self->_make_ua(12);
    my $node = $self->_resolve_node($ua, $auth);
    my $node_rows = _downsample_rrd($self->get_node_rrd_data($tf, $node), 48);

    my @guests;
    if ($guests) {
    my $req = HTTP::Request->new(
        GET => $self->{api_url_base} . '/cluster/resources?type=vm'
    );
    $req->header(Authorization => $auth);
    my $res = $ua->request($req);
    if ($res->is_success) {
        my $data = eval { decode_json($res->decoded_content) };
        if ($data && $data->{data} && ref $data->{data} eq 'ARRAY') {
            @guests = grep { ($_->{type} || '') eq 'qemu' && defined $_->{vmid} } @{ $data->{data} };
        }
    }
    }

    my @vms;
    for my $vm (@guests) {
        my $vmid  = $vm->{vmid};
        my $vnode = $vm->{node} || $node;
        my $rows  = _downsample_rrd(
            $self->_fetch_rrd(
                $self->{api_url_base}
                . "/nodes/$vnode/qemu/$vmid/rrddata?timeframe=$tf&cf=AVERAGE"
            ),
            48
        );
        push @vms, {
            vmid   => 0 + $vmid,
            name   => $vm->{name} || '',
            status => $vm->{status} || '',
            node   => $vnode,
            time   => _series_from($rows, sub { $_[0]->{time} }),
            cpu    => _series_from($rows, sub { 100 * ($_[0]->{cpu} || 0) }),
            mem    => _series_from($rows, sub {
                my $max = $_[0]->{maxmem} || 0;
                return $max ? 100 * ($_[0]->{mem} || 0) / $max : 0;
            }),
            net    => _series_from($rows, sub {
                (($_[0]->{netin} || 0) + ($_[0]->{netout} || 0)) / 1048576;
            }),
            disk   => _series_from($rows, sub {
                (($_[0]->{diskread} || 0) + ($_[0]->{diskwrite} || 0)) / 1048576;
            }),
        };
    }

    my $metrics = _node_metrics($node_rows);
    my $has_temperature = (grep { $_->{key} eq 'temperature' } @$metrics) ? 1 : 0;
    my $status = $self->_node_status_snapshot($ua, $auth, $node);

    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'get_activity_snapshot',
        "activity snapshot node=$node guests=" . scalar(@vms) . " timeframe=$tf");

    return {
        ok        => 1,
        node      => $node,
        timeframe => $tf,
        time      => _series_from($node_rows, sub { $_[0]->{time} }),
        cpu       => _series_from($node_rows, sub { 100 * ($_[0]->{cpu} || 0) }),
        mem       => _series_from($node_rows, sub {
            my $total = $_[0]->{memtotal} || 0;
            return $total ? 100 * ($_[0]->{memused} || 0) / $total : 0;
        }),
        load      => _series_from($node_rows, sub { $_[0]->{loadavg} || 0 }),
        net       => _series_from($node_rows, sub {
            (($_[0]->{netin} || 0) + ($_[0]->{netout} || 0)) / 1048576;
        }),
        metrics   => $metrics,
        has_temperature => $has_temperature,
        status    => $status,
        vms       => \@vms,
    };
}

sub restore_backup {
    my ($self, $vmid, $volid, $storage) = @_;

    my $logging = Comserv::Util::Logging->instance;
    $self->_load_credentials() unless $self->{credentials_loaded};
    return { success => 0, error => 'No API URL' } unless $self->{api_url_base};

    my $ua          = $self->_make_ua(120);
    my $auth_header = $self->_auth_header()
        or return { success => 0, error => 'No credentials' };
    my $node_name = $self->_resolve_node($ua, $auth_header);

    my $url = $self->{api_url_base} . "/nodes/$node_name/qemu";
    my $req = HTTP::Request->new(POST => $url);
    $req->header(Authorization  => $auth_header);
    $req->header('Content-Type' => 'application/x-www-form-urlencoded');

    my $body = "vmid=" . uri_escape($vmid)
             . "&archive=" . uri_escape($volid)
             . "&force=1";
    $body .= "&storage=" . uri_escape($storage) if $storage;
    $req->content($body);

    my $res = $ua->request($req);
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'restore_backup',
        "restore_backup vmid=$vmid volid=$volid => " . $res->status_line);

    if ($res->is_success) {
        my $data = eval { decode_json($res->decoded_content) };
        return { success => 1, task_id => ($data && $data->{data}) ? $data->{data} : '' };
    } else {
        return { success => 0, error => "Proxmox API error (${\$res->code}): " . $res->decoded_content };
    }
}

1;