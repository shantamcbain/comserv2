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
use namespace::autoclean;
use LWP::UserAgent;
use HTTP::Request;
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
    
    # Try to determine the correct node name
    my $node_name = 'proxmox'; # Default to 'proxmox'
    
    # If credentials specify a node, log it
    if ($credentials->{node}) {
        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_load_credentials',
            "Credentials specify node name: '" . $credentials->{node} . "'");
    }
    
    # Set the node name
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

    # Try a direct test with the 'proxmox' node
    my $direct_proxmox_vms = $self->_try_get_node_vms($ua, 'proxmox');
    if ($direct_proxmox_vms && @$direct_proxmox_vms > 0) {
        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
            "Successfully retrieved " . scalar(@$direct_proxmox_vms) . " VMs directly from node 'proxmox'");
        return $direct_proxmox_vms;
    }
    
    # Also try with 'pve' node which is common in Proxmox installations
    my $direct_pve_vms = $self->_try_get_node_vms($ua, 'pve');
    if ($direct_pve_vms && @$direct_pve_vms > 0) {
        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_real_vms_new',
            "Successfully retrieved " . scalar(@$direct_pve_vms) . " VMs directly from node 'pve'");
        return $direct_pve_vms;
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

    # For now, return a static list of templates
    # In a real implementation, this would query the Proxmox API for available templates
    my @templates = (
        {
            id => 'ubuntu-2204',
            name => 'Ubuntu 22.04 LTS',
            description => 'Ubuntu 22.04 LTS (Jammy Jellyfish)',
            url => 'https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img',
        },
        {
            id => 'debian-11',
            name => 'Debian 11',
            description => 'Debian 11 (Bullseye)',
            url => 'https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2',
        },
        {
            id => 'centos-8',
            name => 'CentOS 8',
            description => 'CentOS 8 Stream',
            url => 'https://cloud.centos.org/centos/8-stream/x86_64/images/CentOS-Stream-GenericCloud-8-latest.x86_64.qcow2',
        },
    );

    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'get_available_templates',
        "Found " . scalar(@templates) . " VM templates");

    return \@templates;
}

# Create a new VM
sub create_vm {
    my ($self, $params) = @_;

    my $logging = Comserv::Util::Logging->instance;
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'create_vm',
        "Creating new VM with hostname: " . $params->{hostname});

    # Make sure credentials are loaded
    $self->_load_credentials() unless $self->{credentials_loaded};

    # Check if we have valid credentials
    if (!$self->{api_url_base}) {
        $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'create_vm',
            "No valid API URL found for server: " . $self->{server_id});
        return { success => 0, error => "No valid API URL found" };
    }

    # In a real implementation, this would create a VM using the Proxmox API
    # For now, return a mock success response
    my $vmid = int(rand(1000)) + 100;

    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'create_vm',
        "VM creation simulated with VMID: $vmid");

    return {
        success => 1,
        vmid => $vmid,
        task_id => "UPID:pve:00" . $vmid . ":1234567890:1234567890:create:$vmid:root\@pam:",
    };
}

1;