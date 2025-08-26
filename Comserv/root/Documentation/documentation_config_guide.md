# Documentation Configuration Guide

**Last Updated:** May 15, 2025  
**Author:** Shanta  
**Status:** Active

## Overview

The documentation system in Comserv uses a central configuration file (`documentation_config.json`) to manage documentation categories and file paths. This document explains the structure and usage of this configuration file.

## File Location

The configuration file is located at:
```
/root/Documentation/documentation_config.json
```

## Configuration Structure

The configuration file has two main sections:

1. **Categories**: Defines all documentation categories and their properties
2. **Default Paths**: Maps documentation keys to file paths

### Categories Section

The categories section defines all documentation categories and their properties:

```json
"categories": {
  "user_guides": {
    "title": "User Guides",
    "description": "Documentation for end users of the system",
    "roles": ["normal", "editor", "admin", "developer"],
    "site_specific": false,
    "pages": ["getting_started", "account_management", "customizing_profile"]
  },
  "admin_guides": {
    "title": "Administrator Guides",
    "description": "Documentation for system administrators",
    "roles": ["admin", "developer"],
    "site_specific": false,
    "pages": ["admin_guide", "user_management", "documentation_role_access"]
  }
}
```

Each category has the following properties:

- **title**: The display title for the category
- **description**: A brief description of the category
- **roles**: An array of roles that can access this category
- **site_specific**: Boolean indicating if the category is site-specific
- **pages**: An array of documentation keys that belong to this category

### Default Paths Section

The default paths section maps documentation keys to file paths:

```json
"default_paths": {
  "getting_started": "Documentation/roles/normal/getting_started.md",
  "account_management": "Documentation/roles/normal/account_management.md",
  "customizing_profile": "Documentation/tutorials/customizing_profile.md",
  "admin_guide": "Documentation/roles/admin/admin_guide.md",
  "user_management": "Documentation/roles/admin/user_management.md"
}
```

Each entry maps a documentation key to its file path relative to the `root` directory.

## Usage

### Adding a New Documentation File

To add a new documentation file to the system:

1. Create the documentation file in the appropriate directory
2. Add an entry to the default_paths section:
   ```json
   "new_document": "Documentation/path/to/new_document.md"
   ```
3. Add the document key to the appropriate category's pages array:
   ```json
   "categories": {
     "category_name": {
       "pages": ["existing_page_1", "existing_page_2", "new_document"]
     }
   }
   ```

### Moving a Documentation File

To move a documentation file:

1. Move the file to the new location
2. Update the path in the default_paths section:
   ```json
   "document_key": "Documentation/new/path/to/document.md"
   ```

### Creating a New Category

To create a new documentation category:

1. Add a new entry to the categories section:
   ```json
   "new_category": {
     "title": "New Category Title",
     "description": "Description of the new category",
     "roles": ["role1", "role2"],
     "site_specific": false,
     "pages": ["document_key_1", "document_key_2"]
   }
   ```
2. Ensure all document keys in the pages array have corresponding entries in the default_paths section

## Best Practices

1. **Consistent Naming**: Use consistent naming conventions for documentation keys
2. **Correct Paths**: Ensure all paths in the default_paths section are correct
3. **Role Assignment**: Assign appropriate roles to each category
4. **Category Organization**: Organize documentation into logical categories
5. **Regular Updates**: Update the configuration file when adding, moving, or removing documentation
6. **Testing**: Test documentation visibility after making changes to the configuration

## Troubleshooting

If documentation is not appearing as expected:

1. Check that the document key is in the appropriate category's pages array
2. Verify that the path in the default_paths section is correct
3. Ensure the file exists at the specified path
4. Check that the user has the appropriate role to view the category
5. Enable debug mode to see more detailed information about documentation loading

## Example Configuration

Here's a complete example of a documentation_config.json file:

```json
{
  "categories": {
    "user_guides": {
      "title": "User Guides",
      "description": "Documentation for end users of the system",
      "roles": ["normal", "editor", "admin", "developer"],
      "site_specific": false,
      "pages": ["getting_started", "account_management", "customizing_profile"]
    },
    "admin_guides": {
      "title": "Administrator Guides",
      "description": "Documentation for system administrators",
      "roles": ["admin", "developer"],
      "site_specific": false,
      "pages": ["admin_guide", "user_management", "documentation_role_access"]
    },
    "developer_guides": {
      "title": "Developer Documentation",
      "description": "Documentation for developers",
      "roles": ["developer"],
      "site_specific": false,
      "pages": ["api_reference", "authentication_system", "template_system"]
    }
  },
  "default_paths": {
    "getting_started": "Documentation/roles/normal/getting_started.md",
    "account_management": "Documentation/roles/normal/account_management.md",
    "customizing_profile": "Documentation/tutorials/customizing_profile.md",
    "admin_guide": "Documentation/roles/admin/admin_guide.md",
    "user_management": "Documentation/roles/admin/user_management.md",
    "documentation_role_access": "Documentation/developer/documentation_role_access.md",
    "api_reference": "Documentation/roles/developer/api_reference.md",
    "authentication_system": "Documentation/developer/authentication_system.md",
    "template_system": "Documentation/developer/template_system.md"
  }
}
```

## Technical Implementation

The documentation system loads this configuration file during initialization and uses it to:

1. Define documentation categories and their properties
2. Map documentation keys to file paths
3. Determine which documentation is visible to which users
4. Organize documentation into logical categories

The configuration is loaded by the `_load_config` method in the Documentation controller.