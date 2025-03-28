package Comserv::Model::Proxmox;
use strict;
use warnings;
use base 'Catalyst::Model';
use LWP::UserAgent;
use HTTP::Request;
use JSON;
use Data::Dumper;
use File::Basename;
use Try::Tiny;

=head1 NAME

Comserv::Model::Proxmox - Proxmox VE API Model

=head1 DESCRIPTION

Model for interacting with Proxmox VE API to manage virtual machines.

=head1 METHODS

=cut

sub new {
    my ($class, $c, $args) = @_;

    # Make sure args is a hash reference
    $args = {} unless ref($args) eq 'HASH';

    my $self = {
        # Store the Catalyst context if it's valid
        c => (ref($c) && $c->can('stash')) ? $c : undef,
        proxmox_host => $args->{proxmox_host} || '172.30.236.89',
        api_url_base => $args->{api_url_base} || 'https://172.30.236.89:8006/api2/json',
        node => $args->{node} || 'pve',  # Default node name, can be configured
        ua => LWP::UserAgent->new(
            ssl_opts => { verify_hostname => 0, SSL_verify_mode => 0 },
            timeout => 30,
        ),
        token => undef,
        token_expires => 0,
        username => undef,
        password => undef,
        realm => 'pam',  # Default realm
        image_url_base => $args->{image_url_base} || 'http://172.30.167.222/kvm-images',  # URL for VM templates
        debug_log => [],  # Internal debug log
    };

    # Initialize debug messages array if we have a valid context
    if (ref($c) && $c->can('stash') && !$c->stash->{debug_msg}) {
        $c->stash->{debug_msg} = [];
    }

    bless $self, $class;
    return $self;
}

=head2 authenticate

Authenticate with the Proxmox API using username/password

=cut

sub authenticate {
    my ($self, $username, $password, $realm) = @_;

    $self->{username} = $username if $username;
    $self->{password} = $password if $password;
    $self->{realm} = $realm if $realm;

    my $url = "$self->{api_url_base}/access/ticket";

    my $req = HTTP::Request->new(POST => $url);
    $req->content_type('application/x-www-form-urlencoded');
    $req->content("username=$self->{username}\@$self->{realm}&password=$self->{password}");

    my $res = $self->{ua}->request($req);

    if ($res->is_success) {
        my $data = decode_json($res->content);
        if ($data->{data}) {
            $self->{token} = $data->{data}->{ticket};
            $self->{csrf_token} = $data->{data}->{CSRFPreventionToken};
            $self->{token_expires} = time() + 7200;  # 2 hours expiration
            return 1;
        }
    }

    return 0;
}

=head2 authenticate_with_token

Authenticate with the Proxmox API using API token

=cut

# Helper method to check if token is valid and refresh if needed
sub _check_token {
    my ($self) = @_;

    # If we have a token and it's not expired, we're good
    return 1 if $self->{api_token} && $self->{token_expires} > time();

    # If we have token_user and token_value, try to authenticate
    if ($self->{token_user} && $self->{token_value}) {
        return $self->authenticate_with_token($self->{token_user}, $self->{token_value});
    }

    # If we have username and password, try to authenticate
    if ($self->{username} && $self->{password}) {
        return $self->authenticate($self->{username}, $self->{password}, $self->{realm});
    }

    return 0;
}

# Helper method to safely add debug messages
sub _add_debug_msg {
    my ($self, $msg) = @_;

    # Only try to add to stash if we have a valid Catalyst context
    if (ref($self->{c}) && $self->{c}->can('stash')) {
        # Initialize debug messages array if needed
        $self->{c}->stash->{debug_msg} = [] unless $self->{c}->stash->{debug_msg};
        push @{$self->{c}->stash->{debug_msg}}, $msg;
    }

    # Always store in our internal debug log for reference
    $self->{debug_log} = [] unless $self->{debug_log};
    push @{$self->{debug_log}}, $msg;
}

