package Comserv::Util::NetworkMap;

use Moose;
use namespace::autoclean;
use JSON;
use File::Slurp;
use Net::CIDR;
use Comserv::Util::Logging;
use Data::Dumper;
use Try::Tiny;

# Create a singleton instance of the logging utility
has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# Configuration file path
has '_config_file' => (
    is => 'ro',
    default => '/home/shanta/PycharmProjects/comserv2/Comserv/config/network_map.json'
);

=head1 NAME

Comserv::Util::NetworkMap - Network mapping and IP address management

=head1 DESCRIPTION

This module provides functions for managing a network map, including
tracking IP addresses, their purposes, and network information.

This utility uses JSON storage for prototyping and can be migrated to a 
database model in the future. It follows the JSON storage pattern described
in the network_map_json_storage.md documentation.

=head1 METHODS

=head2 _config

Configuration data attribute

=cut

has '_config' => (
    is => 'rw',
    lazy => 1,
    builder => '_load_config'
);

# Database connection for future use
has 'schema' => (
    is => 'ro',
    lazy => 1,
    default => sub {
        my ($self) = @_;
        # This will be used when we migrate to database storage
        return undef;
    }
);

=head2 _load_config

Internal method to load the network map configuration

=cut

sub _load_config {
    my ($self) = @_;
    my $config = {};
    
    eval {
        if (-e $self->_config_file) {
            my $json_text = read_file($self->_config_file);
            $config = decode_json($json_text);
        }
    };
    
    if ($@) {
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_load_config', "Error loading network map config: $@");
        $config = { networks => {}, devices => {} };
    }
    
    return $config;
}

=head2 _save_config

Internal method to save the network map configuration

=cut

sub _save_config {
    my ($self) = @_;
    
    eval {
        my $json_text = JSON->new->pretty->encode($self->_config);
        write_file($self->_config_file, $json_text);
    };
    
    if ($@) {
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_save_config', "Error saving network map config: $@");
        return 0;
    }
    
    return 1;
}

=head2 get_networks

Returns a list of all networks

=cut

sub get_networks {
    my ($self) = @_;
    return $self->_config->{networks} || {};
}

=head2 get_devices

Returns a list of all devices

=cut

sub get_devices {
    my ($self) = @_;
    return $self->_config->{devices} || {};
}

=head2 get_device

Returns a specific device by name

=cut

sub get_device {
    my ($self, $device_name) = @_;
    return $self->_config->{devices}->{$device_name};
}

=head2 get_device_by_ip

Returns a device by its IP address

=cut

sub get_device_by_ip {
    my ($self, $ip) = @_;
    
    foreach my $device_name (keys %{$self->_config->{devices}}) {
        my $device = $self->_config->{devices}->{$device_name};
        if ($device->{ip} eq $ip) {
            return {
                name => $device_name,
                %$device
            };
        }
    }
    
    return undef;
}

=head2 add_network

Adds a new network to the map

=cut

sub add_network {
    my ($self, $network_id, $name, $cidr, $description) = @_;
    
    # Validate CIDR format
    eval {
        Net::CIDR::cidr2range($cidr);
    };
    if ($@) {
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'add_network', "Invalid CIDR format: $cidr");
        return 0;
    }
    
    $self->_config->{networks}->{$network_id} = {
        name => $name,
        cidr => $cidr,
        description => $description
    };
    
    return $self->_save_config();
}

=head2 add_device

Adds a new device to the map

=cut

sub add_device {
    my ($self, $device_name, $ip, $mac, $network, $type, $location, $purpose, $notes, $site_name, $services) = @_;
    
    # Check if network exists
    if ($network && !exists $self->_config->{networks}->{$network}) {
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'add_device', "Network does not exist: $network");
        return 0;
    }
    
    # Check if IP is already in use
    foreach my $existing_device (keys %{$self->_config->{devices}}) {
        if ($self->_config->{devices}->{$existing_device}->{ip} eq $ip && $existing_device ne $device_name) {
            $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'add_device', "IP address already in use: $ip");
            return 0;
        }
    }
    
    # Add or update the device
    $self->_config->{devices}->{$device_name} = {
        ip => $ip,
        mac => $mac || '',
        network => $network,
        type => $type,
        location => $location || '',
        purpose => $purpose || '',
        notes => $notes || '',
        site_name => $site_name || 'Default',
        services => $services || [],
        added_date => scalar(localtime)
    };
    
    return $self->_save_config();
}

=head2 remove_device

Removes a device from the map

=cut

sub remove_device {
    my ($self, $device_name) = @_;
    
    if (exists $self->_config->{devices}->{$device_name}) {
        delete $self->_config->{devices}->{$device_name};
        return $self->_save_config();
    }
    
    return 0;
}

