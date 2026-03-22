# Network Diagnostics Tool

## Overview

The Network Diagnostics Tool provides administrators with a comprehensive view of the server environment, including network connectivity, system information, and virtualization details. This tool is designed to help administrators manage servers and VMs in the server room, ensuring new VMs can be created without interfering with existing systems.

## Features

1. **Network Map Integration**: View and manage network devices and networks
2. **Ping Test**: Verify basic connectivity to remote hosts
3. **DNS Lookup**: Check DNS resolution for hostnames
4. **Hosts File Management**: Add entries to the local hosts file with network validation
5. **Basic System Information**: View local network configuration
6. **Detailed System Information**: View comprehensive system and network details
7. **VM & Container Information**: View details about virtual machines, Docker containers, and Kubernetes resources

## Access

The Network Diagnostics Tool is available to administrators through:

1. The Admin Dashboard: `/admin` → Network Diagnostics
2. Direct URL: `/admin/network_diagnostics`
3. From the Restart Starman page: `/admin/restart_starman`

## Common Use Cases

### Troubleshooting Production Server Connectivity

If you're unable to connect to a production server (e.g., comservproduction1), you can:

1. Ping the server to check basic connectivity
2. Perform a DNS lookup to verify name resolution
3. Add an entry to your hosts file if DNS resolution fails

### Adding a Hosts File Entry

To add an entry to your hosts file:

1. Navigate to `/admin/network_diagnostics`
2. Scroll to the "Add Hosts File Entry" section
3. Enter the IP address (e.g., 192.168.1.126)
4. Enter the hostname (e.g., comservproduction1)
5. Enter your sudo password
6. Click "Add Hosts Entry"

### Verifying DNS Resolution

To check if a hostname resolves correctly:

1. Navigate to `/admin/network_diagnostics`
2. Use the "DNS Lookup (dig)" tool
3. Enter the hostname to check
4. Review the results in the "ANSWER SECTION"

### Viewing Detailed System Information

To view comprehensive system information:

1. Navigate to `/admin/network_diagnostics`
2. Click the "Detailed System Info" button in the quick navigation bar
3. Review the various sections including:
   - Basic System Information (hostname, kernel, OS)
   - Resource Usage (disk, memory)
   - Network Configuration (IP, routing, DNS)
   - Network Status (connections, hosts file)

### Viewing VM and Container Information

To view information about virtual machines and containers:

1. Navigate to `/admin/network_diagnostics`
2. Click the "VM & Container Info" button in the quick navigation bar
3. Review the various sections including:
   - Network Map Overview (networks and devices)
   - Virtual Machine Status (KVM/QEMU VMs)
   - Docker Containers and Images
   - Kubernetes Nodes, Pods, and Services

### Working with Network Map Data

The Network Diagnostics Tool integrates with the NetworkMap JSON storage:

1. View networks and devices in the Network Map section
2. When adding hosts file entries, select the appropriate network
3. The system will warn you if an IP or hostname already exists in the network map

## Implementation Details

### Templates

The Network Diagnostics Tool uses the following templates:

- `admin/network_diagnostics.tt` - Main diagnostics dashboard
- `admin/network_diagnostics_system_info.tt` - Detailed system information
- `admin/network_diagnostics_vm_info.tt` - VM and container information
- `admin/error.tt` - Error display for unauthorized access

### CSS

Styles for the Network Diagnostics Tool are defined in:

- `/static/css/admin.css` - Admin-specific styles including network diagnostics

### Controller

The main controller is `Comserv::Controller::Admin::NetworkDiagnostics` with these key methods:

- `index` - Main dashboard display
- `ping_host` - Ping a remote host
- `dig_host` - Perform DNS lookup
- `add_hosts_entry` - Add entry to hosts file
- `system_info` - Display detailed system information
- `vm_info` - Display VM and container information
- `_load_network_map` - Helper to load network map data from JSON

## Logging

The Network Diagnostics Tool uses comprehensive logging to track all operations:

```perl
$self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'method_name',
    "Detailed message with relevant information");
```

All network diagnostic operations are logged to the application log with appropriate context.

## Security Considerations

- Only administrators can access the Network Diagnostics Tool
- Sudo password is required for operations that modify system files
- Input validation is performed to prevent command injection
- Passwords are never logged or stored
- Command execution is done safely to prevent shell injection

## Related Documentation

- [Logging Best Practices](/Documentation/logging_best_practices)
- [Restart Starman Server](/Documentation/restart_starman)
- [Server Configuration](/Documentation/server_configuration)
- [Troubleshooting Guide](/Documentation/troubleshooting_guide)