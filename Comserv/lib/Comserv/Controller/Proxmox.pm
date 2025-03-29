package Comserv::Controller::Proxmox;
use Moose;
use namespace::autoclean;
use JSON;
use Data::Dumper;
use Try::Tiny;
use Comserv::Util::ProxmoxCredentials;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

=head1 NAME

Comserv::Controller::Proxmox - Catalyst Controller for Proxmox VM Management

=head1 DESCRIPTION

Catalyst Controller for managing Proxmox virtual machines.

=head1 METHODS

=cut

=head2 index

The main Proxmox management page

=cut

sub index :Path :Args(0) {
    my ($self, $c, $server_id) = @_;

# Check if user has admin role
unless ($c->check_user_roles('admin')) {
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'index',
        "User does not have admin role, access denied");

    $c->flash->{error_msg} = "You need administrator privileges to access Proxmox management.";
    $c->response->redirect($c->uri_for('/'));
    return;
}

    # Use server_id from parameter or default
    my $server_id = $c->req->param('server_id') || $c->session->{proxmox_server_id} || 'default';

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
       
        "Starting Proxmox VM management for server: $server_id");

    # Get credentials for the specified server
    my $credentials = Comserv::Util::ProxmoxCredentials::get_credentials($server_id);

    # Log the credentials we found
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "Credentials retrieved for server $server_id: " .
        "Host=" . ($credentials->{host} || "UNDEFINED") . ", " .
        "Token User=" . ($credentials->{token_user} || "UNDEFINED") . ", " .
        "Token Value=" . ($credentials->{token_value} ? "Present (length: " . length($credentials->{token_value}) . ")" : "MISSING"));

    # Check if we have valid credentials
    unless ($credentials->{host} && $credentials->{token_user} && $credentials->{token_value}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index',
            "Missing Proxmox credentials for server: $server_id");

        $c->stash(
            template => 'proxmox/index.tt',
            auth_success => 0,
            auth_error => "Missing Proxmox credentials. Please configure the Proxmox server first.",
            server_id => $server_id,
            servers => Comserv::Util::ProxmoxCredentials::get_all_servers(),
        );
        $c->forward($c->view('TT'));
        return;
    }

    # Check if we have valid credentials
    unless ($credentials->{host} && $credentials->{token_user} && $credentials->{token_value}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index',
            "Missing Proxmox credentials for server: $server_id");

        $c->stash(
            template => 'proxmox/index.tt',
            auth_success => 0,
            auth_error => "Missing Proxmox credentials. Please configure the Proxmox server first.",
            server_id => $server_id,
            servers => Comserv::Util::ProxmoxCredentials::get_all_servers(),
        );
        $c->forward($c->view('TT'));
        return;
    }

    # Configure the Proxmox model with the server settings
    my $proxmox = $c->model('Proxmox');
    $proxmox->{proxmox_host} = $credentials->{host} if $credentials->{host};
    $proxmox->{api_url_base} = $credentials->{api_url_base} if $credentials->{api_url_base};
    $proxmox->{node} = $credentials->{node} if $credentials->{node};
    $proxmox->{image_url_base} = $credentials->{image_url_base} if $credentials->{image_url_base};

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
        "Configured Proxmox model with host: $proxmox->{proxmox_host}, node: $proxmox->{node}");

    my $auth_success = 0;
    my $auth_error = '';

    # Try to authenticate with Proxmox using stored credentials
    eval {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
            "Attempting to authenticate with Proxmox server using token: " . $credentials->{token_user});

        $auth_success = $proxmox->authenticate_with_token(
            $credentials->{token_user},
            $credentials->{token_value}
        );

        # Get debug info from the Proxmox model
        my $debug_info = $proxmox->{debug_info} || {};

        if ($auth_success) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
                "Successfully authenticated with Proxmox server");
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
                "Response code: " . ($debug_info->{response_code} || "UNKNOWN"));

            # Store credentials in session for future requests
            $c->session->{proxmox_server_id} = $server_id;
            $c->session->{proxmox_token_user} = $credentials->{token_user};
            $c->session->{proxmox_token_value} = $credentials->{token_value};
        } else {
            $auth_error = 'Failed to authenticate with Proxmox server. Please check your credentials.';
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index', $auth_error);

            # Add more detailed error information
            if ($debug_info->{response_code}) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index',
                    "API response: " . $debug_info->{response_code} . " - " .
                    ($debug_info->{response_status} || "Unknown status"));
            }

            # Log the token format validation
            if ($debug_info->{token_user_format_valid} == 0) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index',
                    "Token user format is invalid. Expected format: USER\@REALM!TOKENID");
            }
        }
    };
    if ($@) {
        $auth_error = "Error connecting to Proxmox server: $@";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index', $auth_error);
    }

    my $vms = [];
    if ($auth_success) {
        # Get list of VMs
        eval {
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
                "Retrieving VM list from Proxmox server");

            $vms = $proxmox->get_vms();

            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
                "Retrieved " . scalar(@$vms) . " VMs from Proxmox server");
        };
        if ($@) {
            my $error = "Error getting VM list: $@";
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index', $error);
            $c->log->error($error);
        }
    }

    # Get list of all servers for the server selector
    my $servers = Comserv::Util::ProxmoxCredentials::get_all_servers();

    $c->stash(
        template => 'proxmox/index.tt',
        vms => $vms,
        auth_success => $auth_success,
        auth_error => $auth_error,
        server_id => $server_id,
        servers => $servers,
        credentials => $credentials
    );
    $c->forward($c->view('TT'));
}

