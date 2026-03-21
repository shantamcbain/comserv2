# Restart Starman Functionality

**Date:** September 10, 2025  
**Author:** Shanta  
**Status:** Implemented

## Overview

Added functionality to the Admin controller to allow administrators to restart the Starman server from the web interface. This feature complements the existing Git Pull functionality, allowing administrators to apply code changes and restart the server in a controlled manner.

## Changes Made

1. Added a new `restart_starman` method to the Admin controller
2. Created a new template file `admin/restart_starman.tt` for the restart confirmation and status display
3. Updated the Admin dashboard to include a link to the new functionality
4. Implemented proper logging and error handling for the restart process

## Technical Details

The implementation uses the system's `systemctl` command to restart the Starman service. The feature:

- Requires admin privileges to access
- Provides a confirmation page before executing the restart
- Shows detailed command output after the restart attempt
- Verifies the service status after restart
- Logs all actions with `log_with_details` for audit purposes

## Security Considerations

- Only users with the 'admin' role can access this functionality
- The system uses sudo to execute the systemctl command, which requires proper sudo configuration
- All restart attempts are logged with user information for accountability

## Usage

1. Navigate to the Admin Dashboard
2. Click on "Restart Starman Server" under System Management
3. Review the warning and confirm the restart
4. After restart, review the command output and service status

## Related Documentation

- [Starman Server Documentation](/Documentation/Starman)
- [Admin Guide](/Documentation/admin_guide)