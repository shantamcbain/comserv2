# Theme Mappings Handling in Git Pull

## Overview

The Comserv system has been enhanced to automatically handle changes to the `theme_mappings.json` file during Git pull operations. This feature is particularly useful for production servers where local theme configurations may differ from the repository version.

## How It Works

When you use the Admin Git Pull feature, the system will:

1. Detect if you have local changes to `theme_mappings.json`
2. Create a backup of your local version at `theme_mappings.json.bak`
3. Stash your changes using Git's stash functionality
4. Pull the latest changes from the repository
5. Attempt to reapply your local changes automatically
6. Provide clear feedback about the process

## Benefits

- **Preserves Local Customizations**: Your site-specific theme mappings are preserved
- **Reduces Merge Conflicts**: Handles the common conflict scenario automatically
- **Provides Safety Nets**: Creates backups before any operations
- **Improves Workflow**: No need to manually stash/unstash or resolve conflicts

## Handling Conflicts

If there are conflicts between your local changes and the repository version:

1. The system will notify you with a warning message
2. Your original file is preserved as `theme_mappings.json.bak`
3. You can manually resolve the conflict by:
   - Editing the current file to merge changes
   - Restoring from the backup if needed
   - Using Git's conflict resolution tools

## Best Practices

While this feature helps manage theme configuration conflicts, consider these best practices:

1. **Database Storage**: For a more robust solution, consider moving theme mappings to the database
2. **Environment Configuration**: Use environment-specific configuration files that are excluded from Git
3. **Documentation**: Document any production-specific theme mappings for reference

## Troubleshooting

If you encounter issues with the automatic handling:

1. Check the backup file at `Comserv/root/static/config/theme_mappings.json.bak`
2. View the Git stash with `git stash list` to see if your changes were saved
3. Apply the stash manually with `git stash apply` if needed
4. Check the application logs for detailed error messages

## Future Enhancements

Future versions may include:

1. Database-driven theme configuration
2. Environment-specific configuration files
3. Web interface for managing theme mappings
4. More sophisticated conflict resolution