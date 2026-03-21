package Comserv::Controller::Admin::NetworkDevices;

use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

# Returns an instance of the logging utility
sub logging {
    my ($self) = @_;
    return Comserv::Util::Logging->instance();
}

# Begin method to check if the user has admin role
sub begin : Private {
    my ($self, $c) = @_;
    
    # Add detailed logging
    my $username = ($c->user_exists && $c->user) ? $c->user->username : ($c->session->{username} || 'Guest');
    my $path = $c->req->path;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', 
        "NetworkDevices controller begin method called for user: $username, Path: $path");
    
    # Check if the user is logged in
    if (!$c->user_exists) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', 
            "User is not logged in, redirecting to login page");
        # If the user isn't logged in, redirect to the login page with return_to parameter
        my $current_path = $c->req->path;
        $c->response->redirect($c->uri_for('/user/login', { return_to => "/$current_path" }));
        return;
    }
    
    # Fetch the roles from the session
    my $roles = $c->session->{roles};
    
    # Check if roles is defined and is an array reference
    if (defined $roles && ref $roles eq 'ARRAY') {
        # Check if the user has the 'admin' role
        if (grep { $_ eq 'admin' } @$roles) {
            # User is an admin, proceed with the request
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', 
                "User $username has admin role, proceeding with request");
        } else {
            # User is not an admin, redirect to the login page with a message
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'begin', 
                "User $username does not have admin role, redirecting to login page");
            
            # Store the error message in flash
            $c->flash->{error_msg} = "You need administrator privileges to access this page. Please log in with an admin account.";
            
            # Redirect to the login page with return_to parameter
            my $current_path = $c->req->path;
            $c->response->redirect($c->uri_for('/user/login', { return_to => "/$current_path" }));
            return;
        }
    } else {
        # Roles is not defined or not an array, redirect to login page
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'begin', 
            "User $username has invalid roles format, redirecting to login page");
        
        # Store the error message in flash
        $c->flash->{error_msg} = "Your session has invalid role information. Please log in again.";
        
        # Redirect to the login page with return_to parameter
        my $current_path = $c->req->path;
        $c->response->redirect($c->uri_for('/user/login', { return_to => "/$current_path" }));
        return;
    }
}

# Index action to ensure the controller is loaded
sub index :Path :Auth :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "NetworkDevices controller index method called");
    $c->forward('network_devices');
}

=head2 network_devices

Admin interface to manage network devices

=cut

sub network_devices :Path('/admin/network_devices') :Auth('/admin/network_devices') :Args(0) {
    my ($self, $c) = @_;

    # Log the beginning of the network_devices action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'network_devices', "Starting network_devices action");

    # Admin role check is now handled in the begin method

    # Get the selected site filter (if any)
    my $site_filter = $c->req->param('site') || '';
    
    # Get all devices from the database
    my @devices = ();
    
    # Try to fetch devices from the database if the table exists
    eval {
        my $search_params = {};
        
        # Add site filter if specified
        if ($site_filter) {
            $search_params->{site_name} = $site_filter;
        }
        
        # Log the attempt to access the NetworkDevice table
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'network_devices', 
            "Attempting to access NetworkDevice table with filter: " . ($site_filter || 'None'));
        
        @devices = $c->model('DBEncy')->schema->resultset('NetworkDevice')->search(
            $search_params,
            { order_by => { -asc => 'device_name' } }
        );
        
        # Log success
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'network_devices', 
            "Successfully retrieved " . scalar(@devices) . " devices from the database");
    };
    
    # If there was an error (likely because the table doesn't exist yet)
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'network_devices', 
            "Error fetching devices: $@. Table may not exist yet.");
        
        # Add sample devices for demonstration if the table doesn't exist
        @devices = (
            { 
                id => 1, 
                device_name => 'Main Router', 
                ip_address => '192.168.1.1', 
                mac_address => '00:11:22:33:44:55',
                device_type => 'Router',
                location => 'Server Room',
                purpose => 'Main internet gateway',
                notes => 'Cisco router providing internet access and firewall',
                site_name => 'CSC'
            },
            { 
                id => 2, 
                device_name => 'Core Switch', 
                ip_address => '192.168.1.2', 
                mac_address => '00:11:22:33:44:56',
                device_type => 'Switch',
                location => 'Server Room',
                purpose => 'Core network switch',
                notes => 'Cisco Catalyst 9300 Series',
                site_name => 'CSC'
            },
            { 
                id => 3, 
                device_name => 'Office AP', 
                ip_address => '192.168.1.3', 
                mac_address => '00:11:22:33:44:57',
                device_type => 'Access Point',
                location => 'Main Office',
                purpose => 'Wireless access',
                notes => 'Cisco Meraki MR Series',
                site_name => 'CSC'
            },
            { 
                id => 4, 
                device_name => 'MCOOP Router', 
                ip_address => '10.0.0.1', 
                mac_address => '00:11:22:33:44:58',
                device_type => 'Router',
                location => 'MCOOP Office',
                purpose => 'Main router for MCOOP',
                notes => 'Ubiquiti EdgeRouter',
                site_name => 'MCOOP'
            },
            { 
                id => 5, 
                device_name => 'MCOOP Switch', 
                ip_address => '10.0.0.2', 
                mac_address => '00:11:22:33:44:59',
                device_type => 'Switch',
                location => 'MCOOP Office',
                purpose => 'Network switch for MCOOP',
                notes => 'Ubiquiti EdgeSwitch',
                site_name => 'MCOOP'
            }
        );
        
        # Filter by site if needed
        if ($site_filter) {
            @devices = grep { $_->{site_name} eq $site_filter } @devices;
        }
    }

    # Get list of sites for the filter dropdown
    my @sites = ();
    eval {
        @sites = $c->model('DBEncy::Site')->search(
            {},
            { order_by => { -asc => 'name' } }
        );
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'network_devices', 
            "Error fetching sites: $@");
        
        # Add sample sites if we can't get them from the database
        @sites = (
            { id => 1, name => 'CSC' },
            { id => 2, name => 'MCOOP' },
            { id => 3, name => 'BMaster' }
        );
    }

    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless defined $c->stash->{debug_msg};
        push @{$c->stash->{debug_msg}}, "Admin controller network_devices view - Template: admin/network_devices.tt";
        push @{$c->stash->{debug_msg}}, "Device count: " . scalar(@devices);
        push @{$c->stash->{debug_msg}}, "Site filter: " . ($site_filter || 'None');
    }

    # Pass data to the template
    $c->stash(
        devices => \@devices,
        sites => \@sites,
        site_filter => $site_filter,
        template => 'admin/network_devices.tt'
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'network_devices', 'Set template to admin/network_devices.tt');
    $c->forward($c->view('TT'));
}

