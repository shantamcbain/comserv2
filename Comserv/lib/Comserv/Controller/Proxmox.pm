package Comserv::Controller::Proxmox;
use Moose;
use namespace::autoclean;
use JSON;
use Data::Dumper;
use Try::Tiny;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

=head1 NAME

Comserv::Controller::Proxmox - Catalyst Controller for Proxmox VM Management

=head1 DESCRIPTION

Catalyst Controller for managing Proxmox virtual machines. This controller
provides a web interface for viewing and managing virtual machines hosted
on Proxmox VE servers.

See /docs/proxmox_api.md for detailed API documentation.

=head1 CONFIGURATION

The Proxmox controller requires proper configuration in the credentials file
to connect to Proxmox servers. The credentials file should contain:

- api_url_base: The base URL for the Proxmox API (e.g., https://proxmox.example.com:8006/api2/json)
- node: The default node name (e.g., proxmox)
- token_user: The API token user (e.g., user@realm!tokenid)
- token_value: The API token value

=head1 METHODS

=cut

=head2 index

The main Proxmox management page

=cut

sub index :Path :Args(0) {
    my ($self, $c) = @_;

    # Log that we're accessing the Proxmox controller without role check
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "Accessing Proxmox controller - role check disabled");
        
    # Get roles for debugging purposes only
    my $roles = $c->session->{roles} || [];
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
        "User roles (for debugging): " . join(", ", @$roles));
        
    # No role check - all API interactions are handled via API tokens

    # Use server_id from parameter or default
    my $server_id = $c->req->param('server_id') || $c->session->{proxmox_server_id} || 'ProxmoxDevelopment';

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "Starting Proxmox VM management for server: $server_id");

    # Configure the Proxmox model
    my $proxmox = $c->model('Proxmox');

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
        "Configured Proxmox model for server: $server_id");

    my $auth_success = 0;
    my $auth_error = '';

    # Try to connect to Proxmox server
    eval {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
            "Checking connection to Proxmox server: $server_id");

        # Configure the model with the server ID
        $proxmox->set_server_id($server_id);

        # Check connection status
        $auth_success = $proxmox->check_connection();

        # Get debug info from the Proxmox model
        my $debug_info = $proxmox->{debug_info} || {};

        if ($auth_success) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
                "Successfully connected to Proxmox server");

            # Store server_id in session for future requests
            $c->session->{proxmox_server_id} = $server_id;
        } else {
            $auth_error = 'Failed to connect to Proxmox server. Please contact system administrator.';
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index', $auth_error);

            # Add more detailed error information if available
            if ($debug_info && $debug_info->{response_code}) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index',
                    "API response: " . $debug_info->{response_code} . " - " .
                        ($debug_info->{response_status} || "Unknown status"));
            }
        }
    };
    if ($@) {
        $auth_error = "Error connecting to Proxmox server: $@";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index', $auth_error);
    }

    my $vms = [];
    # Only try to get VMs if authentication was successful
    eval {
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
            "Retrieving VM list from Proxmox server: $server_id");

        # Check if authentication was successful
        if (!$auth_success) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'index',
                "Authentication failed, but attempting to retrieve VMs anyway");
            
            # Try to authenticate again
            $auth_success = $proxmox->check_connection();
            
            if (!$auth_success) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index',
                    "Authentication failed again, cannot retrieve VMs");
                
                # Make sure debug_msg exists in the stash and is an array reference
                if (!defined $c->stash->{debug_msg}) {
                    $c->stash->{debug_msg} = [];
                } elsif (ref($c->stash->{debug_msg}) ne 'ARRAY') {
                    # If debug_msg is a string, convert it to an array with the string as the first element
                    my $original_msg = $c->stash->{debug_msg};
                    $c->stash->{debug_msg} = [$original_msg];
                }
                
                push @{$c->stash->{debug_msg}}, "Authentication failed, cannot retrieve VMs";
                return;
            }
        }

        # First try a direct test of the 'proxmox' node
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
            "Testing direct connection to 'proxmox' node");
        my $proxmox_vms = $proxmox->test_proxmox_node();

        if ($proxmox_vms && @$proxmox_vms > 0) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
                "Successfully retrieved " . scalar(@$proxmox_vms) . " VMs directly from 'proxmox' node");
            $vms = $proxmox_vms;
        } else {
            # If that fails, try the regular method
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
                "Calling get_vms with server_id: $server_id");
            $vms = $proxmox->get_vms($server_id);
        }

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
            "Retrieved " . scalar(@$vms) . " VMs from Proxmox server: $server_id");
    };
    if ($@) {
        my $error = "Error getting VM list: $@";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index', $error);
        $c->log->error($error);
    }

    # Test multiple Proxmox API endpoints
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "Testing multiple Proxmox API endpoints");

    # Get the credentials for API testing
    require Comserv::Util::ProxmoxCredentials;
    my $credentials = Comserv::Util::ProxmoxCredentials::get_credentials($server_id);

    # Create a user agent
    my $ua = LWP::UserAgent->new;
    $ua->ssl_opts(verify_hostname => 0, SSL_verify_mode => 0);
    $ua->timeout(30);

    # Create the API token header
    my $token = "PVEAPIToken=" . $credentials->{token_user} . "=" . $credentials->{token_value};

    # Make sure debug_msg exists in the stash and is an array reference
    if (!defined $c->stash->{debug_msg}) {
        $c->stash->{debug_msg} = [];
    } elsif (ref($c->stash->{debug_msg}) ne 'ARRAY') {
        # If debug_msg is a string, convert it to an array with the string as the first element
        my $original_msg = $c->stash->{debug_msg};
        $c->stash->{debug_msg} = [$original_msg];
    }

    # Add a section header for API tests
    push @{$c->stash->{debug_msg}}, "API Endpoint Tests";

    # Try to extract the hostname from the API URL
    my $hostname = $credentials->{host} || "unknown";
    if ($credentials->{api_url_base} =~ m{https?://([^:/]+)}) {
        $hostname = $1;
    }

    # Add the hostname to the debug messages
    push @{$c->stash->{debug_msg}}, "Proxmox Hostname: $hostname";

    # Define the endpoints to test
    my @endpoints = (
        # [All your endpoint definitions remain unchanged...]
    );

    # Try to add the hostname as a node to test
    if ($hostname ne "unknown" && $hostname ne "172.30.236.89") {
        push @endpoints, {
            name => "Node '$hostname'",
            url => $credentials->{api_url_base} . '/nodes/' . $hostname,
            description => "Get information about the '$hostname' node"
        };
        push @endpoints, {
            name => "Node '$hostname' VMs",
            url => $credentials->{api_url_base} . '/nodes/' . $hostname . '/qemu',
            description => "List all VMs on the '$hostname' node"
        };
    }

    # Test each endpoint
    foreach my $endpoint (@endpoints) {
        # [All your endpoint testing logic remains unchanged...]
    }

    # Get the list of available Proxmox servers from the model
    my $servers = $proxmox->get_servers();

    # Log the server list
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
        "Got server list from model: " . scalar(@$servers) . " servers");

    # Get the current server name
    my $current_server_name = "Unknown Server";

    # Debug log the server list and current server ID
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
        "Server ID: $server_id, Server count: " . scalar(@$servers));

    foreach my $server (@$servers) {
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
            "Available server: " . $server->{id} . " - " . $server->{name});

        if ($server->{id} eq $server_id) {
            $current_server_name = $server->{name};
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
                "Found matching server: " . $server->{name});
            last;
        }
    }

    # Debug log the stash values
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
        "Stashing values: server_id=$server_id, server_count=" . scalar(@$servers) .
            ", current_server_name=$current_server_name, vm_count=" . scalar(@$vms));

    # Add debug info to the stash
    my $creds_file = Comserv::Util::ProxmoxCredentials::get_credentials_file_path();
    my $creds_exists = -f $creds_file ? 'yes' : 'no';

    # Get the Proxmox model's debug info
    my $proxmox_debug_info = $proxmox->{debug_info} || {};
    
    # Make sure debug_msg exists in the stash and is an array reference
    if (!defined $c->stash->{debug_msg}) {
        $c->stash->{debug_msg} = [];
    } elsif (ref($c->stash->{debug_msg}) ne 'ARRAY') {
        # If debug_msg is a string, convert it to an array with the string as the first element
        my $original_msg = $c->stash->{debug_msg};
        $c->stash->{debug_msg} = [$original_msg];
    }

    # Add useful debug messages
    push @{$c->stash->{debug_msg}}, "Server ID: $server_id";
    push @{$c->stash->{debug_msg}}, "API URL: " . ($credentials->{api_url_base} || "Not set");
    push @{$c->stash->{debug_msg}}, "Node: " . ($credentials->{node} || "Not set");
    push @{$c->stash->{debug_msg}}, "Token User: " . ($credentials->{token_user} || "Not set");
    push @{$c->stash->{debug_msg}}, "Token Value: " . ($credentials->{token_value} ? "Set (length: " . length($credentials->{token_value}) . ")" : "Not set");
    push @{$c->stash->{debug_msg}}, "Auth Success: " . ($auth_success ? "Yes" : "No");
    push @{$c->stash->{debug_msg}}, "VM Count: " . scalar(@$vms);

    # [All your additional debug message logic remains unchanged...]

    my $debug_info = {
        server_id => $server_id,
        server_count => scalar(@$servers),
        vm_count => scalar(@$vms),
        auth_success => $auth_success ? 'yes' : 'no',
        auth_error => $auth_error || 'none',
        current_server_name => $current_server_name,
        first_vm => $vms && @$vms ? {
            vmid => $vms->[0]->{vmid},
            name => $vms->[0]->{name},
            status => $vms->[0]->{status},
            server_id => $vms->[0]->{server_id}
        } : 'none',
        show_debug => 1,  # Set to 1 to show debug info in the UI
        proxmox_credentials_file => $creds_file,
        proxmox_credentials_exists => $creds_exists,
        proxmox_credentials => $credentials,
        proxmox_api_response => $proxmox_debug_info
    };

    # CHANGED HERE: Pre-encode debug_info as JSON
    my $debug_info_json = encode_json($debug_info); # Add this line

    $c->stash(
        template => 'proxmox/index.tt',
        vms => $vms,
        auth_success => $auth_success,
        auth_error => $auth_error,
        server_id => $server_id,
        servers => $servers,
        current_server_name => $current_server_name,
        debug_info => $debug_info,
        debug_info_json => $debug_info_json # CHANGED HERE: Add this to the stash
    );
    $c->forward($c->view('TT'));
}