=head2 get_devices_by_network

Returns all devices in a specific network

=cut

sub get_devices_by_network {
    my ($self, $network_id) = @_;
    my $devices = {};
    
    foreach my $device_name (keys %{$self->_config->{devices}}) {
        my $device = $self->_config->{devices}->{$device_name};
        if ($device->{network} eq $network_id) {
            $devices->{$device_name} = $device;
        }
    }
    
    return $devices;
}

=head2 get_devices_by_type

Returns all devices of a specific type

=cut

sub get_devices_by_type {
    my ($self, $type) = @_;
    my $devices = {};
    
    foreach my $device_name (keys %{$self->_config->{devices}}) {
        my $device = $self->_config->{devices}->{$device_name};
        if ($device->{type} eq $type) {
            $devices->{$device_name} = $device;
        }
    }
    
    return $devices;
}

=head2 get_devices_by_service

Returns all devices providing a specific service

=cut

sub get_devices_by_service {
    my ($self, $service) = @_;
    my $devices = {};
    
    foreach my $device_name (keys %{$self->_config->{devices}}) {
        my $device = $self->_config->{devices}->{$device_name};
        if (grep { $_ eq $service } @{$device->{services}}) {
            $devices->{$device_name} = $device;
        }
    }
    
    return $devices;
}

=head2 get_network_summary

Returns a summary of all networks and their devices

=cut

sub get_network_summary {
    my ($self) = @_;
    my $summary = {};
    
    foreach my $network_id (keys %{$self->_config->{networks}}) {
        my $network = $self->_config->{networks}->{$network_id};
        my $devices = $self->get_devices_by_network($network_id);
        
        $summary->{$network_id} = {
            name => $network->{name},
            cidr => $network->{cidr},
            description => $network->{description},
            device_count => scalar(keys %$devices),
            devices => $devices
        };
    }
    
    return $summary;
}

=head2 format_network_map_html

Returns an HTML representation of the network map

=cut

sub format_network_map_html {
    my ($self) = @_;
    my $html = '';
    
    $html .= '<div class="network-map">';
    
    # Networks section
    $html .= '<h2>Networks</h2>';
    $html .= '<table class="network-table">';
    $html .= '<tr><th>Network</th><th>CIDR</th><th>Description</th><th>Device Count</th></tr>';
    
    foreach my $network_id (sort keys %{$self->_config->{networks}}) {
        my $network = $self->_config->{networks}->{$network_id};
        my $devices = $self->get_devices_by_network($network_id);
        my $device_count = scalar(keys %$devices);
        
        $html .= "<tr>";
        $html .= "<td>$network->{name}</td>";
        $html .= "<td>$network->{cidr}</td>";
        $html .= "<td>$network->{description}</td>";
        $html .= "<td>$device_count</td>";
        $html .= "</tr>";
    }
    
    $html .= '</table>';
    
    # Devices section
    $html .= '<h2>Devices</h2>';
    $html .= '<table class="device-table">';
    $html .= '<tr><th>Name</th><th>IP Address</th><th>Network</th><th>Type</th><th>Description</th><th>Services</th></tr>';
    
    foreach my $device_name (sort keys %{$self->_config->{devices}}) {
        my $device = $self->_config->{devices}->{$device_name};
        my $network_name = $self->_config->{networks}->{$device->{network}}->{name} || 'Unknown';
        my $services = join(', ', @{$device->{services}});
        
        $html .= "<tr>";
        $html .= "<td>$device_name</td>";
        $html .= "<td>$device->{ip}</td>";
        $html .= "<td>$network_name</td>";
        $html .= "<td>$device->{type}</td>";
        $html .= "<td>$device->{description}</td>";
        $html .= "<td>$services</td>";
        $html .= "</tr>";
    }
    
    $html .= '</table>';
    $html .= '</div>';
    
    return $html;
}

=head2 format_network_map_text

Returns a text representation of the network map

=cut

