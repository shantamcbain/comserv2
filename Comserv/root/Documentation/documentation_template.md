---
title: "Documentation Template"
description: "Template for creating new documentation using the metadata-driven approach"
author: "System Administrator"
date: "2025-05-30"
status: "Active"
roles: ["normal", "editor", "admin", "developer"]
sites: ["all"]
categories: ["user_guides", "tutorials"]
tags: ["template", "documentation", "metadata"]
version: "1.0"
---

# Documentation Template

## Overview

This template provides a standardized format for creating new documentation in the Comserv system using the metadata-driven approach. Following this template ensures that all documentation is consistent and properly categorized.

## Metadata Section

Every documentation file should begin with a metadata section enclosed in triple dashes (`---`). This section contains key information about the document that is used for categorization, filtering, and display.

```markdown
---
title: "Document Title"
description: "Brief description of the document"
author: "Your Name"
date: "YYYY-MM-DD"
status: "Active"
roles: ["normal", "admin", "developer"]
sites: ["all", "MCOOP"]
categories: ["user_guides", "tutorials"]
tags: ["feature1", "feature2"]
---
```

### Required Metadata Fields

- **title**: The title of the document (should match the H1 heading)
- **description**: A brief description of the document content (1-2 sentences)
- **author**: Your name or username
- **date**: The creation date in YYYY-MM-DD format
- **status**: One of "Active", "Draft", or "Deprecated"
- **roles**: Array of roles that can access this document (normal, editor, admin, developer)
- **sites**: Array of sites this document applies to ("all" for all sites, or specific site names)
- **categories**: Array of categories this document belongs to (from the configuration file)

### Optional Metadata Fields

- **tags**: Array of tags for additional categorization
- **version**: Document version number
- **related**: Array of related document filenames

## Document Structure

### Main Heading

The document should start with a level 1 heading (`#`) that matches the title in the metadata section.

### Overview Section

Begin with an overview section that briefly explains the purpose and scope of the document.

### Main Sections

Organize the document into logical sections using level 2 headings (`##`).

### Subsections

Use level 3 headings (`###`) for subsections within main sections.

## Formatting Guidelines

### Code Blocks

Use fenced code blocks with language specification for code examples:

```perl
sub example_function {
    my ($self, $param) = @_;
    return $param;
}
```

### Lists

Use bulleted lists for unordered items:

- Item 1
- Item 2
- Item 3

Use numbered lists for sequential steps:

1. First step
2. Second step
3. Third step

### Tables

Use markdown tables for tabular data:

| Column 1 | Column 2 | Column 3 |
|----------|----------|----------|
| Data 1   | Data 2   | Data 3   |
| Data 4   | Data 5   | Data 6   |

### Images

Include images with descriptive alt text:

```markdown
![Alt text for the image](path/to/image.png "Optional title")
```

### Notes and Warnings

Use blockquotes for notes and warnings:

> **Note:** This is an important note that users should be aware of.

> **Warning:** This is a warning about potential issues.

## Examples

### Example User Guide

```markdown
---
title: "User Profile Management"
description: "Guide for managing user profiles in the Comserv system"
author: "John Doe"
date: "2025-06-15"
status: "Active"
roles: ["normal", "editor", "admin", "developer"]
sites: ["all"]
categories: ["user_guides"]
tags: ["profile", "user management", "settings"]
---

# User Profile Management

## Overview

This guide explains how to manage your user profile in the Comserv system, including updating personal information, changing your password, and configuring notification preferences.

## Accessing Your Profile

1. Log in to the Comserv system
2. Click on your username in the top-right corner
3. Select "Profile" from the dropdown menu

## Updating Personal Information

...
```

### Example Admin Guide

```markdown
---
title: "User Role Management"
description: "Guide for administrators on managing user roles"
author: "Jane Smith"
date: "2025-06-20"
status: "Active"
roles: ["admin", "developer"]
sites: ["all"]
categories: ["admin_guides"]
tags: ["roles", "permissions", "user management"]
---

# User Role Management

## Overview

This guide explains how administrators can manage user roles in the Comserv system, including assigning roles, creating custom roles, and configuring role permissions.

## Accessing Role Management

1. Log in to the Comserv system as an administrator
2. Navigate to Admin > User Management > Roles

## Available Roles

...
```

## Related Documentation

- [Documentation System Overview](/Documentation/docs/developer/documentation_system.md)
- [Documentation Workflow](/Documentation/docs/developer/documentation_workflow.md)
- [Metadata Reference](/Documentation/docs/developer/metadata_reference.md)

## Conclusion

Following this template ensures that all documentation is consistent, properly categorized, and easily accessible through the documentation system. The metadata-driven approach allows for flexible filtering and organization of documentation based on various criteria.