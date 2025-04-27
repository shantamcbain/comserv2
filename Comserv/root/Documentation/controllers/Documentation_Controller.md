# Documentation Controller

## Overview

The Documentation Controller (`Comserv::Controller::Documentation`) manages the documentation system in the Comserv application. It provides routes for accessing documentation pages, handles role-based access control, and organizes documentation into categories.

## File Location

**IMPORTANT**: The controller file must be located at:
```
/home/shanta/PycharmProjects/comserv2/Comserv/lib/Comserv/Controller/Documentation.pm
```

⚠️ **WARNING**: There was previously a critical issue where the filename (`Documantation.pm` with an 'a') did not match the package name (`Comserv::Controller::Documentation` with an 'o'). This mismatch caused route failures. Always ensure filenames match their package declarations.

## Routes

The controller provides the following routes:

### Main Routes

- `/Documentation` - Main documentation index (uppercase)
- `/documentation` - Alternative route (lowercase)
- `/Documentation/[page]` - View specific documentation page
- `/documentation/[page]` - Alternative route for specific page

### Special Routes

- `/Documentation/documentation_system_overview` - Overview of the documentation system
- `/Documentation/documentation_filename_issue` - Information about the filename/package mismatch issue
- `/Documentation/logging_best_practices` - Best practices for logging
- `/Documentation/ai_guidelines` - Guidelines for AI assistants
- `/Documentation/controller_routing_guidelines` - Guidelines for controller routing
- `/Documentation/controllers` - Documentation for controllers
- `/Documentation/documentation_update_summary` - Summary of documentation updates
- `/Documentation/linux_commands` - Linux Commands Reference (redirects to HelpDesk controller)

## Key Methods

### `index`

The main entry point for the documentation system. It:
1. Determines the user's role
2. Filters documentation based on role and site
3. Organizes documentation into categories
4. Renders the main documentation index

### `view`

Handles viewing individual documentation pages. It:
1. Checks if the user has permission to view the page
2. Determines the appropriate template based on file type
3. Renders the documentation page

### `BUILD`

Initializes the documentation system by:
1. Scanning documentation directories
2. Categorizing documentation files
3. Setting up role-based access control

## Logging

The controller uses comprehensive logging to track access and troubleshoot issues:

```perl
$self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'method_name',
    "Detailed message with relevant information");
```

## Categories

Documentation is organized into the following categories:

1. **User Guides**: For end users of the system
2. **Admin Guides**: For system administrators
3. **Developer Guides**: For developers
4. **Tutorials**: Step-by-step guides for common tasks
5. **Site-Specific**: Documentation specific to a particular site
6. **Modules**: Documentation for specific system modules
7. **Controllers**: Documentation for system controllers
8. **Models**: Documentation for system models
9. **Changelog**: System changes and updates
10. **General**: Complete list of all documentation files

## Access Control

Access to documentation is controlled by:

1. **User Role**: Different roles (normal, editor, admin, developer) have access to different categories
2. **Site**: Site-specific documentation is only shown to users of that site
3. **Admin Override**: Administrators can access all documentation regardless of role or site restrictions

## File Types

The system supports multiple file types:

1. **Markdown (.md)**: For content-focused documentation
2. **Template Toolkit (.tt)**: For interactive or complex documentation
3. **HTML (.html)**: For static HTML content
4. **Text (.txt)**: For plain text documentation

## Related Documentation

- [Documentation System Overview](/Documentation/documentation_system_overview)
- [Documentation Filename Issue](/Documentation/documentation_filename_issue)
- [Logging Best Practices](/Documentation/logging_best_practices)
- [AI Guidelines](/Documentation/ai_guidelines)
- [Controller Routing Guidelines](/Documentation/controller_routing_guidelines)
- [Controllers Documentation](/Documentation/controllers)
- [Documentation Update Summary](/Documentation/documentation_update_summary)