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
    $server_id ||= 'default';

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Starting Proxmox VM management for server: $server_id");

    # Get credentials for the specified server
    my $credentials = Comserv::Util::ProxmoxCredentials::get_credentials($server_id);

    # Log the credentials we found
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "Credentials retrieved for server $server_id: " .
        "Host=" . ($credentials->{host} || "UNDEFINED") . ", " .
        "Token User=" . ($credentials->{token_user} || "UNDEFINED") . ", " .
        "Token Value=" . ($credentials->{token_value} ? "Present (length: " . length($credentials->{token_value}) . ")" : "MISSING"));

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

    # Try to authenticate with Proxmox
    eval {
        if ($credentials->{host} && $credentials->{token_user} && $credentials->{token_value}) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
                "Attempting to authenticate with Proxmox server using API token: $credentials->{token_user}");

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
            } else {
                $auth_error = 'Failed to authenticate with Proxmox server. Please check credentials.';
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
        } else {
            $auth_error = 'Missing Proxmox server credentials. Please configure a Proxmox server first.';
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'index', $auth_error);

            # Log which specific credentials are missing
            if (!$credentials->{host}) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'index',
                    "Missing host in credentials");
            }
            if (!$credentials->{token_user}) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'index',
                    "Missing token_user in credentials");
            }
            if (!$credentials->{token_value}) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'index',
                    "Missing token_value in credentials");
            }

            # Redirect to the server management page if no server is configured
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
                "Redirecting to ProxmoxServers controller to configure a server");
            $c->response->redirect($c->uri_for('/proxmox_servers'));
            return;
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

    # Get available templates
    my $templates = $c->model('Proxmox')->get_available_templates();

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
    );

    $c->forward($c->view('TT'));
}

=head2 create_vm

Process the form submission to create a new VM

=cut

sub create_vm :Path('create_vm') :Args(0) {
    my ($self, $c) = @_;

    # Get form parameters
    my $params = {
        template_id => $c->req->params->{template_id},
        template_file => $c->req->params->{template_file},
        cpu => $c->req->params->{cpu},
        memory => $c->req->params->{memory},
        disk_size => $c->req->params->{disk_size},
        hostname => $c->req->params->{hostname},
        domain => $c->req->params->{domain},
        username => $c->req->params->{username},
        password => $c->req->params->{password},
    };

    # Validate required fields
    my @required_fields = qw(template_id template_file cpu memory disk_size hostname domain username password);
    my @missing_fields = ();

    foreach my $field (@required_fields) {
        push @missing_fields, $field unless $params->{$field};
    }

    if (@missing_fields) {
        $c->stash(
            template => 'proxmox/create_vm.tt',
            error_msg => 'Missing required fields: ' . join(', ', @missing_fields),
            form_data => $params,
        );
        $c->forward($c->view('TT'));
        return;
    }

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
            template => 'proxmox/create_vm.tt',
            error_msg => 'Failed to authenticate with Proxmox server. Please check credentials in configuration.',
            form_data => $params,
        );
        $c->forward($c->view('TT'));
        return;
    }
    
    # Create the VM
    my $result = $proxmox->create_vm($params);
    
    if ($result->{success}) {
        # If successful, resize the disk if needed
        if ($params->{disk_size} > 20) {
            $proxmox->resize_disk($result->{vmid}, 'scsi0', $params->{disk_size} . 'G');
        }
        
        # Start the VM
        $proxmox->start_vm($result->{vmid});
        
        $c->stash(
            template => 'proxmox/vm_created.tt',
            vmid => $result->{vmid},
            hostname => $params->{hostname},
            domain => $params->{domain},
        );
        $c->forward($c->view('TT'));
    } else {
        $c->stash(
            template => 'proxmox/create_vm.tt',
            error_msg => 'Failed to create VM: ' . ($result->{error} || 'Unknown error'),
            form_data => $params,
        );
        $c->forward($c->view('TT'));
    }
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