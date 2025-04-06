# Documentation System

## Overview

The Comserv Documentation System provides a structured way to organize, categorize, and display documentation files for different user roles and sites. The system automatically scans the documentation directory, categorizes files based on their location and content, and presents them in an organized interface.

## Features

- **Role-Based Access Control**: Documentation is filtered based on user roles, ensuring users only see documentation relevant to their permissions.
- **Site-Specific Documentation**: Support for site-specific documentation that is only shown when viewing the relevant site.
- **Categorized Documentation**: Documentation is automatically categorized into sections like User Guides, Tutorials, Admin Guides, etc.
- **File Type Support**: Supports multiple file types including Markdown (.md), Template Toolkit (.tt), HTML (.html), and plain text (.txt).
- **Alphabetical Sorting**: All documentation is displayed in alphabetical order by title.
- **Tabbed Interface**: Documentation can be filtered by file type using a tabbed interface.

## Documentation Structure

The documentation is organized in the following directory structure:

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

## File Naming and Formatting

- **File Names**: Use descriptive names with underscores for spaces (e.g., `user_management.md`).
- **Title Format**: Titles are automatically generated from filenames by replacing underscores with spaces and capitalizing words.
- **Acronyms**: Common acronyms like API, KVM, ISO, etc. are properly capitalized in titles.

## Categories

The system automatically categorizes documentation into the following sections:

1. **User Documentation**: End-user guides and documentation
2. **Tutorials**: Step-by-step guides for common tasks
3. **Site-Specific Documentation**: Documentation specific to the current site
4. **Administrator Guides**: Documentation for system administrators (admin only)
5. **Proxmox Documentation**: Documentation for Proxmox virtualization (admin only)
6. **Controller Documentation**: Documentation for system controllers (admin only)
7. **Changelog**: System changes and updates (admin only)
8. **All Documentation Files**: Complete alphabetical list of all documentation (admin only)

## Adding New Documentation

To add new documentation:

1. Create a new file in the appropriate directory with a `.md` or `.tt` extension.
2. Use a descriptive filename with underscores for spaces.
3. The file will be automatically categorized based on its location and filename.

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

## Administrator View

Administrators have access to all documentation in the system, including:

- All user documentation
- All site-specific documentation
- Admin-only documentation
- A complete alphabetical list of all documentation files

## Recent Updates

The documentation system also displays recent updates to the system, pulled from the `completed_items.json` file. This provides users with information about recent changes and improvements.

## Technical Implementation

The Documentation system is implemented using:

- **Controller**: `Comserv::Controller::Documentation`
- **Template**: `Documentation/index.tt`
- **JavaScript**: Client-side sorting and tab switching
- **CSS**: Styling for documentation cards, tabs, and badges

## Troubleshooting

If documentation is not appearing as expected:

1. Check that the file is in the correct directory
2. Verify that the user has the appropriate role to view the documentation
3. Ensure the file has a supported extension (.md, .tt, .html, .txt)
4. Check the logs for any errors in the documentation scanning process