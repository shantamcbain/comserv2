package Comserv::Controller::Proxmox;
use Moose;
use namespace::autoclean;
use JSON;
use Data::Dumper;
use Try::Tiny;
use File::Slurp qw(read_file);
use LWP::UserAgent;
use HTTP::Request;
use MIME::Base64 qw(encode_base64);
use Catalyst::Utils;
use Comserv::Util::Logging;
use Comserv::Util::AdminAuth;

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

sub _init_proxmox {
    my ($self, $c) = @_;
    my $server_id = $c->session->{proxmox_server_id};
    unless ($server_id) {
        my $all = Comserv::Util::ProxmoxCredentials::get_all_servers();
        $server_id = ($all && @$all) ? ($all->[0]{id} || $all->[0]{server_id}) : 'ProxmoxDevelopment';
    }
    my $proxmox = $c->model('Proxmox');
    $proxmox->set_server_id($server_id);
    $c->session->{proxmox_server_id} = $server_id;
    return $proxmox;
}

sub index :Path :Args(0) {
    my ($self, $c) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->is_csc_admin($c)) {
        $c->flash->{error_msg} = 'Proxmox management is restricted to CSC administrators.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "Accessing Proxmox controller");

    my $roles = $c->session->{roles} || [];
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
        "User roles: " . join(", ", @$roles));

    # Use server_id from parameter or session; fall back to first saved server
    my $server_id = $c->req->param('server_id') || $c->session->{proxmox_server_id};
    unless ($server_id) {
        my $all_servers = Comserv::Util::ProxmoxCredentials::get_all_servers();
        if ($all_servers && @$all_servers) {
            $server_id = $all_servers->[0]{id} || $all_servers->[0]{server_id};
        }
        $server_id ||= 'ProxmoxDevelopment';
    }

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
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'index', $auth_error);

            # Add more detailed error information if available
            if ($debug_info && $debug_info->{response_code}) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'index',
                    "API response: " . $debug_info->{response_code} . " - " .
                        ($debug_info->{response_status} || "Unknown status"));
            }
        }
    };
    if ($@) {
        $auth_error = "Error connecting to Proxmox server: $@";
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'index', $auth_error);
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
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'index',
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

    my $proxmox_host = '';
    if ($credentials && $credentials->{api_url_base}) {
        ($proxmox_host = $credentials->{api_url_base}) =~ s|/api2/json||;
    }

    $c->stash(
        template => 'proxmox/index.tt',
        vms => $vms,
        auth_success => $auth_success,
        auth_error => $auth_error,
        server_id => $server_id,
        servers => $servers,
        current_server_name => $current_server_name,
        proxmox_host => $proxmox_host,
        debug_info => $debug_info,
        debug_info_json => $debug_info_json
    );
    $c->forward($c->view('TT'));
}

=head2 create_vm_form

Display the form to create a new VM

=cut

