# Comserv Documentation

This directory contains documentation for various components of the Comserv application.

## Available Documentation

- [Proxmox API Documentation](proxmox_api.md) - Detailed information about the Proxmox VE API endpoints used in the application
- [Technical Changes](technical_changes.md) - Documentation of technical changes and bug fixes

## Development Plans

This section outlines our ongoing development plans and standardization efforts:

- [Development Plans Index](development_plans.md) - Index of all ongoing and planned development initiatives
- [Controller Routing Standardization](controller_routing_standardization.md) - Plan for standardizing controller routing using Catalyst's chained actions

## Bug Fixes

- [Bug Fixes Documentation](bug_fixes_documentation.md) - Detailed documentation of bug fixes and their implementations
- [MCoop Controller Fix](mcoop_controller_fix.md) - Documentation of the MCoop controller fix for site name case handling and routing standardization

## Troubleshooting

If you encounter issues with the Comserv application, check the following:

1. Ensure all credentials are correctly configured
2. Check the application logs at `logs/application.log` for detailed error messages
3. Verify that all required services are accessible from the application server
4. Make sure all API tokens have sufficient permissions

### Proxmox-Specific Troubleshooting

If you encounter issues with the Proxmox integration specifically:

1. Ensure the Proxmox credentials are correctly configured
2. Verify that the Proxmox API is accessible from the application server
3. Check that the API token has sufficient permissions

## Getting Help

For additional help, please contact the Comserv development team or refer to the internal documentation.