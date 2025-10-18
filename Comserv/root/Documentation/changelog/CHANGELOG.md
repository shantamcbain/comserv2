# Changelog

## [2025-12-28] - Todo Priority Display Template Consistency Fix

### Fixed

#### Todo System Priority Display
- **Template Dependency Issue** - Fixed priority display template that was dependent on controllers passing specific data
  - **Self-Contained Template**: Made `priority_display.md` template independent by defining priority mapping internally
  - **Consistent Mapping**: Standardized priority system: 1=Critical, 2=When we have time, 3=Urgent, etc.
  - **Improved Maintainability**: Reduced coupling between controllers and views
  - **Universal Compatibility**: All templates using priority display now work regardless of controller support

### Changed
- **Priority Display Template**: `/Comserv/root/todo/priority_display.md` - Now self-contained with internal mapping
- **Template System**: Enhanced reusable component design for better maintainability

### Technical Details
- **Problem**: Priority display template required controllers to pass `build_priority` hash, causing inconsistent behavior
- **Solution**: Internalized priority mapping within the template itself
- **Impact**: All todo-related templates now display consistent priority names across the application

## [2025-01-27] - Backup System Documentation and AI Workflow Improvements

### Documentation Enhancements
- **Backup System Documentation** - Comprehensive documentation for backup system administration
  - **Complete Documentation**: Detailed backup procedures, troubleshooting, and maintenance guides
  - **AI Workflow Optimization**: Enhanced AI development guidelines with realistic resource limits
  - **Resource Management**: Updated operation limits from 25-30 to realistic 15-20 per session
  - **Workflow Completion**: Established comprehensive changelog process for development work

### Process Improvements
- **AI Development Guidelines** - Enhanced guidelines for improved development workflows
  - **Resource Conservation**: More accurate resource limit tracking for extended sessions
  - **Handoff Procedures**: Earlier trigger points (15+ prompts/operations) for session handoffs  
  - **Workflow Tracking**: Improved step-by-step completion documentation
  - **Failure Pattern Documentation**: Enhanced tracking of recurring issues and solutions

### Files Created/Modified
- **Changelog**: `/Comserv/root/Documentation/changelog/2025-01-27-backup-system-documentation.tt`
- **Guidelines**: `/Comserv/root/Documentation/AI_DEVELOPMENT_GUIDELINES.md` - Updated resource conservation section
- **Process Documentation**: Enhanced workflow position tracking and session continuity procedures

### Related Links
- [Backup System Documentation Changelog](2025-01-27-backup-system-documentation.tt) - Detailed development session documentation

## [2025-01-21] - Major System Enhancements and Infrastructure Updates

### Major Enhancements
- **Admin Git Controller Implementation** - Complete separation of Git operations into dedicated controller
  - **New Controller**: Created `Admin::Git` controller with 965+ lines of Git management functionality
  - **Enhanced Security**: Centralized authentication using `AdminAuth` utility
  - **Branch Management**: Advanced branch selection and protection mechanisms
  - **File Operations**: Safe Git operations with proper error handling
  - **Template Integration**: New admin templates for Git operations (git_commit.tt, git_stash.tt, restore_file.tt, safe_git_pull.tt)

- **Documentation System Improvements** - Enhanced documentation management and organization
  - **Template Conversion**: Converted AI guidelines from .tt back to .md format for better AI processing
  - **Enhanced Scanning**: Improved documentation scanning methods with better error handling
  - **Configuration Updates**: Updated documentation config with new categories and file mappings
  - **Logging Integration**: Better integration with centralized logging system

- **Authentication System Enhancements** - Improved admin authentication across all controllers
  - **Centralized Auth**: Enhanced `AdminAuth` utility with better session management
  - **Controller Updates**: Updated Admin, ApiCredentials, IT, NetworkMap, Root, and ThemeAdmin controllers
  - **Consistent Security**: Standardized authentication checks across all admin functions
  - **Session Management**: Improved session handling and user verification

### Infrastructure Improvements
- **Deployment Management** - Enhanced deployment infrastructure
  - **Server Update Procedures**: New comprehensive server update documentation
  - **Deployment Checklist**: Converted to .tt format with enhanced procedures
  - **Admin Templates**: New admin interface templates for enhanced management
  - **Git Ignore Updates**: Enhanced .gitignore with better exclusion patterns

- **Dependency Management** - Improved module management
  - **cpanfile Updates**: Added new required modules for enhanced functionality
  - **Module Integration**: Better integration of Perl modules across controllers
  - **Logging Enhancements**: Improved logging utility with better file handling

### Files Modified
- **Controllers**: Admin.pm, Admin/Git.pm (new), Admin/NetworkMap.pm, ApiCredentials.pm, Documentation.pm, Documentation/ScanMethods.pm, IT.pm, Root.pm, ThemeAdmin.pm
- **Utilities**: AdminAuth.pm, Logging.pm
- **Documentation**: Multiple .tt conversions, new admin documentation, enhanced changelogs
- **Templates**: New admin templates for Git operations and enhanced management
- **Configuration**: Updated .gitignore, cpanfile, documentation_config.json

### Breaking Changes
- **Git Operations**: Git functionality moved from Admin controller to dedicated Admin::Git controller
- **Authentication**: Enhanced authentication requirements for admin functions
- **Template Format**: AI guidelines converted from .tt to .md format (affects documentation system)

## [2025-01-21] - Documentation System Overhaul

### Major Enhancement
- **Documentation System Overhaul** - Complete transformation from config-based to file scanning system
  - **Accessibility Improvement**: Increased accessible documentation from 45 to 270+ files
  - **Dynamic Discovery**: Automatic detection of all documentation files without config updates
  - **Proper Logging Integration**: Fixed logging system to use centralized logging utility
  - **Enhanced Categorization**: Intelligent categorization based on directory structure
  - **Zero Maintenance**: New documentation files automatically discovered and categorized
  - **Error Elimination**: Resolved "Failed to open file" errors from missing config entries

## [2025-01-20] - Admin Authentication System Refactor

### Major Enhancement
- **[Admin Authentication System Refactor](2025-01-20-admin-authentication-refactor.tt)** - Complete overhaul of admin authentication with centralized AdminAuth utility and dedicated Git controller
  - Fixed CSC admin access issues
  - Created centralized authentication utility
  - Separated Git operations into dedicated controller
  - Enhanced branch selection and file protection
  - Improved code maintainability and consistency

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