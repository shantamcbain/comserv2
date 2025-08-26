# Proxmox Integration Documentation

## Overview

The Comserv application integrates with Proxmox Virtual Environment (Proxmox VE) to provide VM management capabilities directly from the Comserv interface. This integration allows administrators to view, create, and manage virtual machines hosted on Proxmox servers.

## Command Reference Documentation

For detailed command-line operations in Proxmox VE, refer to these resources:

- [Proxmox Command Reference](../../docs/proxmox_commands.md) - Comprehensive list of CLI commands for managing all aspects of Proxmox VE
- [Proxmox IP Configuration Guide](../../docs/proxmox_ip_configuration.md) - Detailed guide for configuring IP addresses in Proxmox VE

## Architecture

The Proxmox integration consists of the following components:

1. **Proxmox Controller** (`Comserv::Controller::Proxmox`): Handles user interactions and web interface for Proxmox VM management.
2. **Proxmox Model** (`Comserv::Model::Proxmox`): Provides the API integration with Proxmox VE servers.
3. **ProxmoxCredentials Utility** (`Comserv::Util::ProxmoxCredentials`): Manages server credentials and configuration.
4. **ProxmoxServers Controller** (`Comserv::Controller::ProxmoxServers`): Manages Proxmox server configurations.
5. **Templates** (`proxmox/*.tt`): Template files for the Proxmox management interface.

## Authentication

The Proxmox integration uses API tokens for authentication with Proxmox VE servers. These tokens must be created in the Proxmox VE web interface and then configured in Comserv.

Token format: `USER@REALM!TOKENID`

Example: `root@pam!mytoken`

## Features

The Proxmox integration provides the following features:

1. **VM Management**:
   - View list of VMs on Proxmox servers
   - Create new VMs from templates
   - Start, stop, and restart VMs
   - View VM details and status

2. **Server Management**:
   - Configure multiple Proxmox servers
   - Test connections to Proxmox servers
   - Manage API tokens and credentials

3. **Template Management**:
   - Use predefined VM templates
   - Configure template sources

## Configuration

### Server Configuration

Proxmox servers are configured with the following parameters:

- **Server ID**: A unique identifier for the server
- **Host**: The hostname or IP address of the Proxmox server
- **API URL Base**: The base URL for the Proxmox API (default: `https://<host>:8006/api2/json`)
- **Node**: The Proxmox node name (default: `pve`)
- **Token User**: The API token user in the format `USER@REALM!TOKENID`
- **Token Value**: The API token value

### VM Creation Parameters

When creating a new VM, the following parameters are available:

- **Hostname**: The hostname for the new VM
- **Description**: A description of the VM
- **CPU**: Number of CPU cores
- **Memory**: Amount of memory in MB
- **Disk Size**: Size of the primary disk in GB
- **Template**: The VM template to use
- **Network Type**: DHCP or static IP
- **IP Address**: Static IP address (if using static IP)
- **Subnet Mask**: Subnet mask (if using static IP)
- **Gateway**: Default gateway (if using static IP)
- **Start After Creation**: Whether to start the VM after creation
- **Enable QEMU Agent**: Whether to enable the QEMU guest agent
- **Start on Boot**: Whether to start the VM when the Proxmox server boots

## Recent Changes

### August 2024 - Debug Message Handling Fix

Fixed an issue in the Proxmox controller where the `debug_msg` stash variable was being used inconsistently:

1. Added type checking for the `debug_msg` stash variable
2. Implemented conversion of string values to array references when needed
3. Ensured consistent handling of debug messages throughout the controller
4. Fixed potential errors when interacting with other controllers

See the [changelog](changelog/2024-08-proxmox-debug-msg-fix.md) for more details.

### July 2024 - Syntax Error Fixes

Fixed several syntax errors in the Proxmox controller file that were causing the application to fail:

1. Fixed duplicate admin role check and malformed code in the index function
2. Fixed malformed eval block with extra closing braces
3. Fixed duplicate error handling code
4. Fixed malformed stash hash with duplicate server_id key
5. Fixed malformed flash hash for templates
6. Fixed malformed server_id variable reference

See the [changelog](changelog/2024-07-proxmox-controller-fixes.md) for more details.

## Troubleshooting

### Common Issues

1. **Authentication Failures**:
   - Verify that the token format is correct: `USER@REALM!TOKENID`
   - Ensure the token has appropriate permissions in Proxmox VE
   - Check that the token value is correct and not expired

2. **Connection Issues**:
   - Verify that the Proxmox server is reachable from the Comserv server
   - Check that the API URL is correct
   - Ensure that SSL verification is properly configured

3. **VM Creation Failures**:
   - Verify that the template URL is accessible from the Proxmox server
   - Check that the Proxmox server has sufficient resources
   - Ensure that the VM parameters are valid

### Debugging

The Proxmox integration includes extensive logging to help diagnose issues:

1. **Controller Logging**: The Proxmox controller logs detailed information about user actions and API calls.
2. **Model Debugging**: The Proxmox model includes a debug_info hash with detailed information about API calls and responses.
3. **Connection Testing**: The ProxmoxServers controller includes a test_connection action that provides detailed diagnostics.

## Future Improvements

Potential improvements for the Proxmox integration:

1. **Enhanced VM Management**: Add support for more VM operations like cloning, snapshots, and backups.
2. **Improved Template Management**: Add a UI for managing VM templates.
3. **Resource Monitoring**: Add monitoring of Proxmox server resources.
4. **Batch Operations**: Add support for performing operations on multiple VMs at once.
5. **User Management**: Add integration with Proxmox user management.

## Related Files

- `/Comserv/lib/Comserv/Controller/Proxmox.pm`: Main controller for Proxmox VM management
- `/Comserv/lib/Comserv/Model/Proxmox.pm`: Model for Proxmox API integration
- `/Comserv/lib/Comserv/Util/ProxmoxCredentials.pm`: Utility for managing Proxmox credentials
- `/Comserv/lib/Comserv/Controller/ProxmoxServers.pm`: Controller for managing Proxmox server configurations
- `/Comserv/root/proxmox/*.tt`: Template files for the Proxmox management interface