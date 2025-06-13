# Git Pull Guide for Administrators

## Overview

The Git Pull feature allows administrators to update the application with the latest code from the Git repository. This guide explains how to use this feature and understand its special handling of configuration files.

## Accessing the Git Pull Feature

1. Log in with an administrator account
2. Navigate to the Admin Dashboard
3. Click on the "Git Pull" button

## Using Git Pull

The Git Pull page provides:

1. A confirmation screen with information about the operation
2. Details about how configuration files will be handled
3. A button to execute the pull operation
4. Detailed output of the Git commands

## Special Handling of theme_mappings.json

The system automatically handles changes to the `theme_mappings.json` file:

1. Local changes are detected and backed up
2. Changes are stashed before pulling
3. After pulling, local changes are reapplied
4. If conflicts occur, you can restore from the backup

This special handling ensures that your local theme configurations are preserved while still getting the latest code updates.

## Understanding the Output

After executing a Git pull, you'll see:

- **Success Message**: Confirms the pull was successful
- **Warning Message**: Indicates if there were conflicts or issues
- **Git Command Output**: Shows the detailed output from Git
- **Debug Information**: (When in debug mode) Shows additional technical details

## Handling Conflicts

If conflicts occur during the pull:

1. A warning message will be displayed
2. Check the backup file at `Comserv/root/static/config/theme_mappings.json.bak`
3. Manually resolve conflicts if needed
4. Consider documenting production-specific configurations

## Best Practices

1. **Regular Updates**: Pull regularly to avoid large divergences
2. **Backup First**: Consider backing up the entire application before major updates
3. **Test After Pull**: Verify the application works correctly after pulling
4. **Check Logs**: Review application logs for any errors after updating

## Troubleshooting

If you encounter issues:

1. **Permission Errors**: Ensure the web server has write permissions to the repository
2. **Merge Conflicts**: Use the backup files to restore or manually resolve conflicts
3. **Application Errors**: Check the application logs for errors after pulling
4. **Stash Issues**: Use `git stash list` and `git stash apply` to manage stashed changes manually

## Related Documentation

- [Theme Mappings Handling](theme_mappings_handling.md)
- [Server Restart Guide](starman_restart_guide.md)
- [Configuration Management](system_overview.md)