=head2 add_network_device

Admin interface to add a new network device

=cut

sub add_network_device :Path('/admin/add_network_device') :Auth('/admin/add_network_device') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_network_device', 'Enter add_network_device method');

    # Admin role check is now handled in the begin method

    # Get list of sites for the dropdown
    my @sites = ();
    eval {
        @sites = $c->model('DBEncy::Site')->search(
            {},
            { order_by => { -asc => 'name' } }
        );
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'add_network_device', 
            "Error fetching sites: $@");
        
        # Add sample sites if we can't get them from the database
        @sites = (
            { id => 1, name => 'CSC' },
            { id => 2, name => 'MCOOP' },
            { id => 3, name => 'BMaster' }
        );
    }

    # If this is a form submission, process it
    if ($c->req->method eq 'POST') {
        # Retrieve the form data
        my $device_name = $c->req->params->{device_name};
        my $ip_address = $c->req->params->{ip_address};
        my $mac_address = $c->req->params->{mac_address};
        my $device_type = $c->req->params->{device_type};
        my $location = $c->req->params->{location};
        my $purpose = $c->req->params->{purpose};
        my $notes = $c->req->params->{notes};
        my $site_name = $c->req->params->{site_name};

        # Log the device creation attempt
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_network_device',
            "Device creation attempt for device: $device_name with IP: $ip_address, Site: $site_name");

        # Ensure all required fields are filled
        unless ($device_name && $ip_address && $site_name) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'add_network_device',
                "Missing required fields for device creation");

            $c->stash(
                error_msg => 'Device name, IP address, and site are required',
                sites => \@sites,
                template => 'admin/add_network_device.tt',
            );
            $c->forward($c->view('TT'));
            return;
        }

        # Create the new device
        eval {
            $c->model('DBEncy')->schema->resultset('NetworkDevice')->create({
                device_name => $device_name,
                ip_address => $ip_address,
                mac_address => $mac_address,
                device_type => $device_type,
                location => $location,
                purpose => $purpose,
                notes => $notes,
                site_name => $site_name,
                created_at => \'NOW()',
            });

            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_network_device',
                "Device created successfully: $device_name with IP: $ip_address, Site: $site_name");

            # Set success message and redirect to device list
            $c->flash->{success_msg} = "Device '$device_name' created successfully.";
            $c->response->redirect($c->uri_for('/admin/network_devices', { site => $site_name }));
            return;
        };

        if ($@) {
            # Handle database errors
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_network_device',
                "Error creating device: $@");

            $c->stash(
                error_msg => "Error creating device: $@",
                sites => \@sites,
                template => 'admin/add_network_device.tt',
            );
            $c->forward($c->view('TT'));
            return;
        }
    }

    # Display the add device form
    $c->stash(
        sites => \@sites,
        template => 'admin/add_network_device.tt',
    );
    $c->forward($c->view('TT'));
}

=head2 edit_network_device

Admin interface to edit a network device

=cut

