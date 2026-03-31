# Documentation System Management Guide

## Overview

As an administrator, you have full access to the Comserv Documentation System and are responsible for maintaining and organizing the documentation. This guide explains how to manage the documentation system effectively.

## Administrator Privileges

As an administrator, you can:

- View all documentation in the system
- Add, edit, and remove documentation files
- Organize documentation into categories
- Manage site-specific documentation
- View technical documentation not available to regular users

## Documentation Structure

The documentation is stored in the following directory structure:

```
/root/Documentation/
  ├── roles/
  │   ├── admin/         # Admin-only documentation
  │   ├── normal/        # Regular user documentation
  │   └── developer/     # Developer documentation
  ├── tutorials/         # Step-by-step guides
  ├── modules/           # Module-specific documentation
  ├── proxmox/           # Proxmox-related documentation
  ├── changelog/         # System changes and updates
  └── controllers/       # Controller documentation
```

## Adding New Documentation

To add new documentation:

1. Create a new file in the appropriate directory with a `.md` or `.tt` extension
2. Use a descriptive filename with underscores for spaces (e.g., `user_management.md`)
3. Follow the standard Markdown or Template Toolkit format
4. Place the file in the appropriate directory based on its content and intended audience

### Example Markdown Structure

```markdown
# Title of Documentation

## Overview
Brief description of the topic.

## Features
- Feature 1
- Feature 2

## Usage
Instructions for using the feature.

## Examples
Code examples or usage examples.
```

## Categorization Rules

The system automatically categorizes documentation based on:

1. **Directory Location**:
   - Files in `/roles/admin/` are categorized as Administrator Guides
   - Files in `/roles/normal/` are categorized as User Documentation
   - Files in `/roles/developer/` are categorized as Developer Guides
   - Files in `/tutorials/` are categorized as Tutorials
   - Files in `/proxmox/` are categorized as Proxmox Documentation
   - Files in `/controllers/` are categorized as Controller Documentation
   - Files in `/changelog/` are categorized as Changelog

2. **Filename Patterns**:
   - Files starting with `installation`, `configuration`, `system`, `admin`, or `user_management` are categorized as Administrator Guides
   - Files starting with `getting_started`, `account_management`, `user_guide`, or `faq` are categorized as User Documentation
   - Files starting with `todo`, `project`, or `task` are categorized as Module Documentation
   - Files starting with `proxmox` are categorized as Proxmox Documentation

## Site-Specific Documentation

To create site-specific documentation:

1. Add a site identifier to the metadata of the file
2. The documentation will only be shown when viewing that specific site

## Managing Recent Updates

The system displays recent updates from the `completed_items.json` file. To update this:

1. Edit the `root/Documentation/completed_items.json` file
2. Add new entries in the following format:

```json
{
  "completed_items": [
    {
      "date_created": "2024-05-31",
      "title": "Authentication System Updates",
      "description": "Fixed logout functionality and improved user profile management."
    },
    {
      "date_created": "2024-05-31",
      "title": "Template System Improvements",
      "description": "Enhanced footer display and error handling in templates."
    }
  ]
}
```

## Best Practices

### File Naming

- Use descriptive names that clearly indicate the content
- Use underscores instead of spaces
- Keep filenames relatively short
- Use lowercase letters

### Content Organization

- Start with a clear title (# Title)
- Include an overview or introduction
- Use headings (## Heading) to organize content
- Include examples where appropriate
- Use lists for steps or features
- Include screenshots for complex UI elements

### Maintenance

- Regularly review and update documentation
- Remove outdated information
- Update documentation when features change
- Check for broken links or references
- Ensure consistent formatting across documents

## Troubleshooting

### Documentation Not Appearing

If documentation is not appearing as expected:

1. Check that the file is in the correct directory
2. Verify that the file has a supported extension (.md, .tt, .html, .txt)
3. Check the logs for any errors in the documentation scanning process
4. Restart the application to force a rescan of the documentation

### Incorrect Categorization

If documentation is appearing in the wrong category:

1. Check the file path to ensure it's in the correct directory
2. Review the filename to ensure it follows the categorization patterns
3. Move the file to the appropriate directory if needed

### Permission Issues

If users report they cannot see certain documentation:

1. Verify that the documentation is in the correct directory for their role
2. Check that the user has the appropriate role assigned
3. Review the categorization rules to ensure they're working as expected

## Technical Details

The Documentation system is implemented using:

- **Controller**: `Comserv::Controller::Documentation`
- **Template**: `Documentation/index.tt`
- **JavaScript**: Client-side sorting and tab switching
- **CSS**: Styling for documentation cards, tabs, and badges

For more technical details, see the [Documentation Controller Technical Reference](/Documentation/roles/developer/Documentation_Controller).