sub create_vm_form :Path('create') :Args(0) {
    my ($self, $c) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->is_csc_admin($c)) {
        $c->flash->{error_msg} = 'Proxmox management is restricted to CSC administrators.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_vm_form',
        "Accessing create VM form");
        
    my $roles = $c->session->{roles} || [];
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_vm_form',
        "User roles: " . join(", ", @$roles));

    my $server_id = $c->req->param('server_id') || $c->session->{proxmox_server_id};
    unless ($server_id) {
        my $all_servers = Comserv::Util::ProxmoxCredentials::get_all_servers();
        if ($all_servers && @$all_servers) {
            $server_id = $all_servers->[0]{id} || $all_servers->[0]{server_id};
        }
        $server_id ||= 'ProxmoxDevelopment';
    }

    # Configure the Proxmox model
    my $proxmox = $c->model('Proxmox');
    $proxmox->set_server_id($server_id);

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

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->is_csc_admin($c)) {
        $c->response->status(403);
        $c->response->content_type('application/json');
        $c->response->body('{"success":false,"error":"Access denied: admin required"}');
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_vm_action', "Starting VM creation process");

    my $roles = $c->session->{roles} || [];
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_vm_action',
        "User roles: " . join(", ", @$roles));

    # Get form parameters
    my @db_services = $c->req->param('db_services');
    my $vm_type     = $c->req->params->{vm_type} || 'generic';

    my $base_description = $c->req->params->{description} || '';
    if ($vm_type eq 'database' && @db_services) {
        my $svc_list = join(', ', @db_services);
        $base_description .= $base_description ? " | Services: $svc_list" : "Services: $svc_list";
    }

    my $params = {
        hostname => $c->req->params->{hostname},
        description => $base_description,
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
        vm_type => $vm_type,
        db_services => \@db_services,
        db_port_mysql => $c->req->params->{db_port_mysql} || 3306,
        db_port_postgresql => $c->req->params->{db_port_postgresql} || 5432,
    };

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_vm_action',
        "Form parameters: hostname=" . ($params->{hostname} || 'undef') .
        ", template=" . ($params->{template} || 'undef') .
        ", cpu=" . ($params->{cpu} || 'undef') .
        ", memory=" . ($params->{memory} || 'undef') .
        ", disk_size=" . ($params->{disk_size} || 'undef') .
        ", vm_type=" . $vm_type .
        ", db_services=" . join(',', @db_services));

    # Validate required fields (template is optional — VM is created with blank disk if omitted)
    my @missing_fields = ();
    push @missing_fields, 'hostname' unless $params->{hostname};

    if (@missing_fields) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_vm_action',
            "Missing required fields: " . join(', ', @missing_fields));

        my $templates = $c->model('Proxmox')->get_available_templates();

        $c->stash(
            template  => 'proxmox/create_vm.tt',
            error_msg => 'Missing required fields: ' . join(', ', @missing_fields),
            templates => $templates,
            form_data => $params,
        );
        $c->forward($c->view('TT'));
        return;
    }

    # Initialize the Proxmox model
    my $proxmox = $c->model('Proxmox');

    # Resolve the correct server ID (same logic as create_vm_form)
    my $server_id = $c->session->{proxmox_server_id};
    unless ($server_id) {
        my $all_servers = Comserv::Util::ProxmoxCredentials::get_all_servers();
        if ($all_servers && @$all_servers) {
            $server_id = $all_servers->[0]{id} || $all_servers->[0]{server_id};
        }
        $server_id ||= 'ProxmoxDevelopment';
    }
    $proxmox->set_server_id($server_id);
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_vm_action',
        "Using Proxmox server ID: $server_id");

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

    if ($params->{template}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_vm_action',
            "Using ISO volid for CD-ROM: " . $params->{template});
    }

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

        my $proxmox_host = $proxmox->{api_url_base} || '';
        $proxmox_host =~ s|/api2/json||;
        $c->stash(
            template      => 'proxmox/vm_created.tt',
            success_msg   => "Virtual machine creation started successfully. VM ID: " . $result->{vmid},
            vm_id         => $result->{vmid},
            task_id       => $result->{task_id},
            proxmox_host  => $proxmox_host,
            used_iso      => $params->{template} ? 1 : 0,
            vm_hostname   => $params->{hostname},
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

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->is_csc_admin($c)) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'select_server',
            "Access denied: CSC admin required");
        $c->flash->{error_msg} = 'Proxmox management is restricted to CSC administrators.';
        $c->response->redirect($c->uri_for('/user/login'));
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
        current_server => $c->session->{proxmox_server_id} || '',
    );
    $c->forward($c->view('TT'));
}

=head2 vm_status

Get the status of a VM

=cut