sub authenticate_with_token {
    my ($self, $token_user, $token_value) = @_;

    # Initialize debug messages and add first message
    $self->_add_debug_msg("Proxmox::authenticate_with_token - Starting authentication with token");

    # Store token information
    $self->{token_user} = $token_user if $token_user;
    $self->{token_value} = $token_value if $token_value;

    $self->_add_debug_msg("Token user: $token_user");

    # Format: PVEAPIToken=USER@REALM!TOKENID=UUID
    # Note: Do NOT usaround the token value - the API doesn't expect them
    my $auth_header = "PVEAPIToken=$token_user=$token_value";- the API doesn't expect them

    # Log the exact header we're using
    $self->_add_debug_msg("Using auth header: $auth_header");

    $self->_add_debug_msg('Auth header format: PVEAPIToken=USER@REALM!TOKENID=UUID');

    # Store the debug info with detailed token information
    $self->{debug_info} = {
        token_format => 'PVEAPIToken=USER@REALM!TOKENID=UUID',
        token_user => $token_user,
        token_user_format_valid => ($token_user =~ /^[^@]+@[^!]+![^=]+=/) ? 1 : 0,
        auth_header => $auth_header,
        api_url => "$self->{api_url_base}/nodes",
        ssl_verify => $self->{ua}->{ssl_opts}->{verify_hostname} ? "Yes" : "No (SSL verification disabled)",
        timeout => $self->{ua}->{timeout} . " seconds",
        debug_log => $self->{debug_log},  # Include our internal debug log
    };

    # Test the token by making a simple API call
    my $url = "$self->{api_url_base}/nodes";
    $self->_add_debug_msg("Making API request to: $url");

    my $req = HTTP::Request->new(GET => $url);
    $req->header('Authorization' => $auth_header);
    $self->_add_debug_msg("Request headers set: Authorization: $auth_header");

    # Log the full request for debugging
    $self->_add_debug_msg("Full request: " . $req->as_string);

    my $res = $self->{ua}->request($req);
    $self->_add_debug_msg("Received response: " . $res->status_line);

    # Log the full response for debugging
    $self->_add_debug_msg("Response status: " . $res->status_line);
    $self->_add_debug_msg("Response content: " . substr($res->content, 0, 500) . (length($res->content) > 500 ? "..." : ""));

    # Store response info for debugging
    $self->{debug_info}->{response_code} = $res->code;
    $self->{debug_info}->{response_status} = $res->status_line;

    # Store headers without using header_field_names which might not be available
    my %headers;
    $headers{'Content-Type'} = $res->header('Content-Type') if $res->header('Content-Type');
    $headers{'Content-Length'} = $res->header('Content-Length') if $res->header('Content-Length');
    $headers{'Server'} = $res->header('Server') if $res->header('Server');
    $self->{debug_info}->{response_headers} = \%headers;

    # Store the response content
    $self->{debug_info}->{response_content} = substr($res->content, 0, 1000) . (length($res->content) > 1000 ? "..." : "");

    $self->_add_debug_msg("Response code: " . $res->code . " (" . $res->status_line . ")");

    # Process the response
    if ($res->is_success) {
        my $content = $res->content;
        $self->{debug_info}->{response_content_length} = length($content);

        # Try to parse the JSON response
        my $data = eval { decode_json($content) };

        if ($data && !$@) {
            # Store the token for future requests
            $self->{api_token} = $auth_header;
            $self->{token_expires} = time() + 86400;  # 24 hours expiration

            # Store successful response data
            $self->{debug_info}->{auth_success} = 1;
            $self->{debug_info}->{response_data} = $data;

            $self->_add_debug_msg("Authentication successful! Token stored for future requests.");
            $self->_add_debug_msg("Token will expire in 24 hours.");

            return 1;
        }
        else {
            # JSON parsing failed
            $self->{debug_info}->{auth_success} = 0;
            $self->{debug_info}->{json_error} = $@ || "Invalid JSON response";
            $self->{debug_info}->{response_content} = substr($content, 0, 500) . (length($content) > 500 ? "..." : "");

            $self->_add_debug_msg("ERROR: JSON parsing failed: " . ($@ || "Invalid JSON response"));

            # Try to determine if it's an HTML response (common error)
            if ($content =~ /<html/i) {
                $self->{debug_info}->{error_type} = "HTML response received instead of JSON";
                $self->{debug_info}->{possible_cause} = "Server returned an HTML error page instead of JSON. This often happens with SSL certificate issues or incorrect API URL.";

                $self->_add_debug_msg("ERROR: HTML response received instead of JSON");
                $self->_add_debug_msg("This often happens with SSL certificate issues or incorrect API URL");
            }
        }
    }
    else {
        # HTTP request failed
        $self->{debug_info}->{auth_success} = 0;
        $self->{debug_info}->{error} = "HTTP request failed: " . $res->status_line;

        $self->_add_debug_msg("ERROR: HTTP request failed: " . $res->status_line);

        my $content = $res->content;
        $self->{debug_info}->{response_content} = substr($content, 0, 500) . (length($content) > 500 ? "..." : "");

        # Try to determine specific error types
        if ($res->code == 401) {
            $self->{debug_info}->{error_type} = "Authentication failed (401 Unauthorized)";
            $self->{debug_info}->{possible_cause} = "Invalid API token format or value. Ensure the token is in the correct format and has appropriate permissions.";

            $self->_add_debug_msg("ERROR: Authentication failed (401 Unauthorized)");
            $self->_add_debug_msg("Possible cause: Invalid API token format or value. Ensure the token is in the correct format and has appropriate permissions.");
        }
        elsif ($res->code == 403) {
            $self->{debug_info}->{error_type} = "Permission denied (403 Forbidden)";
            $self->{debug_info}->{possible_cause} = "The API token does not have sufficient permissions to access the requested resource.";

            $self->_add_debug_msg("ERROR: Permission denied (403 Forbidden)");
            $self->_add_debug_msg("Possible cause: The API token does not have sufficient permissions to access the requested resource.");
        }
        elsif ($res->code == 404) {
            $self->{debug_info}->{error_type} = "Resource not found (404 Not Found)";
            $self->{debug_info}->{possible_cause} = "The API URL or resource path is incorrect. Check the API URL and node name.";

            $self->_add_debug_msg("ERROR: Resource not found (404 Not Found)");
            $self->_add_debug_msg("Possible cause: The API URL or resource path is incorrect. Check the API URL and node name.");
        }
        elsif ($res->code >= 500) {
            $self->{debug_info}->{error_type} = "Server error (" . $res->code . ")";
            $self->{debug_info}->{possible_cause} = "The Proxmox server encountered an internal error. Check the server logs for more information.";

            $self->_add_debug_msg("ERROR: Server error (" . $res->code . ")");
            $self->_add_debug_msg("Possible cause: The Proxmox server encountered an internal error. Check the server logs for more information.");
        }
    }

    return 0;
}

