# Changelog

## [Unreleased] - Bug Fix Update

### Fixed

#### Proxmox Module
- Fixed duplicate method declarations in the Proxmox model that were causing unexpected behavior
- Corrected indentation errors in the `_get_real_vms_new` method
- Added missing `token` attribute for backward compatibility
- Improved token handling consistency across methods

#### Admin Controller
- Fixed undeclared `$output` variable in the `add_schema` method
- Resolved duplicate `edit_documentation` method definition
- Added proper import for Fcntl constants (O_WRONLY, O_APPEND, O_CREAT)
- Enhanced debug logging in the `edit_documentation` method

#### Dependency Management
- Identified issue with `Net::CIDR` module not being automatically installed despite being listed in cpanfile
- Manual installation was required to resolve "Can't locate Net/CIDR.pm" error
- **TODO**: Fix cpanfile dependency resolution in a future update

### Added
- Added comprehensive documentation for bug fixes
- Created technical documentation for developers
- Added this changelog to track future changes

### Changed
- Updated the `edit_documentation` method to include debug messages in the stash
- Improved error handling in the `add_schema` method

## How to Verify the Fixes

1. **Proxmox Integration**:
   - Log in to the admin interface
   - Navigate to any Proxmox-related functionality
   - Verify that VM listings and operations work correctly

2. **Schema Management**:
   - Go to the schema management page
   - Try to add a new schema
   - Verify that success/error messages are displayed correctly

3. **Documentation Editing**:
   - Navigate to the documentation editing page at `/admin/edit_documentation`
   - Verify that the page loads correctly
   - Check that any changes can be saved properly

4. **Log Rotation**:
   - Access the log viewing page
   - Try rotating the logs
   - Verify that the operation completes without errors

## Notes for Administrators

These fixes address several issues that were causing errors in the application logs. No database changes or configuration changes are required. Simply deploy the updated code to your server.

If you encounter any issues after deploying these fixes, please check the application logs for any new error messages and report them to the development team.