# Documentation Editor Guide

## Overview

The Documentation Editor is a new feature that allows administrators and editors to create, edit, and manage documentation files directly within the Comserv application. This guide explains how to use the Documentation Editor and how it helps prevent documentation files from being created in the wrong location.

## Accessing the Documentation Editor

1. Log in with an administrator or editor account
2. Navigate to `/documentation_editor` in your browser
3. You will see a list of all existing documentation files

## Creating New Documentation

1. Click the "Create New Documentation" button
2. Fill in the following fields:
   - **Title**: The title of the documentation page
   - **Category**: Select the appropriate category for the documentation
   - **Roles**: Select which user roles can access this documentation
   - **Site**: Select which site this documentation is for (or "All Sites")
   - **Content**: Write your documentation content using Markdown syntax
3. Click "Create Documentation" to save the file

## Editing Existing Documentation

1. Find the documentation file you want to edit in the list
2. Click the "Edit" button next to the file
3. Make your changes to the content or metadata
4. Click "Update Documentation" to save your changes

## Viewing Documentation

1. Find the documentation file you want to view in the list
2. Click the "View" button next to the file
3. The documentation will open in a new tab using the standard Documentation viewer

## Deleting Documentation

1. Find the documentation file you want to delete in the list
2. Click the "Delete" button next to the file
3. Confirm the deletion when prompted

## Preventing Documentation Files in the Application Root

The system now includes automatic cleanup scripts that run when the server starts to prevent documentation files from accumulating in the application root. These scripts:

1. Identify files with patterns like "Formatting title from: filename.md" in the application root
2. Move these files to the appropriate location in the Documentation directory structure
3. Clean up any temporary or categorization files

## Best Practices

1. **Always use the Documentation Editor**: Create and edit documentation files using the Documentation Editor rather than creating them manually or through external tools.

2. **Choose the right category**: Select the appropriate category for your documentation to ensure it appears in the right section of the Documentation system.

3. **Set appropriate roles**: Make sure to set the correct roles for your documentation to ensure it's visible to the right users.

4. **Use Markdown formatting**: The Documentation Editor supports Markdown syntax for formatting your content. Use headings, lists, links, and other Markdown features to make your documentation more readable.

5. **Preview before saving**: Use the Preview button to see how your documentation will look before saving it.

## Troubleshooting

If you encounter any issues with the Documentation Editor:

1. **File not saving**: Make sure you have filled in all required fields (Title and Content).

2. **File not appearing in the list**: Try refreshing the page. If the file still doesn't appear, check if you have the necessary permissions.

3. **Files still appearing in application root**: The cleanup scripts run when the server starts. If you notice files in the application root, try restarting the server or manually running the cleanup scripts:
   ```
   cd /home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation/scripts
   ./cleanup_categorization_files.pl
   ./move_docs_to_proper_location.pl
   ```

## Related Documentation

- [Documentation System Overview](/Documentation/documentation_system_overview)
- [Documentation Filename Issue](/Documentation/documentation_filename_issue)
- [Markdown Syntax Guide](/Documentation/markdown_syntax_guide)