=head2 create_vm_form

Display the form to create a new VM

=cut

sub create_vm_form :Path('create') :Args(0) {
    my ($self, $c) = @_;

    # Log that we're accessing the create VM form without role check
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_vm_form',
        "Accessing create VM form - role check disabled");
        
    # Get roles for debugging purposes only
    my $roles = $c->session->{roles} || [];
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_vm_form',
        "User roles (for debugging): " . join(", ", @$roles));
        
    # No role check - all API interactions are handled via API tokens

    # Get server_id from parameter or default
    my $server_id = $c->req->param('server_id') || $c->session->{proxmox_server_id} || 'default';

    # Configure the Proxmox model
    my $proxmox = $c->model('Proxmox');

    # Authenticate with Proxmox
    my $auth_success = $proxmox->authenticate();

    unless ($auth_success) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_vm_form',
            "Authentication failed with Proxmox server");

        $c->stash(
            template => 'proxmox/index.tt',
            auth_success => 0,
            auth_error => "Failed to authenticate with Proxmox server. Please contact system administrator.",
            server_id => $server_id,
        );
        $c->forward($c->view('TT'));
        return;
    }

    # Store server_id in session for future requests
    $c->session->{proxmox_server_id} = $server_id;

    # Get available templates
    my $templates = $proxmox->get_available_templates();

    # CPU options
    my @cpu_options = (1, 2);

    # Memory options (in MB)
    my @memory_options = (
        { value => 2048, label => '2GB' },
        { value => 4096, label => '4GB' },
        { value => 8192, label => '8GB' }
    );

    # Disk size options (in GB)
    my @disk_options = (
        { value => 20, label => '20GB' },
        { value => 30, label => '30GB' }
    );

    $c->stash(
        template => 'proxmox/create_vm.tt',
        templates => $templates,
        cpu_options => \@cpu_options,
        memory_options => \@memory_options,
        disk_options => \@disk_options,
        server_id => $server_id,
    );

    $c->forward($c->view('TT'));
}

