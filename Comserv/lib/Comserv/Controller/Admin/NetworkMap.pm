package Comserv::Controller::Admin::NetworkMap;

use Moose;
use namespace::autoclean;
use Comserv::Util::NetworkMap;
use Comserv::Util::Logging;
use JSON;
use Try::Tiny;

BEGIN { extends 'Catalyst::Controller'; }

# Set the namespace for this controller
__PACKAGE__->config(namespace => 'admin/NetworkMap');

# Returns an instance of the logging utility
sub logging {
    my ($self) = @_;
    return Comserv::Util::Logging->instance();
}

=head1 NAME

Comserv::Controller::Admin::NetworkMap - Admin Network Map Controller

=head1 DESCRIPTION

Controller for managing and displaying the network map in the admin interface.
This controller combines functionality from both the NetworkMap and NetworkDevices
controllers, using JSON storage with a path to future database migration.

=head1 METHODS

=head2 auto

Common setup for all NetworkMap actions

=cut

sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', 
        "Admin::NetworkMap controller auto method called");
    
    # Check if the user has admin role
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto', 
            "User does not have admin role");
        $c->response->redirect($c->uri_for('/'));
        return 0;
    }
    
    # Initialize debug_msg array if it doesn't exist
    $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
    
    # Add the debug message to the array
    push @{$c->stash->{debug_msg}}, "Admin::NetworkMap controller loaded successfully";
    
    return 1; # Allow the request to proceed
}

=head2 base

Base method for chained actions

=cut

sub base :Chained('/') :PathPart('admin/NetworkMap') :CaptureArgs(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'base', 
        "Starting Admin::NetworkMap base action");
    
    # Common setup for all NetworkMap pages
    $c->stash(section => 'networkmap');
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'base', 
        "Completed Admin::NetworkMap base action");
}

=head2 index

Display the network map admin interface

=cut

sub index :Chained('base') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        "Starting Admin::NetworkMap index action");
    
    my $network_map = Comserv::Util::NetworkMap->new();
    
    # Get the selected site filter (if any)
    my $site_filter = $c->req->param('site') || '';
    
    # Get network and device information
    my $networks = $network_map->get_networks();
    my $devices = $network_map->get_devices();
    
    # Filter devices by site if needed
    if ($site_filter) {
        my $filtered_devices = {};
        foreach my $device_name (keys %$devices) {
            if ($devices->{$device_name}->{site_name} eq $site_filter) {
                $filtered_devices->{$device_name} = $devices->{$device_name};
            }
        }
        $devices = $filtered_devices;
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
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'index', 
            "Error fetching sites: $@");
        
        # Extract unique site names from devices
        my %site_names = ();
        foreach my $device_name (keys %{$network_map->get_devices()}) {
            my $device = $network_map->get_device($device_name);
            $site_names{$device->{site_name}} = 1 if $device->{site_name};
        }
        
        @sites = map { { name => $_ } } sort keys %site_names;
        
        # Add default sites if none found
        if (!@sites) {
            @sites = (
                { name => 'CSC' },
                { name => 'MCOOP' },
                { name => 'BMaster' }
            );
        }
    }
    
    # Set up the template variables
    $c->stash(
        template => 'admin/NetworkMap/index.tt',
        networks => $networks,
        devices => $devices,
        sites => \@sites,
        site_filter => $site_filter,
        network_map_html => $network_map->format_network_map_html(),
        title => 'Network Map Administration'
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "Network map loaded successfully";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        "Completed Admin::NetworkMap index action");
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

=head2 add_device

Add a new device to the network map

=cut