=head2 get_available_templates

Get list of available VM templates

=cut

sub get_available_templates {
    my ($self) = @_;

    # Define the templates we want to offer
    # Use the image_url_base from the configuration
    my $base_url = $self->{image_url_base};

    my @templates = (
        {
            id => 'ubuntu-22.04',
            name => 'Ubuntu 22.04 Server',
            file => 'ubuntu-22.04-server-cloudimg-amd64.img',
            url => "$base_url/ubuntu-22.04-server-cloudimg-amd64.img",
            type => 'qcow2',
            os_type => 'linux',
        },
        {
            id => 'turnkey-webmin',
            name => 'TurnKey Webmin 17.1',
            file => 'turnkey-webmin-17.1.qcow2',
            url => "$base_url/turnkey-webmin-17.1.qcow2",
            type => 'qcow2',
            os_type => 'linux',
        },
        {
            id => 'almalinux-9',
            name => 'AlmaLinux 9',
            file => 'almalinux-9.qcow2',
            url => "$base_url/almalinux-9.qcow2",
            type => 'qcow2',
            os_type => 'linux',
        }
    );

    return \@templates;
}

=head2 get_next_vmid

Get the next available VM ID

=cut

sub get_next_vmid {
    my ($self) = @_;
    
    $self->_check_token();
    
    my $url = "$self->{api_url_base}/cluster/nextid";
    my $req = HTTP::Request->new(GET => $url);

    # Use API token if available, otherwise use cookie authentication
    if ($self->{api_token}) {
        $req->header('Authorization' => $self->{api_token});
    } else {
        $req->header('Cookie' => "PVEAuthCookie=$self->{token}");
    }
    
    my $res = $self->{ua}->request($req);
    
    if ($res->is_success) {
        my $data = decode_json($res->content);
        if ($data->{data}) {
            return $data->{data};
        }
    }
    
    # If API call fails, generate a random ID between 100 and 999
    return int(rand(900)) + 100;
}

=head2 create_vm

Create a new virtual machine

=cut

sub create_vm {
    my ($self, $params) = @_;
    
    $self->_check_token();
    
    # Get next available VM ID
    my $vmid = $self->get_next_vmid();
    
    # Prepare VM creation parameters
    my $vm_params = {
        vmid => $vmid,
        name => $params->{hostname},
        cores => $params->{cpu} || 1,
        memory => $params->{memory} || 2048,
        ostype => 'l26', # Linux 2.6/3.x/4.x Kernel
        net0 => 'virtio,bridge=vmbr0',
        cdrom => $params->{template_url}, # Use the URL directly
        scsihw => 'virtio-scsi-pci',
        scsi0 => "local-lvm:$params->{disk_size},format=raw",
        description => "Created via Comserv Proxmox API on " . scalar(localtime),
    };
    
    # Build query string
    my $query = join('&', map { "$_=" . $vm_params->{$_} } keys %$vm_params);
    
    # Create VM
    my $url = "$self->{api_url_base}/nodes/$self->{node}/qemu";
    my $req = HTTP::Request->new(POST => $url);

    # Use API token if available, otherwise use cookie authentication
    if ($self->{api_token}) {
        $req->header('Authorization' => $self->{api_token});
    } else {
        $req->header('Cookie' => "PVEAuthCookie=$self->{token}");
        $req->header('CSRFPreventionToken' => $self->{csrf_token});
    }
    $req->content_type('application/x-www-form-urlencoded');
    $req->content($query);
    
    my $res = $self->{ua}->request($req);
    
    if ($res->is_success) {
        my $data = decode_json($res->content);
        return {
            success => 1,
            vmid => $vmid,
            task_id => $data->{data},
        };
    } else {
        return {
            success => 0,
            error => $res->status_line,
            content => $res->content,
        };
    }
}

