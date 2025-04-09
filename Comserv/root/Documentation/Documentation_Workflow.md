# Documentation Workflow

**Last Updated:** april 9, 2025  
**Author:** Shanta  
**Status:** Active

## Overview

The Comserv Documentation System provides a structured way to organize, categorize, and display documentation files for different user roles and sites. This document outlines the workflow for creating, updating, and maintaining documentation in the system. It incorporates the updates from the 2025-04 documentation workflow update to provide comprehensive guidance on documentation development.

## Documentation Structure

The documentation is organized in the following directory structure:

```
/root/Documentation/
  ├── roles/
  │   ├── admin/         # Admin-only documentation
  │   ├── normal/        # Regular user documentation
  │   └── developer/     # Developer documentation
  ├── tutorials/         # Step-by-step guides
  ├── developer/         # Developer-specific documentation
  ├── proxmox/           # Proxmox-related documentation
  ├── changelog/         # System changes and updates
  ├── controllers/       # Controller documentation
  ├── models/            # Model documentation
  ├── sites/             # Site-specific documentation
  │   └── mcoop/         # MCOOP-specific documentation
  ├── documentation_config.json  # Configuration file for documentation
  └── completed_items.json       # Recent updates tracking
```

## Configuration File

The documentation system uses a central configuration file (`documentation_config.json`) to manage documentation categories and file paths. This file has two main sections:

1. **Categories**: Defines all documentation categories and their properties
2. **Default Paths**: Maps documentation keys to file paths

When adding new documentation or moving existing files, you must update this configuration file to ensure the documentation is properly categorized and accessible.

## File Naming and Formatting

- **File Names**: Use descriptive names with underscores for spaces (e.g., `user_management.md`)
- **Title Format**: Titles are automatically generated from filenames by replacing underscores with spaces and capitalizing words
- **Acronyms**: Common acronyms like API, KVM, ISO, etc. are properly capitalized in titles
- **Metadata**: Include metadata at the top of each document:
  ```markdown
  # Document Title
  
  **Last Updated:** Month Day, Year  
  **Author:** Your Name  
  **Status:** Active/Draft/Deprecated
  ```

## Categories

The system organizes documentation into the following categories:

1. **User Guides**: End-user guides and documentation
2. **Tutorials**: Step-by-step guides for common tasks
3. **Site-Specific Documentation**: Documentation specific to the current site
4. **Administrator Guides**: Documentation for system administrators (admin only)
5. **Developer Documentation**: Technical documentation for developers
6. **Module Documentation**: Documentation for specific system modules
7. **Controllers Documentation**: Documentation for system controllers (admin/developer only)
8. **Models Documentation**: Documentation for system models (admin/developer only)
9. **Proxmox Documentation**: Documentation for Proxmox virtualization (admin only)
10. **Changelog**: System changes and updates (admin/developer only)
11. **All Documentation**: Complete alphabetical list of all documentation (admin only)

## Development Workflow

When working with documentation, follow this workflow to ensure consistency and quality:

### 1. Identify the Issue or Enhancement

- Determine what documentation needs to be created, updated, or fixed
- Check existing documentation to avoid duplication
- Identify the appropriate category and location for the documentation

### 2. Examine Existing Code and Documentation

- Review related code to understand functionality
- Check existing documentation for accuracy
- Note any discrepancies between code and documentation

### 3. Make Changes

- Create or modify documentation files in the appropriate directory
- Follow the file naming conventions and markdown structure
- Ensure content is accurate, clear, and concise
- Update the `documentation_config.json` file if adding new documentation or moving files

### 4. Test Changes

- Run the application locally
- Navigate to the Documentation section
- Verify that your documentation appears in the correct category
- Check that role-based access control works as expected
- Test on different browsers if UI changes are involved

### 5. Update Changelog

- Add an entry to the appropriate changelog file in `/root/Documentation/changelog/`
- Use the format: `YYYY-MM-DD: [Type] - Description of change`
- Types include: `[ADD]`, `[UPDATE]`, `[FIX]`, `[REMOVE]`

### 6. Commit Changes

- Use descriptive commit messages following this format:
  ```
  [DOCS] Brief description of change
  
  - Detailed explanation of what was changed and why
  - List any related issues or tickets
  ```
- Include both documentation and changelog updates in the same commit

