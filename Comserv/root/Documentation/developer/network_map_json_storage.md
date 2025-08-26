# NetworkMap JSON Storage Pattern

**File:** /home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation/developer/network_map_json_storage.md  
**Version:** 1.0  
**Last Updated:** 2025-09-20  
**Author:** Development Team

## Overview

The NetworkMap module uses JSON file storage as an intermediate solution before implementing a full database-backed model. This document explains the pattern used and how to apply it to other modules.

## JSON Storage Implementation

### File Location

The NetworkMap module stores its data in:
```
/home/shanta/PycharmProjects/comserv2/Comserv/config/network_map.json
```

### Data Structure

The JSON file contains two main sections:
1. `networks` - A collection of network definitions
2. `devices` - A collection of device definitions

Example structure:
```json
{
  "networks": {
    "lan": {
      "name": "Local Area Network",
      "cidr": "192.168.1.0/24",
      "description": "Main office network"
    }
  },
  "devices": {
    "router1": {
      "ip": "192.168.1.1",
      "network": "lan",
      "type": "router",
      "description": "Main router",
      "services": ["DHCP", "DNS"],
      "added_date": "Fri Sep 20 14:30:45 2025"
    }
  }
}
```

### Code Implementation

The NetworkMap utility (`Comserv/lib/Comserv/Util/NetworkMap.pm`) implements:

1. **Configuration Loading**:
   ```perl
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
   ```

2. **Configuration Saving**:
   ```perl
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
   ```

3. **Data Access Methods**:
   - `get_networks()` - Returns all networks
   - `get_devices()` - Returns all devices
   - `get_device($device_name)` - Returns a specific device
   - `get_device_by_ip($ip)` - Finds a device by IP address

4. **Data Modification Methods**:
   - `add_network($network_id, $name, $cidr, $description)` - Adds a network
   - `add_device($device_name, $ip, $network, $type, $description, $services)` - Adds a device
   - `remove_device($device_name)` - Removes a device

## Controller Integration

The NetworkMap controller (`Comserv/lib/Comserv/Controller/NetworkMap.pm`) integrates with the utility:

```perl
sub index :Chained('base') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    
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
}
```

## Advantages of This Approach

1. **Rapid Development**: No need to set up database tables initially
2. **Simple Data Structure**: JSON naturally maps to Perl data structures
3. **Self-Contained**: Module works without database dependencies
4. **Easy Debugging**: JSON file can be inspected directly
5. **Transition Path**: Can be migrated to a database model later

## Future Database Migration

When migrating to a database model:

1. Create database tables for networks and devices
2. Create DBIx::Class models in `Comserv/lib/Comserv/Model/`
3. Modify the NetworkMap utility to use the database models
4. Implement a migration script to transfer data from JSON to the database

## Applying This Pattern

When implementing new features that may eventually need database storage:

1. Create a utility class in `Comserv/lib/Comserv/Util/`
2. Implement JSON file storage following the NetworkMap pattern
3. Create a controller that uses the utility
4. Document the JSON structure and planned database migration

## Best Practices

1. **Error Handling**: Always use eval blocks when reading/writing JSON
2. **Default Values**: Provide sensible defaults if the JSON file doesn't exist
3. **Logging**: Log all errors with detailed information
4. **Validation**: Validate data before saving to JSON
5. **Atomic Updates**: Ensure the JSON file is updated atomically to prevent corruption