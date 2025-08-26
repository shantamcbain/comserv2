package Comserv::Controller::NetworkMap;

use Moose;
use namespace::autoclean;
use Comserv::Util::NetworkMap;
use Comserv::Util::Logging;
use JSON;
use Data::Dumper;

BEGIN { extends 'Catalyst::Controller'; }

# Set the namespace for this controller
__PACKAGE__->config(namespace => 'NetworkMap');

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

=head1 NAME

Comserv::Controller::NetworkMap - Network Map Controller

=head1 DESCRIPTION

Controller for managing and displaying the network map.

=head1 METHODS

=head2 auto

Common setup for all NetworkMap actions

=cut

sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', 
        "NetworkMap controller auto method called");
    
    # Initialize debug_msg array if it doesn't exist
    $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
    
    # Add the debug message to the array
    push @{$c->stash->{debug_msg}}, "NetworkMap controller loaded successfully";
    
    return 1; # Allow the request to proceed
}

=head2 base

Base method for chained actions

=cut

sub base :Chained('/') :PathPart('NetworkMap') :CaptureArgs(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'base', 
        "Starting NetworkMap base action");
    
    # Common setup for all NetworkMap pages
    $c->stash(section => 'networkmap');
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'base', 
        "Completed NetworkMap base action");
}

=head2 index

Display the network map

=cut

sub index :Chained('base') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        "Starting NetworkMap index action");
    
    my $network_map = Comserv::Util::NetworkMap->new();
    
    # Get network and device information
    my $networks = $network_map->get_networks();
    my $devices = $network_map->get_devices();
    
    # Set up the template variables
    $c->stash(
        template => 'NetworkMap/index.tt',
        networks => $networks,
        devices => $devices,
        network_map_html => $network_map->format_network_map_html(),
        title => 'Network Map'
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "Network map loaded successfully";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        "Completed NetworkMap index action");
    
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
    
    if ($c->req->method eq 'POST') {
        my $device_name = $c->req->params->{device_name};
        my $ip = $c->req->params->{ip};
        my $network = $c->req->params->{network};
        my $type = $c->req->params->{type};
        my $description = $c->req->params->{description};
        my $services = $c->req->params->{services};
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_device', 
            "Processing add device form submission for device: $device_name, IP: $ip");
        
        # Split services into an array
        my @service_array = split(/\s*,\s*/, $services);
        
        # Add the device
        my $result = $network_map->add_device(
            $device_name,
            $ip,
            $network,
            $type,
            $description,
            \@service_array
        );
        
        if ($result) {
            $c->flash->{status_msg} = "Device '$device_name' added successfully.";
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_device', 
                "Device '$device_name' added successfully");
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
        template => 'NetworkMap/add_device.tt',
        networks => $networks,
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
        template => 'NetworkMap/add_network.tt',
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
        template => 'NetworkMap/view_device.tt',
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
        template => 'NetworkMap/remove_device.tt',
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

=head2 search

Search for devices by name, IP, or description

=cut

sub search :Chained('base') :PathPart('search') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'search', 
        "Starting search action");
    
    my $network_map = Comserv::Util::NetworkMap->new();
    my $query = $c->req->params->{q} || '';
    my $results = {};
    
    if ($query) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'search', 
            "Searching for devices matching query: $query");
        
        my $devices = $network_map->get_devices();
        
        foreach my $device_name (keys %$devices) {
            my $device = $devices->{$device_name};
            
            # Search in name, IP, and description
            if ($device_name =~ /$query/i || 
                $device->{ip} =~ /$query/i || 
                $device->{description} =~ /$query/i) {
                $results->{$device_name} = $device;
            }
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'search', 
            "Found " . scalar(keys %$results) . " matching devices");
    }
    
    $c->stash(
        template => 'NetworkMap/search.tt',
        query => $query,
        results => $results,
        networks => $network_map->get_networks(),
        title => 'Search Network Map'
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "Search results for query: $query";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'search', 
        "Completed search action");
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

=head2 by_network

View devices grouped by network

=cut

sub by_network :Chained('base') :PathPart('by_network') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'by_network', 
        "Starting by_network action");
    
    my $network_map = Comserv::Util::NetworkMap->new();
    my $summary = $network_map->get_network_summary();
    
    $c->stash(
        template => 'NetworkMap/by_network.tt',
        summary => $summary,
        title => 'Network Map - By Network'
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "Viewing devices grouped by network";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'by_network', 
        "Completed by_network action");
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

=head2 by_type

View devices grouped by type

=cut

sub by_type :Chained('base') :PathPart('by_type') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'by_type', 
        "Starting by_type action");
    
    my $network_map = Comserv::Util::NetworkMap->new();
    my $devices = $network_map->get_devices();
    my $networks = $network_map->get_networks();
    
    # Group devices by type
    my $types = {};
    foreach my $device_name (keys %$devices) {
        my $device = $devices->{$device_name};
        my $type = $device->{type} || 'unknown';
        
        $types->{$type} ||= {};
        $types->{$type}->{$device_name} = $device;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'by_type', 
        "Grouped devices by " . scalar(keys %$types) . " types");
    
    $c->stash(
        template => 'NetworkMap/by_type.tt',
        types => $types,
        networks => $networks,
        title => 'Network Map - By Device Type'
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "Viewing devices grouped by type";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'by_type', 
        "Completed by_type action");
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

=head2 by_service

View devices grouped by service

=cut

sub by_service :Chained('base') :PathPart('by_service') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'by_service', 
        "Starting by_service action");
    
    my $network_map = Comserv::Util::NetworkMap->new();
    my $devices = $network_map->get_devices();
    my $networks = $network_map->get_networks();
    
    # Group devices by service
    my $services = {};
    foreach my $device_name (keys %$devices) {
        my $device = $devices->{$device_name};
        
        foreach my $service (@{$device->{services}}) {
            $services->{$service} ||= {};
            $services->{$service}->{$device_name} = $device;
        }
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'by_service', 
        "Grouped devices by " . scalar(keys %$services) . " services");
    
    $c->stash(
        template => 'NetworkMap/by_service.tt',
        services => $services,
        networks => $networks,
        title => 'Network Map - By Service'
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "Viewing devices grouped by service";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'by_service', 
        "Completed by_service action");
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

=head2 default

Fallback for NetworkMap URLs that don't match any actions

=cut

sub default :Chained('base') :PathPart('') :Args {
    my ($self, $c) = @_;
    
    my $path = join('/', @{$c->req->args});
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'default', 
        "Invalid NetworkMap path: $path");
    
    # Forward to the index action
    $c->stash(
        template => 'NetworkMap/index.tt',
        error_msg => "The requested NetworkMap page was not found: $path",
        title => 'Network Map'
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "Invalid NetworkMap path: $path, forwarded to index";
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

# Make the class immutable for better performance
__PACKAGE__->meta->make_immutable;

1;