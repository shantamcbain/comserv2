# Documentation Controller Technical Reference

## Overview

The Documentation Controller (`Comserv::Controller::Documentation`) is responsible for scanning, organizing, and displaying documentation files in the Comserv system. This document provides technical details about how the controller works and how to modify or extend it.

## Controller Structure

The Documentation controller is implemented as a Catalyst controller with the following key components:

1. **Attributes**: Stores documentation pages, categories, and other metadata
2. **Initialization**: Scans directories for documentation files during startup
3. **Request Handling**: Processes requests to view documentation
4. **Helper Methods**: Provides utility functions for formatting and categorization

## Key Methods

### `BUILD`

The `BUILD` method is called when the controller is initialized. It:

1. Sets up logging
2. Defines helper functions for key generation
3. Initializes documentation categories
4. Scans documentation directories
5. Processes and categorizes documentation files

### `index`

The `index` method handles requests to the main documentation page. It:

1. Gets the current user's role and site
2. Filters documentation based on user role and site
3. Sorts documentation alphabetically by title
4. Creates a structured list of documentation pages
5. Passes data to the template for rendering

### `view`

The `view` method handles requests to view specific documentation files. It:

1. Checks if the requested page exists
2. Verifies the user has permission to view the page
3. Renders the documentation content
4. Handles different file types (Markdown, Template Toolkit, etc.)

### `_format_title`

The `_format_title` method formats page names into readable titles. It:

1. Converts underscores and hyphens to spaces
2. Removes file extensions
3. Capitalizes each word
4. Handles special cases for acronyms (API, KVM, etc.)

## Documentation Categories

The controller defines several documentation categories:

```perl
has documentation_categories => (
    is      => 'rw',
    default => sub {
        {
            user_guides => {
                title => 'User Documentation',
                description => 'Documentation for end users of the Comserv system.',
                roles => ['normal', 'editor', 'admin', 'developer'],
                pages => [],
            },
            tutorials => {
                title => 'Tutorials',
                description => 'Step-by-step guides for common tasks.',
                roles => ['normal', 'editor', 'admin', 'developer'],
                pages => [],
            },
            site_specific => {
                title => 'Site-Specific Documentation',
                description => 'Documentation specific to this site.',
                roles => ['normal', 'editor', 'admin', 'developer'],
                site_specific => 1,
                pages => [],
            },
            admin_guides => {
                title => 'Administrator Guides',
                description => 'Documentation for system administrators.',
                roles => ['admin'],
                pages => [],
            },
            proxmox => {
                title => 'Proxmox Documentation',
                description => 'Documentation for Proxmox virtualization.',
                roles => ['admin'],
                pages => [],
            },
            controllers => {
                title => 'Controller Documentation',
                description => 'Documentation for system controllers.',
                roles => ['admin', 'developer'],
                pages => [],
            },
            changelog => {
                title => 'Changelog',
                description => 'System changes and updates.',
                roles => ['admin', 'developer'],
                pages => [],
            },
            general => {
                title => 'All Documentation',
                description => 'Complete list of all documentation files.',
                roles => ['admin'],
                pages => [],
            },
        }
    },
    lazy => 1,
);
```

## File Scanning Process

The controller scans documentation files using the following process:

1. Starts with the main documentation directory (`root/Documentation`)
2. Uses `File::Find` to recursively scan all subdirectories
3. Processes each file with a supported extension (.md, .tt, .html, .txt)
4. Generates a unique key for each file
5. Extracts metadata from the file (title, description, etc.)
6. Categorizes the file based on its path and content
7. Adds the file to the appropriate categories

## Categorization Logic

Files are categorized based on:

1. **Path**: Files in specific directories (e.g., `/roles/admin/`) are automatically categorized
2. **Filename**: Files with specific patterns in their names are categorized accordingly
3. **Content**: Files can be categorized based on their content (not currently implemented)

## Sorting Logic

Documentation is sorted alphabetically by title using:

```perl
# Sort pages alphabetically by title
my @sorted_pages = sort { 
    lc($self->_format_title($a)) cmp lc($self->_format_title($b)) 
} keys %filtered_pages;
```

## Template Integration

The controller passes the following data to the template:

```perl
$c->stash(
    documentation_pages => \%filtered_pages,
    structured_pages => $structured_pages,
    sorted_page_names => \@sorted_pages,
    completed_items => $completed_items,
    categories => \%filtered_categories,
    user_role => $user_role,
    site_name => $site_name,
    template => 'Documentation/index.tt'
);
```

## Extending the Controller

### Adding a New Category

To add a new category:

1. Add the category to the `documentation_categories` attribute
2. Update the categorization logic in the `scan_dirs` function
3. Update the template to display the new category

### Supporting a New File Type

To support a new file type:

1. Update the file scanning regex to include the new extension
2. Add handling for the new file type in the `generate_key` function
3. Update the `view` method to properly render the new file type

### Modifying Sorting Behavior

To change how documentation is sorted:

1. Update the sorting logic in the `index` method
2. Update the `_format_title` method if needed
3. Consider adding client-side sorting in the template

## Troubleshooting

### Common Issues

1. **Missing Documentation**: Check that the file exists and has a supported extension
2. **Incorrect Categorization**: Verify the file path and name match the categorization rules
3. **Permission Issues**: Ensure the user has the appropriate role to view the documentation
4. **Sorting Problems**: Check the `_format_title` method and sorting logic

### Debugging

The controller includes extensive logging. To debug issues:

1. Enable debug mode in the application
2. Check the logs for messages from the Documentation controller
3. Look for errors in the file scanning and categorization process

## Performance Considerations

The Documentation controller scans all files during initialization, which can impact startup time for large documentation sets. Consider:

1. Implementing caching for documentation metadata
2. Lazy-loading documentation content
3. Optimizing the file scanning process for large directories