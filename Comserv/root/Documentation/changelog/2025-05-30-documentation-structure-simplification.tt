# Documentation Structure Simplification Plan

**Date:** May 30, 2025  
**Author:** System Administrator  
**Status:** Planned

## Overview

This document outlines a comprehensive plan to simplify the Comserv documentation directory structure while maintaining the ability to filter documents by role, site name, and other criteria. The current documentation system has become complex with nested directories and redundant organization methods, making it difficult to manage and maintain. This plan proposes a metadata-driven approach that will streamline documentation management while preserving all existing functionality.

## Current Issues

1. **Complex Directory Hierarchy**: The current structure has many nested directories (roles/admin, roles/normal, sites/mcoop, etc.) which makes file management difficult.

2. **Redundant Organization**: Files are organized both by directory structure and by configuration in `documentation_config.json`, creating redundancy.

3. **Maintenance Overhead**: Adding new documentation requires updating both the file structure and the configuration file.

4. **Inconsistent Categorization**: Some files are categorized by directory location, others by filename patterns.

5. **Scattered Documentation**: Documentation files are spread across multiple directories, making it hard to find specific documents.

## Proposed Solution

We will implement a simplified directory structure that relies on metadata in the files themselves rather than complex directory hierarchies, while maintaining the ability to filter by role, site, and other criteria.

### 1. Simplified Directory Structure

```
/root/Documentation/
  ├── docs/                  # All documentation files in one directory
  │   ├── user/              # User-related documentation
  │   ├── admin/             # Admin-related documentation
  │   ├── developer/         # Developer-related documentation
  │   ├── site/              # Site-specific documentation
  │   │   ├── mcoop/         # MCOOP site documentation
  │   │   └── other-sites/   # Other site-specific documentation
  │   ├── module/            # Module-specific documentation
  │   └── changelog/         # Changelog entries
  ├── templates/             # Template files (.tt) for documentation display
  │   ├── components/        # Reusable template components
  │   └── categories/        # Category-specific templates
  ├── config/                # Configuration files
  │   └── documentation_config.json  # Main configuration file
  └── assets/                # Documentation assets (images, etc.)
```

### 2. Enhanced Metadata in Documentation Files

Each documentation file will include enhanced metadata at the top in YAML-style format:

```markdown
---
title: "Document Title"
description: "Brief description of the document"
author: "Author Name"
date: "YYYY-MM-DD"
status: "Active/Draft/Deprecated"
roles: ["normal", "admin", "developer"]
sites: ["all", "MCOOP"]
categories: ["user_guides", "tutorials"]
tags: ["login", "authentication", "security"]
---

# Document Title

Content starts here...
```

### 3. Simplified Configuration File

The `documentation_config.json` file will be simplified to focus on category definitions rather than individual file mappings:

```json
{
  "categories": {
    "user_guides": {
      "title": "User Guides",
      "description": "Documentation for end users of the system",
      "icon": "fas fa-users",
      "display_order": 1
    },
    "admin_guides": {
      "title": "Administrator Guides",
      "description": "Documentation for system administrators",
      "icon": "fas fa-shield-alt",
      "display_order": 2
    },
    "developer_guides": {
      "title": "Developer Documentation",
      "description": "Documentation for developers",
      "icon": "fas fa-code",
      "display_order": 3
    },
    "tutorials": {
      "title": "Tutorials",
      "description": "Step-by-step guides for common tasks",
      "icon": "fas fa-graduation-cap",
      "display_order": 4
    },
    "site_specific": {
      "title": "Site-Specific Documentation",
      "description": "Documentation specific to this site",
      "icon": "fas fa-building",
      "display_order": 5
    },
    "modules": {
      "title": "Module Documentation",
      "description": "Documentation for specific system modules",
      "icon": "fas fa-puzzle-piece",
      "display_order": 6
    },
    "changelog": {
      "title": "Changelog",
      "description": "System changes and updates",
      "icon": "fas fa-history",
      "display_order": 7
    }
  },
  "tags": {
    "login": {
      "title": "Login",
      "description": "Documentation related to login functionality"
    },
    "authentication": {
      "title": "Authentication",
      "description": "Documentation related to authentication"
    }
  }
}
```

