# AI Documentation Guidelines

## Overview
This document provides guidelines for AI assistants working with the Comserv2 project, specifically focusing on documentation management and organization.

## Documentation Organization

### Directory Structure
All documentation must be placed in the appropriate subdirectory of `/Comserv/root/Documentation/`:

- `/changelog/` - Documentation of changes and fixes
- `/controllers/` - Controller-specific documentation
- `/models/` - Model-specific documentation
- `/deployment/` - Deployment and server setup guides
- `/system/` - System-level documentation
- `/themes/` - Theme system documentation
- `/tutorials/` - User and developer tutorials
- `/general/` - General documentation

### Important Rules

1. **NEVER create documentation files in the application root directory**
   - All documentation must be placed in the appropriate subdirectory of `/Comserv/root/Documentation/`
   - The only exception is the main README.md file in the application root

2. **NEVER create categorization files**
   - Do not create files with names like "Added X to Y category"
   - Do not create files with names like "Formatting title from: X"
   - Do not create files with names like "Categorized as X: Y"
   - Do not create files with names like "Category X has Y pages"

3. **NEVER create temporary files**
   - All files should be properly named and placed in the appropriate directory
   - Do not create files with temporary or intermediate content

## Documentation Standards

1. **File Format**
   - Use Markdown format with the `.md` extension
   - Follow consistent formatting within documents

2. **File Naming**
   - Use lowercase with underscores for spaces
   - For changelog entries, use the format: `YYYY-MM-description.md`
   - For controller documentation, use the controller name: `ControllerName.md`

3. **Documentation Structure**
   - Start with a clear title using `# Title`
   - Include an overview section
   - Use appropriate headings for sections
   - Include code examples where relevant
   - Link to related documentation

## Creating New Documentation

When creating new documentation:

1. **Determine the appropriate category**
   - Controller documentation goes in `/controllers/`
   - Model documentation goes in `/models/`
   - General guides go in `/general/`
   - Changelog entries go in `/changelog/`

2. **Create the file in the correct location**
   - Use the `str_replace_editor` tool with the correct path
   - Example: `/home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation/controllers/MyController.md`

3. **Update related documentation**
   - If documenting a controller, update the controller list in `/controllers/controller_list.md`
   - If adding a changelog entry, ensure it follows the standard format

## Example: Documenting a Controller

```markdown
# MyController Controller

## Overview
Brief description of the controller's purpose.

## Key Features
- Feature 1
- Feature 2
- Feature 3

## Methods
- `method1`: Description
- `method2`: Description
- `method3`: Description

## Access Control
This controller is accessible to users with the following roles:
- role1
- role2

## Related Files
- Related file 1
- Related file 2
```

## Example: Creating a Changelog Entry

```markdown
# Feature X Implementation - Month YYYY

## Overview
Brief description of the change.

## Changes Made
- Change 1
- Change 2
- Change 3

## Files Modified
- `/path/to/file1`
- `/path/to/file2`

## Testing
How to test the changes.
```

## Maintaining Documentation

When updating the system:

1. Update relevant documentation files
2. Create changelog entries for significant changes
3. Ensure documentation is placed in the correct location
4. Keep the documentation structure consistent

## Cleaning Up Documentation

If you find documentation files in the wrong location or categorization files:

1. Use the cleanup script: `/Comserv/root/Documentation/scripts/cleanup_categorization_files.pl`
2. Move documentation files to the correct location using the script: `/Comserv/root/Documentation/scripts/move_docs_to_proper_location.pl`