sub vm_status :Path('status') :Args(1) {
    my ($self, $c, $vmid) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->is_csc_admin($c)) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'vm_status',
            "Access denied: CSC admin required");
        $c->stash(
            json => { success => 0, error => 'Proxmox management is restricted to CSC administrators.' }
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

sub vm_isos :Path('vm_isos') :Args(1) {
    my ($self, $c, $vmid) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->is_csc_admin($c)) {
        $c->stash->{json} = { success => 0, error => 'CSC admin required' };
        $c->forward('View::JSON'); return;
    }

    my $proxmox = $self->_init_proxmox($c);
    unless ($proxmox->authenticate()) {
        $c->stash->{json} = { success => 0, error => 'Proxmox authentication failed' };
        $c->forward('View::JSON'); return;
    }

    my $isos      = $proxmox->get_available_templates();
    my $vm_config = $proxmox->get_vm_config($vmid);

    my $current_ide2 = '';
    if ($vm_config && $vm_config->{ide2}) {
        my $raw = $vm_config->{ide2};
        if ($raw =~ /^([^,]+)/) {
            my $volid = $1;
            $current_ide2 = $volid unless $volid eq 'none';
        }
    }

    $c->stash->{json} = {
        success      => 1,
        isos         => $isos,
        current_ide2 => $current_ide2,
    };
    $c->forward('View::JSON');
}

sub attach_iso :Path('attach_iso') :Args(0) {
    my ($self, $c) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->is_csc_admin($c)) {
        $c->stash->{json} = { success => 0, error => 'CSC admin required' };
        $c->forward('View::JSON');
        return;
    }

    my $vmid    = $c->req->params->{vmid}   or do {
        $c->stash->{json} = { success => 0, error => 'vmid required' };
        $c->forward('View::JSON'); return;
    };
    my $iso_volid = $c->req->params->{iso_volid} or do {
        $c->stash->{json} = { success => 0, error => 'iso_volid required' };
        $c->forward('View::JSON'); return;
    };

    my $proxmox = $self->_init_proxmox($c);
    unless ($proxmox->authenticate()) {
        $c->stash->{json} = { success => 0, error => 'Proxmox authentication failed' };
        $c->forward('View::JSON'); return;
    }

    my $result = $proxmox->set_vm_cdrom($vmid, $iso_volid);
    $c->stash->{json} = $result;
    $c->forward('View::JSON');
}

sub eject_iso :Path('eject_iso') :Args(0) {
    my ($self, $c) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->is_csc_admin($c)) {
        $c->stash->{json} = { success => 0, error => 'CSC admin required' };
        $c->forward('View::JSON');
        return;
    }

    my $vmid = $c->req->params->{vmid} or do {
        $c->stash->{json} = { success => 0, error => 'vmid required' };
        $c->forward('View::JSON'); return;
    };

    my $proxmox = $self->_init_proxmox($c);
    unless ($proxmox->authenticate()) {
        $c->stash->{json} = { success => 0, error => 'Proxmox authentication failed' };
        $c->forward('View::JSON'); return;
    }

    my $result = $proxmox->set_vm_cdrom($vmid, '');
    $c->stash->{json} = $result;
    $c->forward('View::JSON');
}

sub edit_vm_form :Path('edit_vm') :Args(1) {
    my ($self, $c, $vmid) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->is_csc_admin($c)) {
        $c->flash->{error_msg} = 'Proxmox management is restricted to CSC administrators.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    my $proxmox = $self->_init_proxmox($c);
    unless ($proxmox->authenticate()) {
        $c->flash->{error_msg} = 'Proxmox authentication failed.';
        $c->response->redirect($c->uri_for('/proxmox'));
        return;
    }

    my $config = $proxmox->get_vm_config($vmid);
    unless ($config) {
        $c->stash(
            template  => 'proxmox/edit_vm.tt',
            error_msg => "Could not retrieve configuration for VM $vmid.",
            vmid      => $vmid,
        );
        $c->forward($c->view('TT'));
        return;
    }

    my $proxmox_host = '';
    my $creds = Comserv::Util::ProxmoxCredentials::get_credentials($c->session->{proxmox_server_id});
    if ($creds && $creds->{api_url_base}) {
        ($proxmox_host = $creds->{api_url_base}) =~ s|/api2/json||;
    }

    $c->stash(
        template     => 'proxmox/edit_vm.tt',
        vmid         => $vmid,
        vm_config    => $config,
        proxmox_host => $proxmox_host,
    );
    $c->forward($c->view('TT'));
}

