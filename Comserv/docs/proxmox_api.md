# Proxmox VE API Documentation

This document provides an overview of the Proxmox VE (Virtual Environment) API endpoints used in the Comserv application. The Proxmox VE API is a RESTful API that provides a wide range of endpoints for managing virtual machines, containers, nodes, storage, and more.

## API Base URL

The Proxmox VE API is accessible via HTTPS on port 8006:

```
https://<proxmox-host>:8006/api2/json
```

All endpoints return JSON by default unless specified otherwise.

## Authentication

### Using API Tokens (Recommended)

API tokens are the recommended authentication method for automated access. They don't require CSRF tokens for write operations.

```
Authorization: PVEAPIToken=USER@REALM!TOKENID=UUID
```

Example in our application:
```perl
my $token = "PVEAPIToken=" . $self->{token_user} . "=" . $self->{token_value};
$req->header('Authorization' => $token);
```

### Using Username/Password

Alternatively, you can authenticate with username and password to obtain a ticket and CSRF prevention token.

```
GET /api2/json/access/ticket
POST /api2/json/access/ticket
```

Parameters: 
- username (e.g., root@pam)
- password

Returns: 
- Ticket (for Cookie header)
- CSRFPreventionToken

## Key API Endpoints

### Cluster Management

```
GET /api2/json/cluster/status
```
Get the status of the cluster (nodes, quorum, etc.).

```
GET /api2/json/cluster/resources?type=vm
```
List all resources in the cluster, filtered by type (e.g., vm for VMs only).

### Node Management

```
GET /api2/json/nodes
```
List all nodes in the cluster.

```
GET /api2/json/nodes/{node}/status
```
Get the status of a specific node (e.g., CPU, memory usage).

### Virtual Machines (QEMU/KVM)

```
GET /api2/json/nodes/{node}/qemu
```
List all QEMU VMs on a specific node.

```
GET /api2/json/nodes/{node}/qemu/{vmid}/status/current
```
Get the current status of a specific VM.

```
POST /api2/json/nodes/{node}/qemu/{vmid}/status/start
```
Start a VM.

```
POST /api2/json/nodes/{node}/qemu/{vmid}/status/stop
```
Stop a VM.

```
POST /api2/json/nodes/{node}/qemu/{vmid}/status/shutdown
```
Gracefully shut down a VM.

```
GET /api2/json/nodes/{node}/qemu/{vmid}/config
```
Get the configuration of a VM.

```
PUT /api2/json/nodes/{node}/qemu/{vmid}/config
```
Update the VM configuration.

### Containers (LXC)

```
GET /api2/json/nodes/{node}/lxc
```
List all LXC containers on a specific node.

```
GET /api2/json/nodes/{node}/lxc/{vmid}/status/current
```
Get the current status of a container.

```
POST /api2/json/nodes/{node}/lxc/{vmid}/status/start
```
Start a container.

```
POST /api2/json/nodes/{node}/lxc/{vmid}/status/stop
```
Stop a container.

### Storage Management

```
GET /api2/json/storage
```
List all storage definitions in the cluster.

```
GET /api2/json/nodes/{node}/storage/{storage}/content
```
List the content of a specific storage (e.g., VM disks, ISO images).

### Tasks and Logs

```
GET /api2/json/nodes/{node}/tasks
```
List all tasks (e.g., VM creation, backups) on a node.

```
GET /api2/json/nodes/{node}/tasks/{upid}/status
```
Get the status of a specific task by its Unique Process ID (UPID).

```
GET /api2/json/nodes/{node}/tasks/{upid}/log
```
Get the log output of a specific task.

### Guest Agent (QEMU)

```
GET /api2/json/nodes/{node}/qemu/{vmid}/agent/info
```
Get info from the QEMU guest agent (if installed in the VM).

```
POST /api2/json/nodes/{node}/qemu/{vmid}/agent/exec
```
Execute a command inside the VM via the guest agent.

### Backup and Restore

```
POST /api2/json/nodes/{node}/vzdump
```
Create a backup of a VM or container.

```
POST /api2/json/nodes/{node}/qemu/{vmid}/snapshot
```
Create a snapshot of a VM.

```
POST /api2/json/nodes/{node}/qemu/{vmid}/snapshot/{snapname}/rollback
```
Roll back a VM to a specific snapshot.

## Implementation in Comserv

In our Comserv application, we primarily use the following endpoints:

1. `/nodes` - To get a list of all nodes in the cluster
2. `/cluster/resources?type=vm` - To get a list of all VMs in the cluster
3. `/cluster/resources?type=qemu` - Alternative endpoint to get QEMU VMs
4. `/cluster/resources` - To get all resources (including VMs and containers)
5. `/nodes/{node}/qemu` - To get QEMU VMs on a specific node
6. `/nodes/{node}/lxc` - To get LXC containers on a specific node
7. `/version` - To check connectivity and get Proxmox version information

Our implementation includes fallback mechanisms to try different endpoints if the primary ones fail, ensuring robust operation even with different Proxmox configurations.

### Key Endpoints for VM Management