### 7. Review and Merge

- Submit for peer review if required
- Address any feedback
- Merge changes to the main branch

## Adding New Documentation

To add new documentation:

1. Create a new file in the appropriate directory with a `.md` extension
2. Use a descriptive filename with underscores for spaces
3. Include proper metadata at the top of the document
4. Add the document to the `documentation_config.json` file:
   - Add the document key to the appropriate category in the "categories" section
   - Add the document path to the "default_paths" section
5. Update the changelog to reflect the addition

### Example Markdown Structure

```markdown
# Title of Documentation

**Last Updated:** Month Day, Year  
**Author:** Your Name  
**Status:** Active

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

## Moving or Renaming Documentation

When moving or renaming documentation files:

1. Move or rename the file in the file system
2. Update the path in the `documentation_config.json` file
3. Test that the documentation is still accessible
4. Add a changelog entry to document the change

## Template Files

When working with Template Toolkit (.tt) files:

1. Follow the same naming conventions as markdown files
2. Include debug information sections:
   ```tt
   [% IF debug_mode == 1 %]
       [% PageVersion %]
       [% # Use the standard debug message system %]
       [% IF debug_msg.defined && debug_msg.size > 0 %]
           <div class="debug-messages">
               [% FOREACH msg IN debug_msg %]
                   <p class="debug">Debug: [% msg %]</p>
               [% END %]
           </div>
       [% END %]
   [% END %]
   ```
3. Include version information:
   ```tt
   [% PageVersion = 'template_name.tt,v X.XX YYYY/MM/DD author Exp author' %]
   ```
4. Use proper role-based access control:
   ```tt
   [% IF c.session.roles && c.session.roles.grep('^admin$').size %]
       <!-- Admin-only content -->
   [% END %]
   ```

## Administrator View

Administrators have access to all documentation in the system, including:

- All user documentation
- All site-specific documentation
- Admin-only documentation
- A complete alphabetical list of all documentation files

## Recent Updates

The documentation system displays recent updates to the system, pulled from the `completed_items.json` file. This provides users with information about recent changes and improvements.

## Technical Implementation

The Documentation system is implemented using:

- **Controller**: `Comserv::Controller::Documentation`
- **Configuration**: `documentation_config.json`
- **Template**: `Documentation/index.tt` and category-specific templates
- **JavaScript**: Client-side sorting and tab switching
- **CSS**: Styling for documentation cards, tabs, and badges

## Logging and Debugging

The documentation system uses the application's logging framework:

- All documentation scanning and categorization is logged
- Debug information can be viewed by enabling debug mode
- Errors during documentation processing are logged to the application log
- Debug messages are pushed to the stash and can be displayed in templates

## Troubleshooting

If documentation is not appearing as expected:

1. Check that the file is in the correct directory
2. Verify that the path in `documentation_config.json` is correct
3. Verify that the user has the appropriate role to view the documentation
4. Ensure the file has a supported extension (.md, .tt, .html, .txt)
5. Check the logs for any errors in the documentation scanning process
6. Verify that the file follows the correct naming conventions
7. Check that the documentation controller is properly initialized
8. Enable debug mode to see more detailed information

## Maintenance

Regular maintenance tasks for the documentation system:

1. Review and update existing documentation for accuracy
2. Remove outdated documentation
3. Check for broken links or references
4. Ensure all new features have corresponding documentation
5. Verify that role-based access is correctly configured
6. Update the `documentation_config.json` file to reflect the current state of documentation
7. Check that all paths in the configuration file are correct
8. Test documentation visibility for different user roles

## Motivation for Workflow Guidelines

The documentation workflow guidelines were established to address several challenges:

1. **Inconsistent Documentation Quality**: Previously, documentation varied widely in quality and structure depending on the author.
2. **Lack of Clear Process**: Developers were unsure about how to properly document their changes.
3. **Outdated Documentation**: Without a clear update process, documentation often became outdated as the codebase evolved.
4. **Discoverability Issues**: Users had difficulty finding relevant documentation due to inconsistent organization.

By following these workflow guidelines, we ensure:
- More consistent documentation quality and structure
- Better tracking of documentation changes through standardized changelog entries
- Clearer troubleshooting steps for documentation issues
- Improved developer experience when working with documentation