sub edit_vm_action :Path('edit_vm_action') :Args(0) {
    my ($self, $c) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->is_csc_admin($c)) {
        $c->flash->{error_msg} = 'Proxmox management is restricted to CSC administrators.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    my $vmid = $c->req->params->{vmid};
    unless ($vmid) {
        $c->response->redirect($c->uri_for('/proxmox'));
        return;
    }

    my $proxmox = $self->_init_proxmox($c);
    unless ($proxmox->authenticate()) {
        $c->flash->{error_msg} = 'Proxmox authentication failed.';
        $c->response->redirect($c->uri_for('/proxmox'));
        return;
    }

    my $params = {
        name        => $c->req->params->{name},
        cores       => $c->req->params->{cores},
        memory      => $c->req->params->{memory},
        description => $c->req->params->{description},
        onboot      => $c->req->params->{onboot} ? '1' : '0',
        agent       => $c->req->params->{agent}  ? '1' : '0',
    };

    my $result = $proxmox->update_vm_config($vmid, $params);

    if ($result->{success}) {
        $c->flash->{success_msg} = $result->{message} || "VM $vmid updated successfully.";
        $c->response->redirect($c->uri_for('/proxmox'));
    } else {
        $c->flash->{error_msg} = $result->{error} || "Failed to update VM $vmid.";
        $c->response->redirect($c->uri_for("/proxmox/edit_vm/$vmid"));
    }
}

sub resize_disk :Path('resize_disk') :Args(0) {
    my ($self, $c) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->is_csc_admin($c)) {
        $c->stash->{json} = { success => 0, error => 'CSC admin required' };
        $c->forward('View::JSON'); return;
    }

    my $vmid     = $c->req->params->{vmid} or do {
        $c->stash->{json} = { success => 0, error => 'vmid required' };
        $c->forward('View::JSON'); return;
    };
    my $disk     = $c->req->params->{disk} || 'scsi0';
    my $new_size = $c->req->params->{new_size_gb} or do {
        $c->stash->{json} = { success => 0, error => 'new_size_gb required' };
        $c->forward('View::JSON'); return;
    };

    my $proxmox = $self->_init_proxmox($c);
    unless ($proxmox->authenticate()) {
        $c->stash->{json} = { success => 0, error => 'Proxmox authentication failed' };
        $c->forward('View::JSON'); return;
    }

    my $result = $proxmox->resize_disk($vmid, $disk, $new_size);
    $c->stash->{json} = $result;
    $c->forward('View::JSON');
}

sub vm_power :Path('vm_power') :Args(0) {
    my ($self, $c) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->is_csc_admin($c)) {
        $c->stash->{json} = { success => 0, error => 'CSC admin required' };
        $c->forward('View::JSON'); return;
    }

    my $vmid   = $c->req->params->{vmid}   or do {
        $c->stash->{json} = { success => 0, error => 'vmid required' };
        $c->forward('View::JSON'); return;
    };
    my $action = $c->req->params->{action} or do {
        $c->stash->{json} = { success => 0, error => 'action required (start|stop|shutdown|reboot|reset)' };
        $c->forward('View::JSON'); return;
    };

    my $proxmox = $self->_init_proxmox($c);
    unless ($proxmox->authenticate()) {
        $c->stash->{json} = { success => 0, error => 'Proxmox authentication failed' };
        $c->forward('View::JSON'); return;
    }

    my $result = $proxmox->vm_power_action($vmid, $action);
    $c->stash->{json} = $result;
    $c->forward('View::JSON');
}

