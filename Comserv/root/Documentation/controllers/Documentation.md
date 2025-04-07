# Documentation Controller

**Last Updated:** May 15, 2025  
**Author:** Shanta  
**Status:** Active

## Overview
The Documentation controller manages the documentation system for the Comserv application. It handles loading, categorizing, and displaying documentation files based on user roles and site context.

## Key Features
- Scans and indexes documentation files
- Categorizes documentation by type and role
- Provides access control based on user roles
- Renders documentation pages with appropriate templates
- Uses JSON configuration for documentation management
- Supports multiple file formats (Markdown, Template Toolkit)
- Logs documentation processing for debugging

## Controller Structure

### Attributes
- `logging`: Logging utility instance
- `documentation_pages`: Hash storing all documentation pages with metadata
- `documentation_categories`: Hash storing documentation categories and their properties

### Methods
- `BUILD`: Initialization method that scans and categorizes documentation
- `index`: Main entry point for the documentation system
- `view`: Displays a specific documentation page
- `category`: Displays documentation for a specific category
- `_format_title`: Formats file names into readable titles
- `_scan_directories`: Scans directories for documentation files
- `_categorize_pages`: Categorizes documentation pages
- `_load_config`: Loads the documentation configuration from JSON

## Documentation Processing Flow

1. **Initialization**:
   - The controller is initialized when the application starts
   - The `BUILD` method is called automatically
   - Documentation directories are scanned
   - Files are categorized based on location and content

2. **Request Handling**:
   - When a user requests the documentation page, the `index` method is called
   - Documentation is filtered based on user role and site
   - The appropriate template is rendered with the filtered documentation

3. **Page Viewing**:
   - When a user requests a specific documentation page, the `view` method is called
   - The page is retrieved from the `documentation_pages` hash
   - Access control is applied based on user role and site
   - The page is rendered with the appropriate template

## Configuration

The controller uses a JSON configuration file (`documentation_config.json`) to manage documentation categories and file paths:

```json
{
  "categories": {
    "user_guides": {
      "title": "User Guides",
      "description": "Documentation for end users",
      "roles": ["normal", "editor", "admin", "developer"],
      "site_specific": false,
      "pages": ["getting_started", "account_management", ...]
    },
    ...
  },
  "default_paths": {
    "getting_started": "Documentation/roles/normal/getting_started.md",
    "account_management": "Documentation/roles/normal/account_management.md",
    ...
  }
}
```

## Access Control
This controller implements role-based access control:

- **Normal Users**: Can see user guides and tutorials
- **Editors**: Can see user guides, tutorials, and editor-specific documentation
- **Admins**: Can see all documentation except developer-specific content
- **Developers**: Can see all documentation
- **CSC Site Admins**: Can see ALL documentation across all sites

## Debugging

The controller includes debugging features:

- **Logging**: All documentation scanning and categorization is logged
- **Debug Messages**: Debug messages are pushed to the stash and can be displayed in templates
- **Error Handling**: Errors during documentation processing are logged

## Related Files
- Documentation templates in `/root/Documentation/`
- Documentation configuration in `/root/Documentation/documentation_config.json`
- Documentation scanning module in `Comserv::Controller::Documentation::ScanMethods`

## Recent Enhancements
- Added support for JSON configuration
- Improved categorization logic
- Enhanced role-based access control
- Added support for site-specific documentation
- Implemented modular template structure
- Added debug message system

## Future Improvements
- Add full-text search capability
- Implement version control for documentation
- Add user feedback mechanism
- Enhance mobile responsiveness
- Implement documentation analytics