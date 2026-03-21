# Pagetop Server Information Display - April 2025

**Date:** April 9, 2025  
**Author:** Shanta  
**Status:** Completed  
**File:** `/Comserv/root/pagetop.tt`

## Overview

Added server information display to the pagetop.tt template to help administrators identify which server they are currently connected to. This is particularly useful for troubleshooting proxy system issues on production servers.

## Changes Made

### 1. Added Server Information Display

- Added a new server information bar at the top of the page that displays:
  - The current server's hostname (from request URI)
  - The client's IP address
- Made the server info display visible only to administrators and users with debug mode enabled
- Used built-in Catalyst request variables to ensure compatibility across all environments

### 2. Improved Role Checking Logic

- Consolidated duplicate role checking code
- Moved the admin role check to the top of the file
- Reused the is_admin variable throughout the template
- Removed redundant role checking code at the bottom of the file

### 3. Updated Template Version

- Updated the PageVersion to 0.023.0
- Added the current date to the version information

## Files Modified

- `/Comserv/root/pagetop.tt`

## Benefits

- Administrators can now easily identify which server they are connected to
- Shows both hostname and IP address to help distinguish between production and proxy servers
- Helps with troubleshooting proxy system issues on production servers
- Improves the efficiency of the template by eliminating duplicate role checks
- Maintains clean separation between admin-only and public content
- Uses only built-in Template Toolkit variables for maximum compatibility

## Technical Details

### Server Information Bar

Added a new div with server information that only appears for administrators:

```html
<div class="server-info" style="background-color: #e9ecef; border-bottom: 1px solid #dee2e6; padding: 5px 10px; font-size: 12px; text-align: right; color: #495057;">
    Server: <strong>[% c.req.uri.host %]</strong> | 
    IP: <strong>[% c.req.address %]</strong>
    [% IF c.session.debug_mode == 1 %] | [% PageVersion %][% END %]
</div>
```

This implementation specifically helps with the proxy configuration where helpdesk.computersystemconsulting.ca is proxied to http://172.30.131.126:3000/. When administrators access the site, they can now see whether they're connecting directly to the internal IP or through the proxy domain, which helps diagnose connection issues.

### Proxy Troubleshooting Example

When accessing through the proxy:
- Server: helpdesk.computersystemconsulting.ca
- IP: [External client IP]

When accessing directly:
- Server: 172.30.131.126:3000
- IP: [Internal network IP]

This difference makes it immediately clear which path the connection is taking.

### Role Checking Optimization

Consolidated role checking to a single location at the top of the file:

```perl
[% SET roles = c.session.roles || [] %]
[% SET is_admin = roles.grep('admin').size > 0 ? 1 : 0 %]
```

## Related Documentation

For more information about the template system and debugging in Comserv, see:
- Template System Documentation
- Debugging Guide
- Administrator Guide