sub upload_iso :Path('upload_iso') :Args(0) {
    my ($self, $c) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->is_csc_admin($c)) {
        $c->stash->{json} = { success => 0, error => 'CSC admin required' };
        $c->forward('View::JSON'); return;
    }

    if ($c->req->method eq 'GET') {
        my $proxmox = $self->_init_proxmox($c);
        $proxmox->authenticate();

        my $storages = $proxmox->get_storages_for_iso() || [];
        my $local_isos = [];
        my $kvm_dir = '/home/shanta/kvm-images';
        if (opendir(my $dh, $kvm_dir)) {
            while (my $f = readdir($dh)) {
                push @$local_isos, { name => $f, path => "$kvm_dir/$f" }
                    if $f =~ /\.iso$/i;
            }
            closedir($dh);
        }
        @$local_isos = sort { $a->{name} cmp $b->{name} } @$local_isos;

        $c->stash(
            template   => 'proxmox/upload_iso.tt',
            storages   => $storages,
            local_isos => $local_isos,
        );
        $c->forward($c->view('TT'));
        return;
    }

    my $iso_path = $c->req->params->{iso_path};
    my $storage  = $c->req->params->{storage} || 'local';

    unless ($iso_path && -f $iso_path) {
        $c->stash->{json} = { success => 0, error => "Invalid file path: $iso_path" };
        $c->forward('View::JSON'); return;
    }

    my $proxmox = $self->_init_proxmox($c);
    unless ($proxmox->authenticate()) {
        $c->stash->{json} = { success => 0, error => 'Proxmox authentication failed' };
        $c->forward('View::JSON'); return;
    }

    my $result = $proxmox->upload_iso_to_proxmox($iso_path, $storage);
    $c->stash->{json} = $result;
    $c->forward('View::JSON');
}

sub available_ips :Path('available_ips') :Args(0) {
    my ($self, $c) = @_;

    my $subnet = $c->req->param('subnet') || '192.168.1';

    my %used_ips;

    my $net_file = Catalyst::Utils::home('Comserv') . '/config/network/network_map.json';
    if (-f $net_file) {
        try {
            my $data = decode_json(read_file($net_file));
            for my $dev (values %{ $data->{devices} || {} }) {
                $used_ips{ $dev->{ip} } = $dev->{type} || 'device'
                    if $dev->{ip} && $dev->{ip} =~ /^\Q$subnet\E\./;
            }
        } catch {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'available_ips',
                "Could not read network_map.json: $_");
        };
    }

    my $opnsense_cfg_file = Catalyst::Utils::home('Comserv') . '/config/infrastructure/opnsense.json';
    if (-f $opnsense_cfg_file) {
        try {
            my $cfg = decode_json(read_file($opnsense_cfg_file));
            if ($cfg->{host} && $cfg->{key} && $cfg->{secret}) {
                my $base = "https://$cfg->{host}:${\($cfg->{port}||443)}/api";
                my $auth = 'Basic ' . encode_base64("$cfg->{key}:$cfg->{secret}", '');
                my $ua   = LWP::UserAgent->new(timeout => 5);
                $ua->ssl_opts(verify_hostname => 0, SSL_verify_mode => 0);
                my $req = HTTP::Request->new(GET => "$base/dhcpv4/leases/searchLease");
                $req->header(Authorization => $auth);
                my $res = $ua->request($req);
                if ($res->is_success) {
                    my $leases = decode_json($res->decoded_content);
                    for my $lease (@{ $leases->{rows} || [] }) {
                        my $ip = $lease->{address} || $lease->{ip} || '';
                        $used_ips{$ip} = 'DHCP lease (' . ($lease->{hostname} || 'unknown') . ')'
                            if $ip && $ip =~ /^\Q$subnet\E\./;
                    }
                }
            }
        } catch {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'available_ips',
                "OPNsense DHCP query failed: $_");
        };
    }

    my @available;
    for my $last (10..254) {
        my $ip = "$subnet.$last";
        push @available, $ip unless $used_ips{$ip};
        last if @available >= 20;
    }

    my @used_list = map { { ip => $_, reason => $used_ips{$_} } }
                    sort keys %used_ips;

    $c->stash->{json} = {
        subnet    => "$subnet.0/24",
        available => \@available,
        used      => \@used_list,
    };
    $c->forward('View::JSON');
}