sub add_device :Chained('base') :PathPart('add_device') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_device', 
        "Starting add_device action");
    
    my $network_map = Comserv::Util::NetworkMap->new();
    my $networks = $network_map->get_networks();
    
    # Get list of sites for the dropdown
    my @sites = ();
    eval {
        @sites = $c->model('DBEncy::Site')->search(
            {},
            { order_by => { -asc => 'name' } }
        );
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'add_device', 
            "Error fetching sites: $@");
        
        # Extract unique site names from devices
        my %site_names = ();
        foreach my $device_name (keys %{$network_map->get_devices()}) {
            my $device = $network_map->get_device($device_name);
            $site_names{$device->{site_name}} = 1 if $device->{site_name};
        }
        
        @sites = map { { name => $_ } } sort keys %site_names;
        
        # Add default sites if none found
        if (!@sites) {
            @sites = (
                { name => 'CSC' },
                { name => 'MCOOP' },
                { name => 'BMaster' }
            );
        }
    }
    
    if ($c->req->method eq 'POST') {
        my $device_name = $c->req->params->{device_name};
        my $ip = $c->req->params->{ip_address};
        my $mac = $c->req->params->{mac_address};
        my $network = $c->req->params->{network};
        my $type = $c->req->params->{device_type};
        my $location = $c->req->params->{location};
        my $purpose = $c->req->params->{purpose};
        my $notes = $c->req->params->{notes};
        my $site_name = $c->req->params->{site_name};
        my $services = $c->req->params->{services};
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_device', 
            "Processing add device form submission for device: $device_name, IP: $ip");
        
        # Split services into an array
        my @service_array = split(/\s*,\s*/, $services);
        
        # Add the device
        my $result = $network_map->add_device(
            $device_name,
            $ip,
            $mac,
            $network,
            $type,
            $location,
            $purpose,
            $notes,
            $site_name,
            \@service_array
        );
        
        if ($result) {
            $c->flash->{status_msg} = "Device '$device_name' added successfully.";
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_device', 
                "Device '$device_name' added successfully");
                
            # Try to add to database if it exists
            try {
                my $db_device = $network_map->get_device_for_db($device_name);
                $c->model('DBEncy')->schema->resultset('NetworkDevice')->create({
                    device_name => $device_name,
                    ip_address => $ip,
                    mac_address => $mac,
                    device_type => $type,
                    location => $location,
                    purpose => $purpose,
                    notes => $notes,
                    site_name => $site_name,
                    network_id => $network,
                    services => $services,
                    created_at => \'NOW()',
                });
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_device', 
                    "Device '$device_name' also added to database");
            } catch {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'add_device', 
                    "Could not add device to database: $_. Using JSON storage only.");
            };
        } else {
            $c->flash->{error_msg} = "Failed to add device. Please check the logs.";
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_device', 
                "Failed to add device '$device_name'");
        }
        
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    # Display the add device form
    $c->stash(
        template => 'admin/NetworkMap/add_device.tt',
        networks => $networks,
        sites => \@sites,
        title => 'Add Device to Network Map'
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "Add device form loaded";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_device', 
        "Completed add_device action");
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

=head2 add_network

Add a new network to the map

=cut

sub add_network :Chained('base') :PathPart('add_network') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_network', 
        "Starting add_network action");
    
    my $network_map = Comserv::Util::NetworkMap->new();
    
    if ($c->req->method eq 'POST') {
        my $network_id = $c->req->params->{network_id};
        my $name = $c->req->params->{name};
        my $cidr = $c->req->params->{cidr};
        my $description = $c->req->params->{description};
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_network', 
            "Processing add network form submission for network: $name, CIDR: $cidr");
        
        # Add the network
        my $result = $network_map->add_network(
            $network_id,
            $name,
            $cidr,
            $description
        );
        
        if ($result) {
            $c->flash->{status_msg} = "Network '$name' added successfully.";
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_network', 
                "Network '$name' added successfully");
        } else {
            $c->flash->{error_msg} = "Failed to add network. Please check the logs.";
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_network', 
                "Failed to add network '$name'");
        }
        
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    # Display the add network form
    $c->stash(
        template => 'admin/NetworkMap/add_network.tt',
        title => 'Add Network to Network Map'
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "Add network form loaded";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_network', 
        "Completed add_network action");
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

=head2 view_device

View details of a specific device

=cut

sub view_device :Chained('base') :PathPart('view_device') :Args(1) {
    my ($self, $c, $device_name) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view_device', 
        "Starting view_device action for device: $device_name");
    
    my $network_map = Comserv::Util::NetworkMap->new();
    my $device = $network_map->get_device($device_name);
    
    if (!$device) {
        $c->flash->{error_msg} = "Device not found.";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'view_device', 
            "Device not found: $device_name");
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    my $networks = $network_map->get_networks();
    my $network_name = $networks->{$device->{network}}->{name} || 'Unknown';
    
    $c->stash(
        template => 'admin/NetworkMap/view_device.tt',
        device_name => $device_name,
        device => $device,
        network_name => $network_name,
        title => "Device Details: $device_name"
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "Viewing device: $device_name";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view_device', 
        "Completed view_device action for device: $device_name");
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

