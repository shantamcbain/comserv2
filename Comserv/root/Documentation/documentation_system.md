# Documentation System

**Last Updated:** April 1, 2025  
**Author:** Shanta  
**Status:** Active

## Overview

The Comserv documentation system provides a structured way to organize and access documentation for different sites, roles, and modules. This document explains how the documentation system works, including visibility rules and organization principles.

## Documentation Types

The system supports several types of documentation:

1. **General Application Documentation**
   - Common features like login, profile customization, etc.
   - Visible to all sites and users
   - Located in the main Documentation directory

2. **Site-Specific Documentation**
   - Documentation specific to a particular site (e.g., MCOOP, CSC)
   - Only visible to users of that specific site
   - Located in the `Documentation/sites/{site_name}` directory

3. **Role-Specific Documentation**
   - Documentation targeted at specific user roles (admin, developer, etc.)
   - Only visible to users with the appropriate role
   - Located in the `Documentation/roles/{role_name}` directory

4. **Module Documentation**
   - Documentation for specific system modules
   - Visibility depends on module access permissions
   - Located in the `Documentation/modules` directory

## Visibility Rules

The documentation system applies the following visibility rules:

1. **CSC Site Administrators**
   - Can see ALL documentation across all sites and roles
   - This is the only user group with complete documentation access

2. **Site-Specific Visibility**
   - Users can only see documentation for their current site
   - General documentation (site = 'all') is visible to all sites

3. **Role-Based Visibility**
   - Users can only see documentation appropriate for their role
   - Higher roles can see documentation for lower roles (e.g., admins can see normal user docs)

4. **Module-Specific Visibility**
   - Module documentation visibility follows the same site and role rules
   - Additional module-specific permissions may apply

## Documentation Organization

Documentation is organized into the following categories:

1. **User Guides**
   - Basic documentation for end users
   - Includes getting started guides and FAQs
   - Visible to all user roles

2. **Administrator Guides**
   - Documentation for system administrators
   - Includes installation and configuration guides
   - Only visible to users with admin role

3. **Developer Documentation**
   - Technical documentation for developers
   - Includes API references and coding standards
   - Only visible to users with developer role

4. **Tutorials**
   - Step-by-step guides for common tasks
   - Visibility depends on the complexity of the task

5. **Site-Specific Documentation**
   - Documentation specific to the current site
   - Only visible to users of that site

6. **Module Documentation**
   - Documentation for specific system modules
   - Visibility depends on module access permissions

## File Formats

The documentation system supports multiple file formats:

1. **Markdown (.md)**
   - Preferred format for most documentation
   - Rendered with syntax highlighting and formatting

2. **Template Toolkit (.tt)**
   - Used for documentation that requires dynamic content
   - Can include variables, conditionals, and other TT features

3. **Other Formats**
   - JSON, HTML, CSS, and other formats are supported
   - Served with appropriate content types

## Best Practices

When creating documentation, follow these best practices:

1. **Proper Placement**
   - Place documentation in the appropriate directory based on its type
   - Use the site-specific directory for site-specific documentation
   - Use the role-specific directory for role-specific documentation

2. **Clear Metadata**
   - Include a clear title, last updated date, and author
   - Specify the status (Active, Draft, Deprecated)
   - Include version information if applicable

3. **Structured Content**
   - Use proper Markdown headings and formatting
   - Include a table of contents for longer documents
   - Use code blocks with language specification for code examples

4. **Comprehensive Coverage**
   - Cover all aspects of the feature or module
   - Include examples and use cases
   - Address common questions and issues

5. **Regular Updates**
   - Keep documentation up-to-date with system changes
   - Note the last updated date in the metadata
   - Archive or clearly mark deprecated documentation

## Adding New Documentation

To add new documentation to the system:

1. **Determine the Type**
   - Is it general, site-specific, role-specific, or module-specific?

2. **Choose the Location**
   - Place the file in the appropriate directory
   - Use a descriptive filename with the appropriate extension

3. **Include Metadata**
   - Add title, author, date, and status at the top of the document

4. **Write the Content**
   - Follow the structured content guidelines
   - Include all necessary information

5. **Test Visibility**
   - Verify that the document is visible to the intended audience
   - Check that it appears in the appropriate category

## Accessing Documentation

Users can access documentation through:

1. **Documentation Index**
   - Available at `/documentation`
   - Shows all documentation visible to the current user

2. **Direct URLs**
   - Access specific documents via `/documentation/page_name`
   - File extensions are optional (e.g., `/documentation/user_guide` or `/documentation/user_guide.md`)

3. **Category Pages**
   - Access category-specific documentation via `/documentation/category/category_name`
   - Shows all documents in that category visible to the current user

4. **Search**
   - Use the documentation search feature to find specific content
   - Searches only within documentation visible to the current user

## Technical Implementation

The documentation system is implemented in the `Documentation.pm` controller with these key components:

1. **Scanning Mechanism**
   - Scans documentation directories on application startup
   - Builds metadata for each documentation file

2. **Filtering Logic**
   - Filters documentation based on user role and site
   - Special case for CSC site admins who can see everything

3. **Rendering System**
   - Renders Markdown files with proper formatting
   - Processes Template Toolkit files with the TT view

4. **Access Control**
   - Enforces visibility rules based on site and role
   - Provides appropriate error messages for unauthorized access

## Future Enhancements

Planned enhancements for the documentation system include:

1. **Improved Search**
   - Full-text search across all documentation
   - Advanced filtering options

2. **Version Control**
   - Track changes to documentation over time
   - View previous versions of documents

3. **User Feedback**
   - Allow users to rate and comment on documentation
   - Collect suggestions for improvements

4. **Interactive Examples**
   - Add interactive code examples and demos
   - Include video tutorials for complex topics

5. **Documentation Analytics**
   - Track which documentation is most frequently accessed
   - Identify gaps in documentation coverage