sub vm_detail :Path('vm_detail') :Args(1) {
    my ($self, $c, $vmid) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->is_csc_admin($c)) {
        $c->flash->{error_msg} = 'Proxmox management is restricted to CSC administrators.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    my $proxmox = $self->_init_proxmox($c);
    unless ($proxmox->authenticate()) {
        $c->flash->{error_msg} = 'Proxmox authentication failed.';
        $c->response->redirect($c->uri_for('/proxmox'));
        return;
    }

    my $config    = $proxmox->get_vm_config($vmid);
    my $status    = $proxmox->get_vm_status($vmid);
    my $snapshots = $proxmox->list_snapshots($vmid);
    my $backups   = $proxmox->list_backups($vmid);

    my $proxmox_host = '';
    my $creds = Comserv::Util::ProxmoxCredentials::get_credentials($c->session->{proxmox_server_id});
    if ($creds && $creds->{api_url_base}) {
        ($proxmox_host = $creds->{api_url_base}) =~ s|/api2/json||;
    }

    $c->stash(
        template     => 'proxmox/vm_detail.tt',
        vmid         => $vmid,
        vm_config    => $config,
        vm_status    => $status,
        snapshots    => $snapshots,
        backups      => $backups,
        proxmox_host => $proxmox_host,
    );
    $c->forward($c->view('TT'));
}

sub clone_vm_form :Path('clone_vm') :Args(1) {
    my ($self, $c, $vmid) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->is_csc_admin($c)) {
        $c->flash->{error_msg} = 'Proxmox management is restricted to CSC administrators.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    my $proxmox = $self->_init_proxmox($c);
    unless ($proxmox->authenticate()) {
        $c->flash->{error_msg} = 'Proxmox authentication failed.';
        $c->response->redirect($c->uri_for('/proxmox'));
        return;
    }

    my $config  = $proxmox->get_vm_config($vmid);
    my $next_id = $proxmox->get_next_vmid();

    $c->stash(
        template  => 'proxmox/vm_detail.tt',
        vmid      => $vmid,
        vm_config => $config,
        next_vmid => $next_id,
        show_clone_form => 1,
    );
    $c->forward($c->view('TT'));
}

sub clone_vm_action :Path('clone_vm_action') :Args(0) {
    my ($self, $c) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->is_csc_admin($c)) {
        $c->stash->{json} = { success => 0, error => 'CSC admin required' };
        $c->forward('View::JSON'); return;
    }

    my $vmid     = $c->req->params->{vmid}    or do { $c->stash->{json} = { success => 0, error => 'vmid required' }; $c->forward('View::JSON'); return; };
    my $newid    = $c->req->params->{newid}   or do { $c->stash->{json} = { success => 0, error => 'newid required' }; $c->forward('View::JSON'); return; };
    my $name     = $c->req->params->{name}    || '';
    my $full     = $c->req->params->{full}    // 1;
    my $storage  = $c->req->params->{storage} || '';
    my $new_ip   = $c->req->params->{new_ip}  || '';
    my $gateway  = $c->req->params->{gateway} || '';
    my $dns      = $c->req->params->{dns}     || '';
    my $hostname = $c->req->params->{hostname}|| '';

    my $proxmox = $self->_init_proxmox($c);
    unless ($proxmox->authenticate()) {
        $c->stash->{json} = { success => 0, error => 'Proxmox authentication failed' };
        $c->forward('View::JSON'); return;
    }

    my $result = $proxmox->clone_vm($vmid, $newid, $name, $full, $storage);
    if ($result->{success} && ($new_ip || $hostname || $dns)) {
        my %config_params;
        if ($new_ip) {
            my $ipconfig = "ip=$new_ip";
            $ipconfig .= ",gw=$gateway" if $gateway;
            $config_params{ipconfig0} = $ipconfig;
            $config_params{citype}    = 'nocloud';
        }
        $config_params{name}       = $hostname if $hostname;
        $config_params{nameserver} = $dns      if $dns;

        my $cfg_result = $proxmox->set_vm_config($newid, %config_params);
        $result->{ip_config} = $cfg_result->{success} ? 'applied' : ('failed: ' . ($cfg_result->{error} || ''));
    }

    $c->stash->{json} = $result;
    $c->forward('View::JSON');
}