### 4. Enhanced Documentation Controller

The Documentation controller will be enhanced to:

1. **Scan for Metadata**: Parse the YAML-style metadata at the top of each document
2. **Build Index**: Create an in-memory index of all documentation with their metadata
3. **Filter by Criteria**: Filter documentation based on role, site, category, and tags
4. **Cache Results**: Cache the documentation index for better performance

## Implementation Plan

### Phase 1: Preparation (June 2025)

1. **Create New Directory Structure**
   - Create the new directory structure in the Documentation directory
   - Set up the templates, config, and assets directories

2. **Develop Metadata Parser**
   - Create a utility to parse YAML-style metadata from documentation files
   - Implement caching for parsed metadata

3. **Update Configuration File**
   - Create the new simplified configuration file structure
   - Define all categories and tags

### Phase 2: Migration Tool Development (July 2025)

1. **Create Migration Script**
   - Develop a script that reads existing documentation files
   - Extract metadata from file content and directory location
   - Generate new files with proper metadata in the new structure

2. **Test Migration Script**
   - Test the migration script on a subset of documentation
   - Verify that metadata is correctly extracted and applied

3. **Develop Documentation Controller Updates**
   - Modify the Documentation controller to work with the new structure
   - Implement the new filtering logic based on metadata

### Phase 3: Gradual Migration (August-September 2025)

1. **Migrate Changelog Documentation**
   - Start with changelog documentation as a test case
   - Verify that the migrated documentation is accessible and properly categorized

2. **Migrate User Documentation**
   - Migrate user-related documentation
   - Update links and references

3. **Migrate Admin Documentation**
   - Migrate admin-related documentation
   - Update links and references

4. **Migrate Developer Documentation**
   - Migrate developer-related documentation
   - Update links and references

5. **Migrate Site-Specific Documentation**
   - Migrate site-specific documentation
   - Update links and references

### Phase 4: Template Updates (October 2025)

1. **Update Documentation Templates**
   - Update templates to work with the new structure
   - Implement new filtering and search functionality in the UI

2. **Create New Template Components**
   - Develop reusable template components for documentation display
   - Implement category-specific templates

### Phase 5: Testing and Deployment (November 2025)

1. **Comprehensive Testing**
   - Test the new system with various roles and sites
   - Verify that all documentation is accessible and properly categorized

2. **User Acceptance Testing**
   - Have users from different roles test the new documentation system
   - Gather feedback and make adjustments

3. **Final Deployment**
   - Deploy the changes to production
   - Monitor for any issues

### Phase 6: Cleanup and Optimization (December 2025)

1. **Remove Old Structure**
   - Once the new system is stable, remove the old directory structure
   - Update any remaining references to the old structure

2. **Optimize Performance**
   - Implement additional caching mechanisms
   - Optimize search functionality

3. **Document the New System**
   - Create documentation about the new documentation system
   - Provide guidelines for creating and managing documentation

## Guidelines for Creating New Documentation During Migration

During the migration period, new documentation should be created using the new metadata-driven approach to ensure a smooth transition. Follow these guidelines when creating new documentation:

### 1. File Location

Place new documentation files in the appropriate directory under the new structure:

```
/root/Documentation/docs/{category}/{filename}.md
```

For example:
- User documentation: `/root/Documentation/docs/user/new_feature_guide.md`
- Admin documentation: `/root/Documentation/docs/admin/system_configuration.md`
- Site-specific documentation: `/root/Documentation/docs/site/mcoop/member_management.md`

### 2. Metadata Format

Include the following metadata at the top of each new documentation file:

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

# Document Title

Content starts here...
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

### 3. Content Guidelines

