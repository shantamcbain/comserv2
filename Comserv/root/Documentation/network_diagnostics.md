# Network Diagnostics Tool

## Overview

The Network Diagnostics Tool provides administrators with a set of utilities to diagnose and resolve network connectivity issues between servers in the Comserv environment. This tool is particularly useful when troubleshooting connection problems with production servers.

## Features

1. **Ping Test**: Verify basic connectivity to remote hosts
2. **DNS Lookup**: Check DNS resolution for hostnames
3. **Hosts File Management**: Add entries to the local hosts file
4. **System Information**: View local network configuration

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

## Related Documentation

- [Logging Best Practices](/Documentation/logging_best_practices)
- [Restart Starman Server](/Documentation/restart_starman)
- [Server Configuration](/Documentation/server_configuration)
- [Troubleshooting Guide](/Documentation/troubleshooting_guide)