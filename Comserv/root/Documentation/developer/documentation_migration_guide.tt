---
title: "Documentation Migration Guide"
description: "Guide for developers on using the new documentation system during migration"
author: "System Administrator"
date: "2025-05-30"
status: "Active"
roles: ["admin", "developer"]
sites: ["all"]
categories: ["developer_guides", "admin_guides"]
tags: ["documentation", "migration", "metadata"]
---

# Documentation Migration Guide

## Overview

This guide explains how to work with the Comserv documentation system during the migration from the old directory-based structure to the new metadata-driven approach. It provides instructions for creating new documentation, updating existing documentation, and understanding the migration process.

## Migration Timeline

The documentation system migration will occur in phases over several months:

1. **Phase 1: Preparation** (June 2025)
   - Create new directory structure
   - Develop metadata parser
   - Update configuration file

2. **Phase 2: Migration Tool Development** (July 2025)
   - Create migration script
   - Test migration script
   - Develop Documentation controller updates

3. **Phase 3: Gradual Migration** (August-September 2025)
   - Migrate changelog documentation
   - Migrate user documentation
   - Migrate admin documentation
   - Migrate developer documentation
   - Migrate site-specific documentation

4. **Phase 4: Template Updates** (October 2025)
   - Update documentation templates
   - Create new template components

5. **Phase 5: Testing and Deployment** (November 2025)
   - Comprehensive testing
   - User acceptance testing
   - Final deployment

6. **Phase 6: Cleanup and Optimization** (December 2025)
   - Remove old structure
   - Optimize performance
   - Document the new system

## Creating New Documentation During Migration

During the migration period, new documentation should be created using the new metadata-driven approach to ensure a smooth transition.

### Step 1: Choose the Appropriate Location

Place new documentation files in the appropriate directory under the new structure:

```
/root/Documentation/docs/{category}/{filename}.md
```

For example:
- User documentation: `/root/Documentation/docs/user/new_feature_guide.md`
- Admin documentation: `/root/Documentation/docs/admin/system_configuration.md`
- Site-specific documentation: `/root/Documentation/docs/site/mcoop/member_management.md`

### Step 2: Include Metadata

Add the following metadata section at the top of your documentation file:

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

#### Required Metadata Fields:

- **title**: The title of the document (should match the H1 heading)
- **description**: A brief description of the document content
- **author**: Your name or username
- **date**: The creation date in YYYY-MM-DD format
- **status**: One of "Active", "Draft", or "Deprecated"
- **roles**: Array of roles that can access this document (normal, editor, admin, developer)
- **sites**: Array of sites this document applies to ("all" for all sites, or specific site names)
- **categories**: Array of categories this document belongs to (from the configuration file)

#### Optional Metadata Fields:

- **tags**: Array of tags for additional categorization
- **version**: Document version number
- **related**: Array of related document filenames

### Step 3: Write Content

Follow the standard documentation format:

1. Start with a level 1 heading (# Title) that matches the title in the metadata
2. Include an Overview section
3. Use level 2 headings (## Heading) for main sections
4. Use level 3 headings (### Subheading) for subsections
5. Include code examples, screenshots, and diagrams as needed
6. End with a Related Documentation section if applicable

### Step 4: Update Current Configuration

Until the new controller is fully implemented, also add the document to the current `documentation_config.json` file:

1. Add the document key to the appropriate category in the "categories" section
2. Add the document path to the "default_paths" section

Example:

```json
{
  "categories": {
    "developer_guides": {
      "pages": ["existing_page_1", "your_new_document"]
    }
  },
  "default_paths": {
    "your_new_document": "Documentation/docs/developer/your_new_document.md"
  }
}
```

This ensures the document is accessible through both the old and new systems during the transition period.

## Updating Existing Documentation

When updating existing documentation, follow these guidelines:

### For Documentation Not Yet Migrated

1. Update the file in its current location
2. When the file is migrated, the changes will be preserved

### For Already Migrated Documentation

1. Update the file in the new location (`/root/Documentation/docs/...`)
2. Ensure the metadata section is preserved
3. Update the metadata if necessary (e.g., change status, add tags)

## Using the Documentation Template

A template for new documentation is available at:

```
/root/Documentation/docs/templates/documentation_template.md
```

This template includes:
- Properly formatted metadata section
- Standard document structure
- Examples of formatting (code blocks, lists, tables, etc.)
- Example user and admin guides

Copy this template when creating new documentation to ensure consistency.

## Migration Script

A migration script is available to help migrate existing documentation to the new structure:

```
/root/Documentation/scripts/migrate_documentation.pl
```

This script:
1. Reads existing documentation files
2. Extracts metadata from file content and directory location
3. Generates new files with proper metadata in the new structure

**Note:** This script is intended for use by the documentation team during the migration process. Do not run it on your own unless instructed to do so.

## Accessing Documentation During Migration

During the migration period, documentation will be accessible through both the old and new systems:

### Old System

- Access via `/documentation` URL
- Uses the current directory structure and configuration
- All existing documentation remains accessible

### New System (When Available)

- Access via `/documentation/new` URL
- Uses the new metadata-driven approach
- Only migrated and new documentation will be available

## Testing the New System

When the new system becomes available for testing:

1. Access it via `/documentation/new`
2. Test that your documentation is properly categorized and accessible
3. Verify that role-based access control works correctly
4. Report any issues to the documentation team

## Reporting Issues

If you encounter issues with the documentation system during migration:

1. Check the application logs for error messages
2. Report the issue to the documentation team with:
   - Description of the issue
   - Steps to reproduce
   - Expected vs. actual behavior
   - Any error messages from the logs

## Best Practices During Migration

1. **Follow the New Format**: Always use the new metadata format for new documentation
2. **Update Both Systems**: Update both the new file and the configuration file
3. **Test Visibility**: Verify that your documentation is visible to the intended audience
4. **Use the Template**: Use the provided template for consistency
5. **Ask for Help**: Contact the documentation team if you're unsure about anything

## After Migration

Once the migration is complete:

1. All documentation will be in the new structure
2. The old directory structure will be removed
3. The documentation system will use the metadata-driven approach exclusively
4. The configuration file will be simplified to focus on category definitions

## Related Documentation

- [Documentation Structure Simplification Plan](/Documentation/changelog/2025-05-30-documentation-structure-simplification.md)
- [Documentation Template](/Documentation/docs/templates/documentation_template.md)
- [Documentation System Overview](/Documentation/documentation_system.md)