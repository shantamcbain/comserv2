# Documentation System Overview

## Introduction

The Comserv Documentation System provides a comprehensive framework for organizing, categorizing, and displaying documentation for different user roles and sites. This document provides an overview of the system architecture, key components, and best practices.

## System Architecture

The documentation system consists of:

1. **Controller**: `Comserv::Controller::Documentation` handles routing and access control
2. **Templates**: Located in `root/Documentation/` directory
3. **Content Files**: Markdown (.md) and Template Toolkit (.tt) files
4. **Categories**: Predefined categories for organizing documentation
5. **Access Control**: Role-based permissions for viewing documentation

## Routes

The system supports both uppercase and lowercase routes:

- `/Documentation` - Main documentation index (uppercase)
- `/documentation` - Alternative route (lowercase)
- `/Documentation/[page]` - View specific documentation page
- `/documentation/[page]` - Alternative route for specific page

### Special Routes

- `/Documentation/documentation_system_overview` - This overview
- `/Documentation/documentation_filename_issue` - Information about the filename/package mismatch issue
- `/Documentation/logging_best_practices` - Best practices for logging
- `/Documentation/ai_guidelines` - Guidelines for AI assistants
- `/Documentation/controller_routing_guidelines` - Guidelines for controller routing
- `/Documentation/controllers` - Documentation for controllers
- `/Documentation/documentation_update_summary` - Summary of documentation updates
- `/Documentation/linux_commands` - Linux Commands Reference (redirects to HelpDesk controller)

## Logging

The documentation system uses comprehensive logging to track access and troubleshoot issues:

```perl
$self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'method_name',
    "Detailed message with relevant information");
```

This ensures that:
1. The log level is properly set
2. File and line information is captured
3. The method name is recorded
4. A detailed message is provided

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

## Best Practices

### File Naming

1. Use lowercase with underscores for filenames
2. Include the category in the filename when appropriate
3. Use descriptive names that indicate the content

Example: `user_guide_login.md`, `admin_installation.tt`

### Content Organization

1. Place files in appropriate subdirectories based on category
2. Use consistent formatting within documentation files
3. Include a title and description at the top of each file

### Metadata

Each documentation file has metadata including:

1. **Title**: Formatted from the filename
2. **Path**: Relative path to the file
3. **Roles**: User roles that can access the file
4. **Site**: Site specificity (all or site name)
5. **File Type**: Template, markdown, or other

## Troubleshooting

Common issues and solutions:

1. **Page Not Found**: Check that the file exists and is properly categorized
2. **Access Denied**: Verify user role has permission to view the documentation
3. **Rendering Issues**: Check the file type and corresponding template

## Important Note on File Naming

**⚠️ WARNING**: Ensure that controller filenames match their package declarations. A mismatch between filename and package name can cause route failures.

Example of correct naming:
- File: `Documentation.pm`
- Package: `Comserv::Controller::Documentation`

For more details on a previous issue with filename mismatch, see [Documentation Filename Issue](/Documentation/documentation_filename_issue).

## Related Documentation

- [Documentation Filename Issue](/Documentation/documentation_filename_issue)
- [Logging Best Practices](/Documentation/logging_best_practices)
- [AI Guidelines](/Documentation/ai_guidelines)
- [Controller Routing Guidelines](/Documentation/controller_routing_guidelines)
- [Controllers Documentation](/Documentation/controllers)
- [Documentation Update Summary](/Documentation/documentation_update_summary)
- [Linux Commands Reference](/Documentation/linux_commands)
- [Mail System Documentation](/Documentation/mail_system.md)
- [Mail Configuration Guide](/Documentation/mail_configuration_guide.md)
- [Mail Troubleshooting Guide](/Documentation/mail_troubleshooting.md)