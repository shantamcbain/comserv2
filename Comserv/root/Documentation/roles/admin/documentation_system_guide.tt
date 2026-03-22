# Documentation System Administrator Guide

**Last Updated:** April 10, 2025  
**Author:** Shanta

## Overview

This guide provides information for administrators about the Documentation system in Comserv. As an administrator, you have access to all documentation categories and pages, including admin-specific documentation.

## Admin Documentation Categories

As an administrator, you have access to the following special documentation categories:

1. **Administrator Guides**: Documentation specifically for system administrators
2. **Proxmox Documentation**: Documentation related to the Proxmox virtualization environment
3. **Controller Documentation**: Technical documentation about system controllers
4. **Changelog**: Documentation about system changes and updates
5. **All Documentation Files**: A complete alphabetical list of all documentation files

## Role-Based Access

The Documentation system uses role-based access control to determine which documentation categories and pages a user can see:

- **Admin users** can see all documentation categories and pages
- **Developer users** can see developer documentation and some admin documentation
- **Editor users** can see editor documentation and user documentation
- **Normal users** can see only user documentation and tutorials

## Troubleshooting Access Issues

If you or your users are experiencing issues with documentation access:

1. **Check user roles**: Make sure the user has the appropriate role assigned
2. **Check session roles**: The system uses session roles to determine access
3. **Enable debug mode**: Set `debug_mode = 1` in the user's session to see detailed role information
4. **Check logs**: Look for role-related messages in the application logs

## Adding New Documentation

To add new documentation:

1. Create a new markdown (.md) or template (.tt) file in the appropriate directory:
   - `/Documentation/roles/admin/` for admin-specific documentation
   - `/Documentation/roles/developer/` for developer documentation
   - `/Documentation/roles/normal/` for user documentation
   - `/Documentation/changelog/` for changelog entries
   - `/Documentation/tutorials/` for tutorials
   - `/Documentation/sites/{site_name}/` for site-specific documentation

2. Use the following format for changelog entries:
   ```
   # Title of Change
   
   **Date:** Month Day, Year  
   **Author:** Your Name  
   **Status:** Completed/In Progress
   
   ## Overview
   
   Brief description of the change
   
   ## Changes Made
   
   ### 1. First Change
   
   Details about the first change
   
   ### 2. Second Change
   
   Details about the second change
   
   ## Technical Details
   
   Code examples and technical information
   
   ## Benefits
   
   List of benefits from this change
   
   ## Future Considerations
   
   Ideas for future improvements
   ```

## Documentation Organization

The Documentation system organizes documentation into the following categories:

1. **User Guides**: Documentation for end users
2. **Administrator Guides**: Documentation for system administrators
3. **Developer Documentation**: Documentation for developers
4. **Tutorials**: Step-by-step guides for common tasks
5. **Site-Specific Documentation**: Documentation specific to a particular site
6. **Module Documentation**: Documentation for specific system modules
7. **Proxmox Documentation**: Documentation for Proxmox virtualization
8. **Controller Documentation**: Documentation for system controllers
9. **Changelog**: System changes and updates
10. **All Documentation**: Complete list of all documentation files

## Best Practices

1. **Keep documentation up-to-date**: Update documentation when making system changes
2. **Use markdown formatting**: Use markdown for better readability
3. **Include code examples**: Provide code examples where appropriate
4. **Add metadata**: Include date, author, and status information
5. **Categorize properly**: Place documentation in the appropriate category
6. **Use clear titles**: Make titles descriptive and clear
7. **Include troubleshooting**: Add troubleshooting sections for common issues

## Getting Help

If you need help with the Documentation system, contact the system administrator or refer to the developer documentation for more technical details.