sub format_network_map_text {
    my ($self) = @_;
    my $text = '';
    
    $text .= "NETWORK MAP\n";
    $text .= "===========\n\n";
    
    # Networks section
    $text .= "NETWORKS:\n";
    $text .= "---------\n";
    
    foreach my $network_id (sort keys %{$self->_config->{networks}}) {
        my $network = $self->_config->{networks}->{$network_id};
        my $devices = $self->get_devices_by_network($network_id);
        my $device_count = scalar(keys %$devices);
        
        $text .= "$network->{name} ($network->{cidr})\n";
        $text .= "  Description: $network->{description}\n";
        $text .= "  Devices: $device_count\n\n";
    }
    
    # Devices section
    $text .= "DEVICES:\n";
    $text .= "--------\n";
    
    foreach my $device_name (sort keys %{$self->_config->{devices}}) {
        my $device = $self->_config->{devices}->{$device_name};
        my $network_name = $self->_config->{networks}->{$device->{network}}->{name} || 'Unknown';
        my $services = join(', ', @{$device->{services}});
        
        $text .= "$device_name ($device->{ip})\n";
        $text .= "  Network: $network_name\n";
        $text .= "  Type: $device->{type}\n";
        $text .= "  Description: $device->{description}\n";
        $text .= "  Services: $services\n";
        $text .= "  Added: $device->{added_date}\n\n";
    }
    
    return $text;
}

=head2 get_device_for_db

Converts a device from JSON format to database format

=cut

sub get_device_for_db {
    my ($self, $device_name) = @_;
    
    my $device = $self->get_device($device_name);
    return unless $device;
    
    return {
        device_name => $device_name,
        ip_address => $device->{ip},
        mac_address => $device->{mac},
        device_type => $device->{type},
        location => $device->{location},
        purpose => $device->{purpose},
        notes => $device->{notes},
        site_name => $device->{site_name},
        created_at => $device->{added_date},
        updated_at => scalar(localtime)
    };
}

=head2 get_all_devices_for_db

Returns all devices in database format

=cut

sub get_all_devices_for_db {
    my ($self) = @_;
    my @devices = ();
    
    foreach my $device_name (keys %{$self->_config->{devices}}) {
        push @devices, {
            device_name => $device_name,
            %{$self->get_device_for_db($device_name)}
        };
    }
    
    return \@devices;
}

=head2 import_from_db

Imports devices from the database into JSON storage

=cut

sub import_from_db {
    my ($self, $schema) = @_;
    
    return 0 unless $schema;
    
    try {
        my @db_devices = $schema->resultset('NetworkDevice')->search({});
        
        foreach my $db_device (@db_devices) {
            my $device_name = $db_device->device_name;
            my $network_id = lc(substr($db_device->site_name, 0, 3)) . '_net';
            
            # Add network if it doesn't exist
            unless (exists $self->_config->{networks}->{$network_id}) {
                $self->add_network(
                    $network_id,
                    $db_device->site_name . ' Network',
                    '192.168.0.0/24', # Default CIDR
                    'Network for ' . $db_device->site_name
                );
            }
            
            # Add the device
            $self->_config->{devices}->{$device_name} = {
                ip => $db_device->ip_address,
                mac => $db_device->mac_address || '',
                network => $network_id,
                type => $db_device->device_type || 'Unknown',
                location => $db_device->location || '',
                purpose => $db_device->purpose || '',
                notes => $db_device->notes || '',
                site_name => $db_device->site_name,
                services => [],
                added_date => $db_device->created_at ? $db_device->created_at->strftime('%a %b %d %H:%M:%S %Y') : scalar(localtime)
            };
        }
        
        return $self->_save_config();
    } catch {
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'import_from_db', "Error importing from database: $_");
        return 0;
    };
}

=head2 export_to_db

Exports devices from JSON storage to the database

=cut

sub export_to_db {
    my ($self, $schema) = @_;
    
    return 0 unless $schema;
    
    try {
        my $devices = $self->get_devices();
        
        foreach my $device_name (keys %$devices) {
            my $device = $devices->{$device_name};
            
            # Check if device exists in DB
            my $db_device = $schema->resultset('NetworkDevice')->find({ device_name => $device_name });
            
            if ($db_device) {
                # Update existing device
                $db_device->update({
                    ip_address => $device->{ip},
                    mac_address => $device->{mac},
                    device_type => $device->{type},
                    location => $device->{location},
                    purpose => $device->{purpose},
                    notes => $device->{notes},
                    site_name => $device->{site_name},
                    updated_at => \'NOW()'
                });
            } else {
                # Create new device
                $schema->resultset('NetworkDevice')->create({
                    device_name => $device_name,
                    ip_address => $device->{ip},
                    mac_address => $device->{mac},
                    device_type => $device->{type},
                    location => $device->{location},
                    purpose => $device->{purpose},
                    notes => $device->{notes},
                    site_name => $device->{site_name},
                    created_at => \'NOW()',
                    updated_at => \'NOW()'
                });
            }
        }
        
        return 1;
    } catch {
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'export_to_db', "Error exporting to database: $_");
        return 0;
    };
}

# Make the class immutable for better performance
__PACKAGE__->meta->make_immutable;

1;