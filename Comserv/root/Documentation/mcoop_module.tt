# MCoop Module Documentation

**Last Updated:** April 17, 2025
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

**Access URL:** `/MCoop/server_room_plan` or `/MCoop/server-room-plan` (case-sensitive)  
**Alternative URLs:** `/mcoop/server_room_plan` or `/mcoop/server-room-plan` (lowercase also supported)  
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
# Main index method - chained version
sub index :Chained('base') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 'Enter MCoop index method');

    # Set mail server
    $c->session->{MailServer} = "http://webmail.computersystemconsulting.ca";

    # Generate theme CSS if needed
    $c->model('ThemeConfig')->generate_all_theme_css($c);

    # Make sure we're using the correct case for the site name
    $c->model('ThemeConfig')->set_site_theme($c, "MCoop", "mcoop");

    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless defined $c->stash->{debug_msg};
        push @{$c->stash->{debug_msg}}, "MCoop controller index view - Using mcoop theme";
    }

    # Set template and forward to view
    $c->stash(template => 'coop/index.tt');
    $c->forward($c->view('TT'));
}

# Server room plan base method (chained)
sub server_room_plan_base :Chained('base') :PathPart('server_room_plan') :CaptureArgs(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'server_room_plan_base', 'Enter server_room_plan_base method');

    # Set up common elements for server room plan pages
    $c->stash->{help_message} = "This is the server room proposal for the Monashee Coop transition team.";
    $c->stash->{account_message} = "For more information or to provide feedback, please contact the IT department.";
}

# Main server room plan page (chained)
sub server_room_plan :Chained('server_room_plan_base') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'server_room_plan', 'Enter server_room_plan method');

    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless defined $c->stash->{debug_msg};
        push @{$c->stash->{debug_msg}}, "MCoop controller server_room_plan view - Template: coop/server_room_plan.tt";
    }

    # Set template and forward to view
    $c->stash(template => 'coop/server_room_plan.tt');
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'server_room_plan', 'Set template to coop/server_room_plan.tt');
    $c->forward($c->view('TT'));
}

# Direct access to server_room_plan (non-chained)
sub direct_server_room_plan :Path('/MCoop/server_room_plan') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'direct_server_room_plan', 'Direct server_room_plan method called');
    $c->forward('server_room_plan');
}

# Handle the hyphenated version (uppercase)
sub server_room_plan_hyphen :Path('/MCoop/server-room-plan') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'server_room_plan_hyphen', 'Enter server_room_plan_hyphen method');
    $c->forward('server_room_plan');
}

# Handle lowercase mcoop URLs with hyphen
sub server_room_plan_hyphen_lowercase :Path('/mcoop/server-room-plan') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'server_room_plan_hyphen_lowercase', 'Lowercase mcoop URL accessed');
    $c->forward('server_room_plan');
}

# Handle lowercase mcoop URLs with underscore
sub server_room_plan_underscore_lowercase :Path('/mcoop/server_room_plan') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'server_room_plan_underscore_lowercase', 'Lowercase mcoop URL with underscore accessed');
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
- [MCoop URL Case Sensitivity Fix](changelog/2025-04-13-mcoop-url-case-fix.md)
- [Theme System Implementation](theme_system_implementation.md)