=head2 create_vm

Process the form submission to create a new VM

=cut

sub create_vm_action :Path('create_vm_action') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_vm_action', "Starting VM creation process");

    # Log that we're accessing the create VM action without role check
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_vm_action',
        "Processing VM creation - role check disabled");
        
    # Get roles for debugging purposes only
    my $roles = $c->session->{roles} || [];
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_vm_action',
        "User roles (for debugging): " . join(", ", @$roles));
        
    # No role check - all API interactions are handled via API tokens

    # Get form parameters
    my $params = {
        hostname => $c->req->params->{hostname},
        description => $c->req->params->{description},
        cpu => $c->req->params->{cpu},
        memory => $c->req->params->{memory},
        disk_size => $c->req->params->{disk_size},
        template => $c->req->params->{template},
        network_type => $c->req->params->{network_type},
        ip_address => $c->req->params->{ip_address},
        subnet_mask => $c->req->params->{subnet_mask},
        gateway => $c->req->params->{gateway},
        start_after_creation => $c->req->params->{start_after_creation},
        enable_qemu_agent => $c->req->params->{enable_qemu_agent},
        start_on_boot => $c->req->params->{start_on_boot},
    };

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_vm_action',
        "Form parameters: hostname=" . ($params->{hostname} || 'undef') .
        ", template=" . ($params->{template} || 'undef') .
        ", cpu=" . ($params->{cpu} || 'undef') .
        ", memory=" . ($params->{memory} || 'undef') .
        ", disk_size=" . ($params->{disk_size} || 'undef'));

    # Validate required fields
    my @required_fields = qw(hostname template);
    my @missing_fields = ();

    foreach my $field (@required_fields) {
        push @missing_fields, $field unless $params->{$field};
    }

    if (@missing_fields) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_vm_action',
            "Missing required fields: " . join(', ', @missing_fields));

        # Get templates for re-displaying the form
        my $templates = $c->model('Proxmox')->get_available_templates();

        $c->stash(
            template => 'proxmox/create_vm.tt',
            error_msg => 'Missing required fields: ' . join(', ', @missing_fields),
            templates => $templates,
            form_data => $params,
        );
        $c->forward($c->view('TT'));
        return;
    }

    # Initialize the Proxmox model
    my $proxmox = $c->model('Proxmox');

    # Get the server ID from the session or use default
    my $server_id = $c->session->{proxmox_server_id} || 'default';
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_vm_action',
        "Using Proxmox server ID: $server_id");

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_vm_action',
        "Configured Proxmox model for server: $server_id");

    # Authenticate with built-in credentials
    my $auth_result = $proxmox->authenticate();

    unless ($auth_result) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_vm_action',
            "Authentication failed with Proxmox server");

        $c->stash(
            template => 'proxmox/create_vm.tt',
            error_msg => "Proxmox authentication failed. Please contact system administrator.",
            form_data => $params,
        );
        $c->forward($c->view('TT'));
        return;
    }

    # Find the selected template
    my $templates = $proxmox->get_available_templates();
    my $selected_template;
    foreach my $template (@$templates) {
        if ($template->{id} eq $params->{template}) {
            $selected_template = $template;
            last;
        }
    }

    unless ($selected_template) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_vm_action',
            "Invalid template selected: " . ($params->{template} || 'undef'));

        $c->stash(
            template => 'proxmox/create_vm.tt',
            error_msg => "Invalid template selected.",
            templates => $templates,
            form_data => $params,
        );
        $c->forward($c->view('TT'));
        return;
    }

    # Add template URL to params
    $params->{template_url} = $selected_template->{url};
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_vm_action',
        "Using template URL: " . $params->{template_url});

    # Add network configuration if static IP is selected
    if ($params->{network_type} eq 'static' && $params->{ip_address} && $params->{subnet_mask} && $params->{gateway}) {
        $params->{ip_config} = {
            ip_address => $params->{ip_address},
            subnet_mask => $params->{subnet_mask},
            gateway => $params->{gateway},
        };
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_vm_action',
            "Using static IP: " . $params->{ip_address} . ", Gateway: " . $params->{gateway});
    } else {
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_vm_action',
            "Using DHCP for network configuration");
    }

    # Create the VM
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_vm_action',
        "Creating VM with hostname: " . $params->{hostname});

    my $result = $proxmox->create_vm($params);

    if ($result->{success}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_vm_action',
            "VM creation successful. VM ID: " . $result->{vmid});

        # VM creation successful
        $c->stash(
            template => 'proxmox/vm_created.tt',
            success_msg => "Virtual machine creation started successfully. VM ID: " . $result->{vmid},
            vm_id => $result->{vmid},
            task_id => $result->{task_id},
        );
        $c->forward($c->view('TT'));
    } else {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_vm_action',
            "VM creation failed: " . ($result->{error} || "Unknown error"));

        # VM creation failed
        my $templates = $proxmox->get_available_templates();

        $c->stash(
            template => 'proxmox/create_vm.tt',
            error_msg => "Failed to create VM: " . ($result->{error} || "Unknown error"),
            templates => $templates,
            form_data => $params,
        );
        $c->forward($c->view('TT'));
    }
}

