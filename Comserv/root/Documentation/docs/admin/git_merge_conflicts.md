# Handling Git Merge Conflicts on Production Servers

## Overview

This guide explains how to handle Git merge conflicts on production servers where you don't have direct commit access to the GitHub repository.

## Problem

When running `git pull` on a production server, you might encounter an error like:

```
error: Your local changes to the following files would be overwritten by merge:
    Comserv/root/static/config/theme_mappings.json
Please commit your changes or stash them before you merge.
Aborting
```

This happens when:
1. Local changes have been made to files on the production server
2. Those same files have been modified in the remote repository
3. Git cannot automatically merge the changes

## Solutions

### Option 1: Stash Local Changes and Apply After Pull (Recommended)

This approach temporarily saves your local changes, pulls the remote changes, and then reapplies your local changes.

```bash
# Save local changes to stash with a descriptive message
git stash save "Local changes to theme_mappings.json"

# Pull the remote changes
git pull

# View the stashed changes
git stash show -p

# Apply the stashed changes back
git stash apply

# If there are conflicts, resolve them manually
# Then remove the stash when done
git stash drop
```

### Option 2: Create a Backup and Force Pull

If you're comfortable with manual merging:

```bash
# Create a backup of the file
cp Comserv/root/static/config/theme_mappings.json Comserv/root/static/config/theme_mappings.json.bak

# Discard local changes and pull
git checkout -- Comserv/root/static/config/theme_mappings.json
git pull

# Manually merge your changes from the backup
# Use a diff tool or text editor to compare and merge
```

### Option 3: Use Git's Merge Tool

If you need more sophisticated merging:

```bash
# Tell Git to attempt a merge even with local changes
git pull --no-commit

# If conflicts occur, use a merge tool
git mergetool

# After resolving conflicts
git commit -m "Merged remote changes with local modifications"
```

## Best Practices for Production Servers

1. **Avoid making direct changes to production files** - Instead, make changes in development and push through Git
2. **Document all local changes** - Keep a log of any emergency fixes made directly on production
3. **Set up proper deployment workflows** - Use CI/CD pipelines when possible
4. **Regular backups** - Always back up critical configuration files before updates
5. **Use environment-specific configuration** - Consider using environment variables or separate config files for production-specific settings

## Logging Changes

When making emergency changes on production, always:

1. Document what was changed and why
2. Create a ticket or issue to implement the same change properly through Git
3. Add detailed comments in the code about the emergency change
4. Use the application's logging system to record the change:

```perl
$c->log->info("Emergency fix applied to theme_mappings.json: [details of change]");
push @{$c->stash->{debug_msg}}, "Applied emergency configuration fix to theme mappings";
```

## Getting Help

If you encounter complex merge conflicts that you're unsure how to resolve, contact the development team for assistance rather than risking data loss or application instability.