- Start with a level 1 heading (# Title) that matches the title in the metadata
- Use level 2 headings (## Heading) for main sections
- Use level 3 headings (### Subheading) for subsections
- Include an Overview section at the beginning
- Use code blocks with language specification for code examples
- Include screenshots or diagrams where appropriate
- End with a Related Documentation section if applicable

### 4. Temporary Configuration Update

Until the new controller is fully implemented, also add the document to the current `documentation_config.json` file:

1. Add the document key to the appropriate category in the "categories" section
2. Add the document path to the "default_paths" section

This ensures the document is accessible through both the old and new systems during the transition period.

## Benefits of the New Structure

1. **Simplified Management**: All documentation is in a more logical, flatter structure
2. **Metadata-Driven**: Filtering is based on file metadata rather than directory location
3. **Easier Maintenance**: Adding new documentation only requires adding a file with proper metadata
4. **Better Categorization**: Documents can belong to multiple categories through metadata
5. **Improved Searchability**: Tags provide additional ways to find documentation
6. **Consistent Organization**: All documentation follows the same structure and format
7. **Reduced Redundancy**: No need to update both directory structure and configuration file

## Technical Implementation Details

### Metadata Parser

The metadata parser will:
1. Read the file content
2. Extract the YAML-style metadata between `---` markers
3. Parse the metadata into a structured format
4. Cache the results for better performance

```perl
sub parse_metadata {
    my ($self, $file_path) = @_;
    
    # Read the file content
    open my $fh, '<:encoding(UTF-8)', $file_path or die "Cannot open $file_path: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    
    # Extract metadata
    my $metadata = {};
    if ($content =~ /^---\s*$(.*?)^---\s*$/ms) {
        my $yaml_content = $1;
        
        # Parse YAML-style metadata
        foreach my $line (split /\n/, $yaml_content) {
            if ($line =~ /^\s*(\w+)\s*:\s*"?([^"]*)"?\s*$/) {
                my ($key, $value) = ($1, $2);
                $metadata->{$key} = $value;
            }
            elsif ($line =~ /^\s*(\w+)\s*:\s*\[(.*)\]\s*$/) {
                my ($key, $value_list) = ($1, $2);
                my @values = map { s/^\s*"?//; s/"?\s*$//; $_ } split /,/, $value_list;
                $metadata->{$key} = \@values;
            }
        }
    }
    
    return $metadata;
}
```

### Documentation Controller Updates

The Documentation controller will be updated to:
1. Scan the new directory structure for documentation files
2. Parse metadata from each file
3. Build an in-memory index of all documentation
4. Filter documentation based on user role, site, and other criteria

```perl
sub build_documentation_index {
    my ($self) = @_;
    
    my $docs_dir = $self->path_to('root', 'Documentation', 'docs');
    my $index = {};
    
    find(
        {
            wanted => sub {
                my $file = $_;
                return if -d $file;
                return unless $file =~ /\.(md|tt)$/;
                
                my $metadata = $self->parse_metadata($file);
                my $relative_path = File::Spec->abs2rel($file, $docs_dir);
                
                $index->{$relative_path} = {
                    path => $file,
                    metadata => $metadata
                };
            },
            no_chdir => 1
        },
        $docs_dir
    );
    
    return $index;
}

sub filter_documentation {
    my ($self, $index, $user_role, $site_name) = @_;
    
    my $filtered = {};
    
    foreach my $path (keys %$index) {
        my $doc = $index->{$path};
        my $metadata = $doc->{metadata};
        
        # Check role access
        my $has_role_access = 0;
        if (grep { $_ eq $user_role } @{$metadata->{roles}}) {
            $has_role_access = 1;
        }
        
        # Check site access
        my $has_site_access = 0;
        if (grep { $_ eq 'all' || $_ eq $site_name } @{$metadata->{sites}}) {
            $has_site_access = 1;
        }
        
        # Add to filtered list if user has access
        if ($has_role_access && $has_site_access) {
            $filtered->{$path} = $doc;
        }
    }
    
    return $filtered;
}
```

## Conclusion

This documentation structure simplification plan provides a clear roadmap for transitioning from the current complex directory structure to a more manageable, metadata-driven approach. By implementing this plan in phases over the next several months, we can ensure a smooth transition while maintaining all existing functionality.

The new structure will make documentation management easier, improve searchability, and provide a more consistent experience for both documentation creators and users. The metadata-driven approach allows for more flexible categorization and filtering, making it easier to find relevant documentation based on role, site, category, and tags.

During the migration period, following the guidelines for creating new documentation will ensure that all new content is compatible with both the current and new systems, facilitating a gradual transition without disruption to users.