=head2 select_server

Select a Proxmox server to use for management

=cut

sub select_server :Path('select_server') :Args(0) {
    my ($self, $c) = @_;

    # Check if user has admin role
    my $roles = $c->session->{roles} || [];

    # Log the roles for debugging
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'select_server',
        "User roles: " . join(", ", @$roles));

    # Check if the user has the 'admin' role using grep
    unless (ref $roles eq 'ARRAY' && grep { $_ eq 'admin' } @$roles) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'select_server',
            "User does not have admin role, access denied");

        $c->flash->{error_msg} = "You need administrator privileges to manage Proxmox servers.";
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # If this is a form submission, process it
    if ($c->req->method eq 'POST') {
        my $server_id = $c->req->params->{server_id} || 'ProxmoxDevelopment';

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'select_server',
            "Server selection: $server_id");

        # Store the selected server in the session
        $c->session->{proxmox_server_id} = $server_id;

        # Set success message
        $c->flash->{success_msg} = "Selected Proxmox server: $server_id";

        # Redirect to Proxmox management page
        $c->response->redirect($c->uri_for('/proxmox'));
        return;
    }

    # Configure the Proxmox model
    my $proxmox = $c->model('Proxmox');

    # Get the list of available Proxmox servers from the model
    my $servers = $proxmox->get_servers();

    # Display the server selection form
    $c->stash(
        template => 'proxmox/select_server.tt',
        servers => $servers,
        current_server => $c->session->{proxmox_server_id} || 'ProxmoxDevelopment',
    );
    $c->forward($c->view('TT'));
}

