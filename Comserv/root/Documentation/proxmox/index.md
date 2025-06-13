# Proxmox Documentation

This page provides access to comprehensive documentation for Proxmox VE, including API references, command-line tools, and configuration guides.

## Available Documentation

### API and Integration

- [Proxmox VE API Documentation](/Documentation/proxmox/api) - Overview of the Proxmox VE API endpoints used in the Comserv application
- [Proxmox Authentication Changes](/Documentation/proxmox/authentication) - Changes to the authentication system for Proxmox integration
- [Proxmox Integration Overview](/Documentation/proxmox/integration) - Overview of the Proxmox integration in Comserv

### Command Reference

- [Proxmox Command Reference](commands.md) - Comprehensive list of CLI commands for managing Proxmox VE
- [Proxmox IP Configuration Guide](ip_configuration.md) - Detailed guide for configuring IP addresses in Proxmox

### Changelog

- [2024-07 Proxmox Controller Fixes](changelog/2024-07-proxmox-controller-fixes.md) - Fixes for the Proxmox controller
- [2024-08 Proxmox Debug Message Fix](changelog/2024-08-proxmox-debug-msg-fix.md) - Fix for debug message handling in the Proxmox controller

## Quick Reference

### Common Proxmox Commands

```bash
# List all VMs
qm list

# Start a VM
qm start <vmid>

# Stop a VM
qm stop <vmid>

# List all containers
pct list

# Start a container
pct start <ctid>

# Stop a container
pct stop <ctid>
```

### Setting IP Addresses

```bash
# Set static IP for a container
pct set <ctid> --net0 name=eth0,bridge=vmbr0,ip=192.168.1.100/24,gw=192.168.1.1

# Set static IP for a VM (requires QEMU guest agent)
qm set <vmid> --ipconfig0 ip=192.168.1.100/24,gw=192.168.1.1
```

For more detailed commands and examples, see the [Proxmox Command Reference](commands.md) and [Proxmox IP Configuration Guide](ip_configuration.md).