=head2 edit_device

Edit a device in the network map

=cut

sub edit_device :Chained('base') :PathPart('edit_device') :Args(1) {
    my ($self, $c, $device_name) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_device', 
        "Starting edit_device action for device: $device_name");
    
    my $network_map = Comserv::Util::NetworkMap->new();
    my $device = $network_map->get_device($device_name);
    
    if (!$device) {
        $c->flash->{error_msg} = "Device not found.";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_device', 
            "Device not found: $device_name");
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    my $networks = $network_map->get_networks();
    
    # Get list of sites for the dropdown
    my @sites = ();
    eval {
        @sites = $c->model('DBEncy::Site')->search(
            {},
            { order_by => { -asc => 'name' } }
        );
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'edit_device', 
            "Error fetching sites: $@");
        
        # Extract unique site names from devices
        my %site_names = ();
        foreach my $dev_name (keys %{$network_map->get_devices()}) {
            my $dev = $network_map->get_device($dev_name);
            $site_names{$dev->{site_name}} = 1 if $dev->{site_name};
        }
        
        @sites = map { { name => $_ } } sort keys %site_names;
        
        # Add default sites if none found
        if (!@sites) {
            @sites = (
                { name => 'CSC' },
                { name => 'MCOOP' },
                { name => 'BMaster' }
            );
        }
    }
    
    if ($c->req->method eq 'POST') {
        my $new_device_name = $c->req->params->{device_name};
        my $ip = $c->req->params->{ip_address};
        my $mac = $c->req->params->{mac_address};
        my $network = $c->req->params->{network};
        my $type = $c->req->params->{device_type};
        my $location = $c->req->params->{location};
        my $purpose = $c->req->params->{purpose};
        my $notes = $c->req->params->{notes};
        my $site_name = $c->req->params->{site_name};
        my $services = $c->req->params->{services};
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_device', 
            "Processing edit device form submission for device: $device_name");
        
        # Remove the old device
        $network_map->remove_device($device_name);
        
        # Split services into an array
        my @service_array = split(/\s*,\s*/, $services);
        
        # Add the updated device
        my $result = $network_map->add_device(
            $new_device_name,
            $ip,
            $mac,
            $network,
            $type,
            $location,
            $purpose,
            $notes,
            $site_name,
            \@service_array
        );
        
        if ($result) {
            $c->flash->{status_msg} = "Device '$new_device_name' updated successfully.";
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_device', 
                "Device '$device_name' updated successfully to '$new_device_name'");
                
            # Try to update in database if it exists
            try {
                # Try to find device by name
                my $db_device = $c->model('DBEncy')->schema->resultset('NetworkDevice')->find({ device_name => $device_name });
                
                if ($db_device) {
                    $db_device->update({
                        device_name => $new_device_name,
                        ip_address => $ip,
                        mac_address => $mac,
                        device_type => $type,
                        location => $location,
                        purpose => $purpose,
                        notes => $notes,
                        site_name => $site_name,
                        network_id => $network,
                        services => $services,
                        updated_at => \'NOW()'
                    });
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_device', 
                        "Device '$device_name' also updated in database");
                }
            } catch {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'edit_device', 
                    "Could not update device in database: $_. Using JSON storage only.");
            };
        } else {
            $c->flash->{error_msg} = "Failed to update device. Please check the logs.";
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_device', 
                "Failed to update device '$device_name'");
        }
        
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    # Format services for display
    my $services_text = join(', ', @{$device->{services}});
    
    # Display the edit device form
    $c->stash(
        template => 'admin/NetworkMap/edit_device.tt',
        device_name => $device_name,
        device => $device,
        networks => $networks,
        sites => \@sites,
        services_text => $services_text,
        title => "Edit Device: $device_name"
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "Edit device form for: $device_name";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_device', 
        "Completed edit_device action for device: $device_name");
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

=head2 remove_device

Remove a device from the network map

=cut