=head2 create_vm_form

Display the form to create a new VM

=cut

sub create_vm_form :Path('create') :Args(0) {
    my ($self, $c) = @_;

    # Check if user has admin role
    unless ($c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'create_vm_form',
            "User does not have admin role, access denied");

        $c->flash->{error_msg} = "You need administrator privileges to create VMs.";
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Get server_id from parameter or default
    my $server_id = $c->req->param('server_id') || $c->session->{proxmox_server_id} || 'default';

    # Get credentials for the specified server
    my $credentials = Comserv::Util::ProxmoxCredentials::get_credentials($server_id);

    # Configure the Proxmox model with the server settings
    my $proxmox = $c->model('Proxmox');
    $proxmox->{proxmox_host} = $credentials->{host} if $credentials->{host};
    $proxmox->{api_url_base} = $credentials->{api_url_base} if $credentials->{api_url_base};
    $proxmox->{node} = $credentials->{node} if $credentials->{node};
    $proxmox->{image_url_base} = $credentials->{image_url_base} if $credentials->{image_url_base};

    # Authenticate with Proxmox
    my $auth_success = $proxmox->authenticate_with_token(
        $credentials->{token_user},
        $credentials->{token_value}
    );

    unless ($auth_success) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_vm_form',
            "Authentication failed with Proxmox server");

        $c->stash(
            template => 'proxmox/index.tt',
            auth_success => 0,
            auth_error => "Failed to authenticate with Proxmox server. Please check credentials.",
            server_id => $server_id,
            servers => Comserv::Util::ProxmoxCredentials::get_all_servers(),
        );
        $c->forward($c->view('TT'));
        return;
    }

    # Store credentials in session for future requests
    $c->session->{proxmox_server_id} = $server_id;
    $c->session->{proxmox_token_user} = $credentials->{token_user};
    $c->session->{proxmox_token_value} = $credentials->{token_value};

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

    # Check if user has admin role
    unless ($c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'create_vm_action',
            "User does not have admin role, access denied");

        $c->flash->{error_msg} = "You need administrator privileges to create VMs.";
        $c->response->redirect($c->uri_for('/'));
        return;
    }

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

    # Get credentials for the specified server
    my $credentials = Comserv::Util::ProxmoxCredentials::get_credentials($server_id);

    # Configure the Proxmox model with the server settings
    $proxmox->{proxmox_host} = $credentials->{host} if $credentials->{host};
    $proxmox->{api_url_base} = $credentials->{api_url_base} if $credentials->{api_url_base};
    $proxmox->{node} = $credentials->{node} if $credentials->{node};
    $proxmox->{image_url_base} = $credentials->{image_url_base} if $credentials->{image_url_base};

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_vm_action',
        "Configured Proxmox model with host: $proxmox->{proxmox_host}, node: $proxmox->{node}");

    # Authenticate with credentials from configuration
    my $auth_result = $proxmox->authenticate_with_token(
        $credentials->{token_user},
        $credentials->{token_value}
    );

    unless ($auth_result) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_vm_action',
            "Authentication failed with token: " . $credentials->{token_user});

        $c->stash(
            template => 'proxmox/create_vm.tt',
            error_msg => "Proxmox authentication failed. Please check server credentials.",
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
    unless ($c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'select_server',
            "User does not have admin role, access denied");

        $c->flash->{error_msg} = "You need administrator privileges to manage Proxmox servers.";
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # If this is a form submission, process it
    if ($c->req->method eq 'POST') {
        my $server_id = $c->req->params->{server_id} || 'default';

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

    # Get list of all servers for the server selector
    my $servers = Comserv::Util::ProxmoxCredentials::get_all_servers();

    # Display the server selection form
    $c->stash(
        template => 'proxmox/select_server.tt',
        servers => $servers,
        current_server => $c->session->{proxmox_server_id} || 'default',
    );
    $c->forward($c->view('TT'));
}

=head2 vm_status

Get the status of a VM

=cut

sub vm_status :Path('status') :Args(1) {
    my ($self, $c, $vmid) = @_;

    # Authenticate with Proxmox
    my $proxmox = $c->model('Proxmox');
    my $auth_success = 0;

    # Try to authenticate with Proxmox
    eval {
        # Get credentials from config or use defaults for testing
        my $username = $c->config->{'Model::Proxmox'}->{username} || 'root';
        my $password = $c->config->{'Model::Proxmox'}->{password} || 'password';
        my $realm = $c->config->{'Model::Proxmox'}->{realm} || 'pam';

        $auth_success = $proxmox->authenticate($username, $password, $realm);
    };

    unless ($auth_success) {
        $c->stash(
            json => { success => 0, error => 'Authentication failed. Please check Proxmox credentials in configuration.' }
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