sub edit_network_device :Path('/admin/edit_network_device') :Auth('/admin/edit_network_device') :Args(1) {
    my ($self, $c, $device_id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_network_device', "Enter edit_network_device method for device ID: $device_id");

    # Admin role check is now handled in the begin method

    # Get list of sites for the dropdown
    my @sites = ();
    eval {
        @sites = $c->model('DBEncy::Site')->search(
            {},
            { order_by => { -asc => 'name' } }
        );
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'edit_network_device', 
            "Error fetching sites: $@");
        
        # Add sample sites if we can't get them from the database
        @sites = (
            { id => 1, name => 'CSC' },
            { id => 2, name => 'MCOOP' },
            { id => 3, name => 'BMaster' }
        );
    }

    # Try to find the device
    my $device;
    eval {
        $device = $c->model('DBEncy')->schema->resultset('NetworkDevice')->find($device_id);
    };

    # Handle errors or device not found
    if ($@ || !$device) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'edit_network_device',
            "Device not found with ID: $device_id or error: $@");
            
        $c->flash->{error_msg} = "Device not found.";
        $c->response->redirect($c->uri_for('/admin/network_devices'));
        return;
    }

    # If this is a form submission, process it
    if ($c->req->method eq 'POST') {
        # Retrieve the form data
        my $device_name = $c->req->params->{device_name};
        my $ip_address = $c->req->params->{ip_address};
        my $mac_address = $c->req->params->{mac_address};
        my $device_type = $c->req->params->{device_type};
        my $location = $c->req->params->{location};
        my $purpose = $c->req->params->{purpose};
        my $notes = $c->req->params->{notes};
        my $site_name = $c->req->params->{site_name};

        # Log the device update attempt
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_network_device',
            "Device update attempt for device: $device_name with IP: $ip_address, Site: $site_name");

        # Ensure all required fields are filled
        unless ($device_name && $ip_address && $site_name) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'edit_network_device',
                "Missing required fields for device update");

            $c->stash(
                error_msg => 'Device name, IP address, and site are required',
                device => $device,
                sites => \@sites,
                template => 'admin/edit_network_device.tt',
            );
            $c->forward($c->view('TT'));
            return;
        }

        # Update the device
        eval {
            $device->update({
                device_name => $device_name,
                ip_address => $ip_address,
                mac_address => $mac_address,
                device_type => $device_type,
                location => $location,
                purpose => $purpose,
                notes => $notes,
                site_name => $site_name,
                updated_at => \'NOW()',
            });

            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_network_device',
                "Device updated successfully: $device_name with IP: $ip_address, Site: $site_name");

            # Set success message and redirect to device list
            $c->flash->{success_msg} = "Device '$device_name' updated successfully.";
            $c->response->redirect($c->uri_for('/admin/network_devices', { site => $site_name }));
            return;
        };

        if ($@) {
            # Handle database errors
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_network_device',
                "Error updating device: $@");

            $c->stash(
                error_msg => "Error updating device: $@",
                device => $device,
                sites => \@sites,
                template => 'admin/edit_network_device.tt',
            );
            $c->forward($c->view('TT'));
            return;
        }
    }

    # Display the edit device form
    $c->stash(
        device => $device,
        sites => \@sites,
        template => 'admin/edit_network_device.tt',
    );
    $c->forward($c->view('TT'));
}

=head2 delete_network_device

Admin interface to delete a network device

=cut

sub delete_network_device :Path('/admin/delete_network_device') :Auth('/admin/delete_network_device') :Args(1) {
    my ($self, $c, $device_id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete_network_device', "Enter delete_network_device method for device ID: $device_id");

    # Admin role check is now handled in the begin method

    # Try to find the device
    my $device;
    eval {
        $device = $c->model('DBEncy')->schema->resultset('NetworkDevice')->find($device_id);
    };

    # Handle errors or device not found
    if ($@ || !$device) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'delete_network_device',
            "Device not found with ID: $device_id or error: $@");
            
        $c->flash->{error_msg} = "Device not found.";
        $c->response->redirect($c->uri_for('/admin/network_devices'));
        return;
    }

    # Store device name and site for logging and redirection
    my $device_name = $device->device_name;
    my $site_name = $device->site_name;
    
    # Delete the device
    eval {
        $device->delete;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete_network_device',
            "Device deleted successfully: $device_name (ID: $device_id)");
            
        $c->flash->{success_msg} = "Device '$device_name' deleted successfully.";
    };
    
    if ($@) {
        # Handle any exceptions
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'delete_network_device',
            "Exception when deleting device: $@");
            
        $c->flash->{error_msg} = "An error occurred while deleting the device: $@";
    }
    
    # Redirect back to the device list page with the site filter if available
    $c->response->redirect($c->uri_for('/admin/network_devices', { site => $site_name }));
}

__PACKAGE__->meta->make_immutable;
1;