=head2 vm_status

Get the status of a VM

=cut

sub vm_status :Path('status') :Args(1) {
    my ($self, $c, $vmid) = @_;

    # Check if user has admin role
    my $roles = $c->session->{roles} || [];

    # Log the roles for debugging
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'vm_status',
        "User roles: " . join(", ", @$roles));

    # Check if the user has the 'admin' role using grep
    unless (ref $roles eq 'ARRAY' && grep { $_ eq 'admin' } @$roles) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'vm_status',
            "User does not have admin role, access denied");

        $c->stash(
            json => { success => 0, error => 'You need administrator privileges to access VM status.' }
        );
        $c->forward('View::JSON');
        return;
    }

    # Authenticate with Proxmox
    my $proxmox = $c->model('Proxmox');
    my $auth_success = 0;

    # Try to authenticate with Proxmox using built-in credentials
    eval {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'vm_status',
            "Attempting to authenticate with Proxmox server");

        $auth_success = $proxmox->authenticate();
    };

    unless ($auth_success) {
        $c->stash(
            json => { success => 0, error => 'Authentication failed. Please contact system administrator.' }
        );
        $c->forward('View::JSON');
        return;
    }
    
    # Get VM status
    my $status = $proxmox->get_vm_status($vmid);
    
    if ($status) {
        $c->stash(
            json => {
                success => 1,
                status => $status,
            }
        );
    } else {
        $c->stash(
            json => {
                success => 0,
                error => 'Failed to get VM status',
            }
        );
    }
    
    $c->forward('View::JSON');
}

=head1 AUTHOR

Comserv

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;