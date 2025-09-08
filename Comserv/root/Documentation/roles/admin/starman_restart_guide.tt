# Starman Server Restart Guide

This document provides instructions for administrators on how to safely restart the Starman server through the admin interface.

## Overview

The Starman restart functionality allows administrators to restart the Starman web server when necessary, such as after configuration changes or to resolve performance issues. This feature is accessible only to users with admin privileges.

## Recent Updates (September 2025)

The Starman restart functionality has been enhanced with the following improvements:

1. **Added Username Field**: The restart form now requires both username and password, allowing the feature to work across different servers with various user accounts.

2. **Improved Authentication**: The system now properly verifies admin privileges before allowing server restarts.

3. **Enhanced Debugging**: More detailed logging has been added to help troubleshoot any issues.

4. **Better Error Handling**: Clear error messages are displayed when credentials are missing or incorrect.

5. **Security Enhancements**: Improved input sanitization and credential handling for better security.

## Accessing the Restart Feature

1. Log in to the Comserv platform with an administrator account
2. Navigate to the Admin Dashboard
3. Click on "Restart Starman Server" in the System Maintenance section

## Using the Restart Feature

### Prerequisites

Before restarting the Starman server, ensure:

- You have administrator privileges on the Comserv platform
- You know the system username with sudo privileges
- You know the password for that system user
- No critical operations are in progress

### Restart Procedure

1. On the Restart Starman Server page, review the warning message about service interruption
2. Click the "Yes, Restart Starman Server" button to proceed
3. Enter your system credentials:
   - **Username**: The system username with sudo privileges
   - **Password**: The password for that system user
4. Click "Restart Starman Server" to execute the restart

### Understanding the Results

After the restart command executes:

- A success message will appear if the restart was successful
- The system will automatically check and display the status of the Starman service
- Any errors or warnings will be displayed with relevant details
- Command output will be shown for troubleshooting purposes

## Troubleshooting

### Common Issues

1. **Authentication Failure**: 
   - Ensure you're using the correct system username and password
   - Verify the user has sudo privileges
   - Check that the user is allowed to run systemctl commands

2. **Service Fails to Restart**:
   - Check the command output for specific error messages
   - Verify the Starman service is properly configured
   - Check system logs for additional information

3. **Access Denied**:
   - Confirm you have admin privileges in the Comserv platform
   - Ensure your session hasn't expired
   - Try logging out and back in

### Debug Information

When troubleshooting, enable debug mode to see additional information:

1. Set `debug_mode = 1` in your session
2. The restart page will display detailed information about:
   - User authentication status
   - Role verification
   - Command execution
   - Service status

## Security Considerations

- The Starman restart feature requires both system username and password
- Passwords are never stored and are only used for the current restart operation
- All input is sanitized to prevent command injection
- The feature is restricted to users with admin privileges
- All restart attempts are logged for security auditing

## Related Documentation

- [Administrator Guide](admin_guide.md)
- [System Maintenance Procedures](system_maintenance.md)
- [Troubleshooting Common Issues](troubleshooting.md)