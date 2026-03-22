# Unused Templates

This directory contains template files that are not currently connected to any controller or actively used in the application.

## Files

### database_config.tt
**Original Location**: `root/templates/admin/database_config.tt`  
**Moved On**: February 10, 2026  
**Reason**: No controller references this template. Appears to be a planned feature for managing database connection profiles that was never implemented.

**Purpose**: Comprehensive database configuration management UI for editing connection profiles across different environments (production, workstation, remote, etc.).

**To Activate**: Create a controller at `lib/Comserv/Controller/Admin/DatabaseConfig.pm` that sets `template => 'admin/database_config.tt'` and move this file back to `root/admin/database_config.tt`.

## Related Templates In Use

- `root/admin/database.tt` - Current operational database management (table status, create/drop operations)
- `root/admin/database-sync/*.tt` - Database synchronization features
