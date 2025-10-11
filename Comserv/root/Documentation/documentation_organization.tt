# Documentation Organization

## Overview
This document explains the organization of documentation in the Comserv2 project. All documentation is centralized in the `/Comserv/root/Documentation` directory to maintain consistency and ease of access.

## Directory Structure

- `/Comserv/root/Documentation/` - Main documentation directory
  - `/changelog/` - Documentation of changes and fixes
  - `/controllers/` - Controller-specific documentation
  - `/models/` - Model-specific documentation
  - `/deployment/` - Deployment and server setup guides
  - `/system/` - System-level documentation
  - `/themes/` - Theme system documentation
  - `/tutorials/` - User and developer tutorials
  - `/general/` - General documentation
  - `/scripts/` - Documentation-related scripts

## Documentation Standards

1. **File Location**: All documentation files should be placed in the appropriate subdirectory of `/Comserv/root/Documentation/`.

2. **File Format**: Documentation files should be written in Markdown format with the `.md` extension.

3. **File Naming**:
   - Use lowercase with underscores for spaces
   - For changelog entries, use the format: `YYYY-MM-description.md`
   - For controller documentation, use the controller name: `ControllerName.md`

4. **Documentation Structure**:
   - Start with a clear title using `# Title`
   - Include an overview section
   - Use appropriate headings for sections
   - Include code examples where relevant
   - Link to related documentation

## Documentation Migration

A script has been created to help migrate documentation files from the application root to the proper documentation directory structure:

```
/Comserv/root/Documentation/scripts/move_docs_to_proper_location.pl
```

This script:
1. Identifies documentation files in the application root
2. Determines the appropriate destination based on file content and name
3. Moves the files to the correct location in the documentation directory structure
4. Removes the "Formatting title from: " prefix from filenames

## Accessing Documentation

Documentation can be accessed through:

1. The Documentation controller in the web interface
2. Direct file access in the codebase
3. Version control system (e.g., Git)

## Maintaining Documentation

When updating the system:

1. Update relevant documentation files
2. Create changelog entries for significant changes
3. Ensure documentation is placed in the correct location
4. Keep the documentation structure consistent

## Related Files

- `/Comserv/root/Documentation/scripts/move_docs_to_proper_location.pl` - Script for migrating documentation
- `/Comserv/lib/Comserv/Controller/Documentation.pm` - Documentation controller
- `/Comserv/root/Documentation/controllers/Documentation_Controller.md` - Documentation controller documentation