=head2 get_vms

Get list of all VMs

=cut

sub get_vms {
    my ($self) = @_;

    $self->_check_token();

    my $url = "$self->{api_url_base}/nodes/$self->{node}/qemu";
    my $req = HTTP::Request->new(GET => $url);

    # Use API token if available, otherwise use cookie authentication
    if ($self->{api_token}) {
        $req->header('Authorization' => $self->{api_token});
    } else {
        $req->header('Cookie' => "PVEAuthCookie=$self->{token}");
    }

    my $res = $self->{ua}->request($req);

    if ($res->is_success) {
        my $data = decode_json($res->content);
        return $data->{data};
    }

    return [];
}

=head2 get_vm_status

Get the status of a VM

=cut

sub get_vm_status {
    my ($self, $vmid) = @_;

    $self->_check_token();

    my $url = "$self->{api_url_base}/nodes/$self->{node}/qemu/$vmid/status/current";
    my $req = HTTP::Request->new(GET => $url);

    # Use API token if available, otherwise use cookie authentication
    if ($self->{api_token}) {
        $req->header('Authorization' => $self->{api_token});
    } else {
        $req->header('Cookie' => "PVEAuthCookie=$self->{token}");
    }

    my $res = $self->{ua}->request($req);

    if ($res->is_success) {
        my $data = decode_json($res->content);
        return $data->{data};
    }

    return undef;
}

=head2 start_vm

Start a VM

=cut

sub start_vm {
    my ($self, $vmid) = @_;
    
    $self->_check_token();
    
    my $url = "$self->{api_url_base}/nodes/$self->{node}/qemu/$vmid/status/start";
    my $req = HTTP::Request->new(POST => $url);

    # Use API token if available, otherwise use cookie authentication
    if ($self->{api_token}) {
        $req->header('Authorization' => $self->{api_token});
    } else {
        $req->header('Cookie' => "PVEAuthCookie=$self->{token}");
        $req->header('CSRFPreventionToken' => $self->{csrf_token});
    }
    
    my $res = $self->{ua}->request($req);
    
    if ($res->is_success) {
        my $data = decode_json($res->content);
        return $data->{data};
    }
    
    return undef;
}

=head2 resize_disk

Resize a VM's disk

=cut

sub resize_disk {
    my ($self, $vmid, $disk, $size) = @_;
    
    $self->_check_token();
    
    my $url = "$self->{api_url_base}/nodes/$self->{node}/qemu/$vmid/resize";
    my $req = HTTP::Request->new(PUT => $url);

    # Use API token if available, otherwise use cookie authentication
    if ($self->{api_token}) {
        $req->header('Authorization' => $self->{api_token});
    } else {
        $req->header('Cookie' => "PVEAuthCookie=$self->{token}");
        $req->header('CSRFPreventionToken' => $self->{csrf_token});
    }
    $req->content_type('application/x-www-form-urlencoded');
    $req->content("disk=$disk&size=$size");
    
    my $res = $self->{ua}->request($req);
    
    if ($res->is_success) {
        my $data = decode_json($res->content);
        return $data->{data};
    }
    
    return undef;
}

=head2 _check_token

Internal method to check if token is valid and re-authenticate if needed

=cut

sub _check_token {
    my ($self) = @_;

    # Check if token is expired
    if (time() > $self->{token_expires}) {
        # If we have API token credentials, use those
        if ($self->{token_user} && $self->{token_value}) {
            return $self->authenticate_with_token($self->{token_user}, $self->{token_value});
        }
        # Fall back to username/password if available
        elsif ($self->{username} && $self->{password}) {
            return $self->authenticate();
        }
        # No valid credentials
        else {
            return 0;
        }
    }

    return 1;
}

=head1 AUTHOR

Comserv

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;