sub remove_device :Chained('base') :PathPart('remove_device') :Args(1) {
    my ($self, $c, $device_name) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'remove_device', 
        "Starting remove_device action for device: $device_name");
    
    my $network_map = Comserv::Util::NetworkMap->new();
    
    if ($c->req->method eq 'POST') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'remove_device', 
            "Processing remove device form submission for device: $device_name");
        
        my $result = $network_map->remove_device($device_name);
        
        if ($result) {
            $c->flash->{status_msg} = "Device '$device_name' removed successfully.";
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'remove_device', 
                "Device '$device_name' removed successfully");
                
            # Try to remove from database if it exists
            try {
                my $db_device = $c->model('DBEncy')->schema->resultset('NetworkDevice')->find({ device_name => $device_name });
                if ($db_device) {
                    $db_device->delete();
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'remove_device', 
                        "Device '$device_name' also removed from database");
                }
            } catch {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'remove_device', 
                    "Could not remove device from database: $_. Removed from JSON storage only.");
            };
        } else {
            $c->flash->{error_msg} = "Failed to remove device. Please check the logs.";
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'remove_device', 
                "Failed to remove device '$device_name'");
        }
        
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    my $device = $network_map->get_device($device_name);
    
    if (!$device) {
        $c->flash->{error_msg} = "Device not found.";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'remove_device', 
            "Device not found: $device_name");
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    $c->stash(
        template => 'admin/NetworkMap/remove_device.tt',
        device_name => $device_name,
        device => $device,
        title => "Remove Device: $device_name"
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "Remove device form for: $device_name";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'remove_device', 
        "Completed remove_device action for device: $device_name");
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

=head2 export_json

Export the network map as JSON

=cut

sub export_json :Chained('base') :PathPart('export_json') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'export_json', 
        "Starting export_json action");
    
    my $network_map = Comserv::Util::NetworkMap->new();
    my $data = {
        networks => $network_map->get_networks(),
        devices => $network_map->get_devices(),
    };
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'export_json', 
        "Exporting network map as JSON");
    
    $c->response->content_type('application/json');
    $c->response->body(JSON->new->pretty->encode($data));
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'export_json', 
        "Completed export_json action");
}

=head2 export_text

Export the network map as plain text

=cut

sub export_text :Chained('base') :PathPart('export_text') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'export_text', 
        "Starting export_text action");
    
    my $network_map = Comserv::Util::NetworkMap->new();
    my $text = $network_map->format_network_map_text();
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'export_text', 
        "Exporting network map as text");
    
    $c->response->content_type('text/plain');
    $c->response->body($text);
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'export_text', 
        "Completed export_text action");
}

=head2 sync_with_db

Synchronize JSON storage with database

=cut

sub sync_with_db :Chained('base') :PathPart('sync_with_db') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_with_db', 
        "Starting sync_with_db action");
    
    my $network_map = Comserv::Util::NetworkMap->new();
    my $direction = $c->req->params->{direction} || 'to_db';
    my $result = 0;
    
    try {
        if ($direction eq 'to_db') {
            # Export from JSON to database
            $result = $network_map->export_to_db($c->model('DBEncy')->schema);
            if ($result) {
                $c->flash->{status_msg} = "Successfully exported network map to database.";
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_with_db', 
                    "Successfully exported network map to database");
            } else {
                $c->flash->{error_msg} = "Failed to export network map to database.";
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'sync_with_db', 
                    "Failed to export network map to database");
            }
        } else {
            # Import from database to JSON
            $result = $network_map->import_from_db($c->model('DBEncy')->schema);
            if ($result) {
                $c->flash->{status_msg} = "Successfully imported network map from database.";
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_with_db', 
                    "Successfully imported network map from database");
            } else {
                $c->flash->{error_msg} = "Failed to import network map from database.";
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'sync_with_db', 
                    "Failed to import network map from database");
            }
        }
    } catch {
        $c->flash->{error_msg} = "Error during synchronization: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'sync_with_db', 
            "Error during synchronization: $_");
    };
    
    $c->response->redirect($c->uri_for($self->action_for('index')));
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_with_db', 
        "Completed sync_with_db action");
}

# Make the class immutable for better performance
__PACKAGE__->meta->make_immutable;

1;