sub snapshot_create :Path('snapshot_create') :Args(0) {
    my ($self, $c) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->is_csc_admin($c)) {
        $c->stash->{json} = { success => 0, error => 'CSC admin required' };
        $c->forward('View::JSON'); return;
    }

    my $vmid     = $c->req->params->{vmid}     or do { $c->stash->{json} = { success => 0, error => 'vmid required' }; $c->forward('View::JSON'); return; };
    my $snapname = $c->req->params->{snapname} or do { $c->stash->{json} = { success => 0, error => 'snapname required' }; $c->forward('View::JSON'); return; };
    my $desc     = $c->req->params->{description} || '';

    my $proxmox = $self->_init_proxmox($c);
    unless ($proxmox->authenticate()) {
        $c->stash->{json} = { success => 0, error => 'Proxmox authentication failed' };
        $c->forward('View::JSON'); return;
    }

    my $result = $proxmox->create_snapshot($vmid, $snapname, $desc);
    $c->stash->{json} = $result;
    $c->forward('View::JSON');
}

sub snapshot_rollback :Path('snapshot_rollback') :Args(0) {
    my ($self, $c) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->is_csc_admin($c)) {
        $c->stash->{json} = { success => 0, error => 'CSC admin required' };
        $c->forward('View::JSON'); return;
    }

    my $vmid     = $c->req->params->{vmid}     or do { $c->stash->{json} = { success => 0, error => 'vmid required' }; $c->forward('View::JSON'); return; };
    my $snapname = $c->req->params->{snapname} or do { $c->stash->{json} = { success => 0, error => 'snapname required' }; $c->forward('View::JSON'); return; };

    my $proxmox = $self->_init_proxmox($c);
    unless ($proxmox->authenticate()) {
        $c->stash->{json} = { success => 0, error => 'Proxmox authentication failed' };
        $c->forward('View::JSON'); return;
    }

    my $result = $proxmox->rollback_snapshot($vmid, $snapname);
    $c->stash->{json} = $result;
    $c->forward('View::JSON');
}

sub backup_restore :Path('backup_restore') :Args(0) {
    my ($self, $c) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->is_csc_admin($c)) {
        $c->stash->{json} = { success => 0, error => 'CSC admin required' };
        $c->forward('View::JSON'); return;
    }

    my $vmid    = $c->req->params->{vmid}    or do { $c->stash->{json} = { success => 0, error => 'vmid required' }; $c->forward('View::JSON'); return; };
    my $volid   = $c->req->params->{volid}   or do { $c->stash->{json} = { success => 0, error => 'volid required' }; $c->forward('View::JSON'); return; };
    my $storage = $c->req->params->{storage} || '';

    my $proxmox = $self->_init_proxmox($c);
    unless ($proxmox->authenticate()) {
        $c->stash->{json} = { success => 0, error => 'Proxmox authentication failed' };
        $c->forward('View::JSON'); return;
    }

    my $result = $proxmox->restore_backup($vmid, $volid, $storage);
    $c->stash->{json} = $result;
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