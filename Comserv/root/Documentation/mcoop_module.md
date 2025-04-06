# MCoop Module Documentation

**Last Updated:** April 1, 2025  
**Author:** Shanta  
**Status:** Active

## Overview

The MCoop (Monashee Coop) module provides functionality for managing Monashee Cooperative operations within the Comserv system. This module is designed for administrators to manage cooperative resources, infrastructure, and planning.

## Features

### Server Room Plan

The Server Room Plan feature provides a detailed proposal for the Monashee Coop's server infrastructure, including:

- Equipment requirements with pricing options
- Analysis of different server room configurations
- Common practices in server room implementation
- Recommendations for short-term and long-term solutions

**Access URL:** `/mcoop/server_room_plan` or `/mcoop/server-room-plan`  
**Required Role:** Administrator  
**Template:** `coop/server_room_plan.tt`

### Network Infrastructure

The Network Infrastructure feature provides information and management tools for the coop's network setup.

**Access URL:** `/mcoop/network`  
**Required Role:** Administrator  
**Template:** `coop/network.tt`

### COOP Services

This feature provides an overview and management interface for services offered by the cooperative.

**Access URL:** `/mcoop/services`  
**Required Role:** Administrator  
**Template:** `coop/services.tt`

## Technical Implementation

### Controller Structure

The MCoop module is implemented in `Comserv/lib/Comserv/Controller/MCoop.pm` with the following key methods:

```perl
# Main index method
sub index :Path :Args(0) {
    # Implementation details...
}

# Server room plan method
sub server_room_plan :Path('server_room_plan') :Args(0) {
    # Implementation details...
}

# Compatibility method for hyphenated URLs
sub server_room_plan_hyphen :Path('server-room-plan') :Args(0) {
    # Implementation details...
}
```

### Template Structure

The MCoop module uses the following templates:

- `coop/index.tt` - Main landing page for the MCoop module
- `coop/server_room_plan.tt` - Server room proposal template
- `coop/network.tt` - Network infrastructure template
- `coop/services.tt` - COOP services template

### Access Control

All MCoop features are restricted to administrators only. This is implemented through:

1. Role-based menu visibility in `admintopmenu.tt`
2. Site-specific menu visibility (only shown when the current site is MCOOP)
3. Controller-level checks for administrator privileges

## Navigation

MCoop features are accessible through the Admin menu in the main navigation, but only when the current site is MCOOP. The menu structure is:

```
Admin
└── MCOOP Admin (only visible when current site is MCOOP)
    ├── MCOOP Home
    ├── Server Room Plan
    ├── Network Infrastructure
    ├── COOP Services
    ├── Infrastructure Management
    ├── COOP Reports
    └── Strategic Planning
```

## Future Development

Planned enhancements for the MCoop module include:

1. **Member Management** - Tools for managing cooperative membership
2. **Resource Scheduling** - Calendar and booking system for shared resources
3. **Financial Reporting** - Tools for tracking cooperative finances
4. **Document Repository** - Secure storage for cooperative documents
5. **Meeting Management** - Tools for scheduling and documenting meetings

## Related Documentation

- [MCoop Admin Menu Restriction](changelog/2025-04-mcoop-admin-menu-restriction.md)
- [MCoop Server Room Plan Implementation](changelog/2025-04-mcoop-server-room-plan.md)
- [Theme System Implementation](theme_system_implementation.md)