**To get a list of nodes (physical servers) in the cluster**:
```
GET /api2/json/nodes
```
This does NOT return VMs, only the physical nodes in your cluster.

**To get a list of all VMs across the cluster**:
```
GET /api2/json/cluster/resources?type=vm
```
or
```
GET /api2/json/cluster/resources?type=qemu
```
These endpoints return all VMs across all nodes in the cluster.

**To get VMs on a specific node**:
```
GET /api2/json/nodes/{node}/qemu
```
Where `{node}` is the name of the node (e.g., "pve").

**To get LXC containers on a specific node**:
```
GET /api2/json/nodes/{node}/lxc
```

### Endpoint Selection Logic

Our application tries to retrieve VM data in the following order:

1. First, it gets a list of all nodes in the cluster using `/nodes`
2. Then it tries the cluster resources endpoint with different type parameters:
   - `/cluster/resources?type=vm`
   - `/cluster/resources?type=qemu`
   - `/cluster/resources` (without type filter)
3. If those fail, it tries to get VMs from each node individually:
   - `/nodes/{node}/qemu` for QEMU VMs
   - `/nodes/{node}/lxc` for LXC containers

This approach ensures that we can retrieve VM data from different Proxmox configurations, including standalone nodes and clusters.

### Testing API Endpoints Directly

You can test these endpoints directly using curl to diagnose issues:

```bash
# Replace with your actual values
PROXMOX_HOST="your-proxmox-host.example.com"
API_TOKEN_USER="your-user@pam!tokenid"
API_TOKEN_VALUE="your-token-value"

# Test getting nodes
curl -k -s "https://$PROXMOX_HOST:8006/api2/json/nodes" \
  -H "Authorization: PVEAPIToken=$API_TOKEN_USER=$API_TOKEN_VALUE"

# Test getting VMs via cluster resources
curl -k -s "https://$PROXMOX_HOST:8006/api2/json/cluster/resources?type=vm" \
  -H "Authorization: PVEAPIToken=$API_TOKEN_USER=$API_TOKEN_VALUE"

# Test getting VMs on a specific node (using 'proxmox' as the node name)
curl -k -s "https://$PROXMOX_HOST:8006/api2/json/nodes/proxmox/qemu" \
  -H "Authorization: PVEAPIToken=$API_TOKEN_USER=$API_TOKEN_VALUE"

# If your node has a different name, replace 'proxmox' with your node name
# For example, if your node is named 'pve':
curl -k -s "https://$PROXMOX_HOST:8006/api2/json/nodes/pve/qemu" \
  -H "Authorization: PVEAPIToken=$API_TOKEN_USER=$API_TOKEN_VALUE"
```

The `-k` flag disables SSL verification, which is useful for testing but should be avoided in production.

#### Finding Your Node Name

If you're not sure what your node name is, you can:

1. Look at the Proxmox web interface - the node name is usually shown in the server list
2. Use the `/nodes` API endpoint to get a list of all nodes
3. Check the hostname of your Proxmox server (often the node name is the same as the hostname)

Our code now automatically tries both the configured node name and 'proxmox' to ensure it works regardless of your configuration.

### Common Issues and Solutions

1. **Authentication Issues**:
   - Make sure the API token has the correct permissions
   - Verify the token format: `PVEAPIToken=USER@REALM!TOKENID=UUID`
   - Check that the token is not expired
   - Ensure the token has the correct role with VM.Audit permission

2. **Node Name Issues**:
   - The default node name in Proxmox is often 'pve', but it can be customized
   - Our code now automatically detects node names from the API
   - If you know your node name (e.g., 'proxmox'), you can set it in the configuration
   - You can see the node name in the Proxmox web interface or by using the `/nodes` API endpoint

3. **Empty VM List**:
   - The API token might not have permission to view VMs
   - The cluster resources endpoint might not be available in your Proxmox version
   - Try using node-specific endpoints instead
   - Check if you have any VMs created on the Proxmox server
   - Make sure you're using the correct node name in node-specific endpoints

4. **SSL/TLS Issues**:
   - Our code disables SSL verification for development environments
   - For production, consider enabling proper SSL verification
   - If using a self-signed certificate, you may need to add it to your trusted certificates

5. **Version Differences**:
   - Different Proxmox versions might have slightly different API responses
   - Our code includes fallbacks for different API formats
   - Proxmox VE 7.x and 8.x have slightly different API structures

## Error Handling

The Proxmox API returns standard HTTP status codes:
- 200 OK - Request successful
- 400 Bad Request - Invalid parameters
- 401 Unauthorized - Authentication failed
- 403 Forbidden - Permission denied
- 404 Not Found - Resource not found
- 500 Internal Server Error - Server-side error

In our application, we handle these errors and provide detailed logging to help diagnose issues.

## Further Resources

- [Official Proxmox VE API Documentation](https://pve.proxmox.com/pve-docs/api-viewer/)
- Access the API Viewer on your Proxmox instance: `https://<your-proxmox-host>:8006/pve-docs/api-viewer/`
- Use the `pvesh` command-line tool on a Proxmox node (e.g., `pvesh get / --output-format json`) to inspect available paths dynamically