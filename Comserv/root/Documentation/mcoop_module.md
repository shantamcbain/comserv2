# MCoop Module Documentation

**Last Updated:** April 1, 2025
**Author:** Shanta
**Status:** Active

## Overview

The MCoop (Monashee Coop) module provides functionality for managing Monashee Cooperative operations within the Comserv system. This module is designed for administrators to manage cooperative resources, infrastructure, and planning. The module is accessible only to administrators when the current site is set to MCOOP.

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
    my ($self, $c) = @_;

    # Set theme and other configuration
    $c->session->{"theme_mcoop"} = "mcoop";
    $c->session->{theme_name} = "mcoop";
    $c->session->{"theme_" . lc("MCOOP")} = "mcoop";
    $c->model('ThemeConfig')->set_site_theme($c, "MCOOP", "mcoop");

    # Site information is retrieved from the site table in Root.pm
    $c->stash->{main_website} = "https://monasheecoop.ca";

    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless defined $c->stash->{debug_msg};
        push @{$c->stash->{debug_msg}}, "MCoop controller index view - Using mcoop theme";
    }

    $c->stash->{debug_mode} = $c->session->{debug_mode} || 0;
    $c->stash(template => 'coop/index.tt');
    $c->forward($c->view('TT'));
}

# Server room plan method
sub server_room_plan :Path('server_room_plan') :Args(0) {
    my ($self, $c) = @_;

    # Set theme and help messages
    $c->stash->{theme_name} = "mcoop";
    $c->stash->{help_message} = "This is the server room proposal for the Monashee Coop transition team.";
    $c->stash->{account_message} = "For more information or to provide feedback, please contact the IT department.";

    $c->stash->{debug_mode} = $c->session->{debug_mode} || 0;
    $c->stash(template => 'coop/server_room_plan.tt');
    $c->forward($c->view('TT'));
}

# Compatibility method for hyphenated URLs
sub server_room_plan_hyphen :Path('server-room-plan') :Args(0) {
    my ($self, $c) = @_;
    $c->forward('server_room_plan');
}

# Method with underscore for Root controller compatibility
sub server_room_plan_underscore :Path('/mcoop/server_room_plan') :Args(0) {
    my ($self, $c) = @_;
    $c->forward('server_room_plan');
}
```

### Template Structure

The MCoop module uses the following templates:

- `coop/index.tt` - Main landing page for the MCoop module
  - Contains the Technical Support Center content
  - Displays different content for administrators and regular users
  - Uses the site information from the site table via Root.pm
- `coop/server_room_plan.tt` - Server room proposal template
  - Contains detailed server infrastructure proposal
  - Includes equipment requirements, options analysis, and recommendations
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

This menu structure is implemented in the `admintopmenu.tt` template with the following conditional check:

```tt
[% IF c.session.roles && c.session.roles.grep('^admin$').size && (c.session.SiteName == 'MCOOP' || c.stash.SiteName == 'MCOOP') %]
    <!-- MCOOP Admin menu items -->
[% END %]
```

This ensures that the MCOOP Admin menu is only visible to users with the admin role when they are viewing the MCOOP site.

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