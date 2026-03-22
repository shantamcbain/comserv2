# Site Domain Resolution Guide

## Overview

This document explains how the Comserv application resolves domains to sites, how it handles domains not found in the database, and common issues that can occur in this process.

## How Domain Resolution Works

1. When a request comes in, the `Root` controller's `auto` method calls `setup_site`.
2. The `setup_site` method extracts the domain from the request.
3. If no site name is set in the session, it looks up the domain in the `sitedomain` table.
4. If a matching domain is found, it retrieves the associated site details.
5. The site's name and home_view are used to determine which controller should handle the request.
6. If no matching domain is found, the system uses default settings (SiteName='default', ControllerName='Root').

## Default Behavior for Unknown Domains

When a domain is not found in the sitedomain table, the system should:

1. Set `SiteName` to 'default'
2. Set `ControllerName` to 'Root'
3. Set `theme_name` to 'default'
4. Set default values for critical variables:
   - `ScriptDisplayName` = 'Site'
   - `css_view_name` = '/static/css/default.css'
   - `mail_to_admin` = 'admin@computersystemconsulting.ca'
   - `mail_replyto` = 'helpdesk.computersystemconsulting.ca'
   - `cmenu_css` = '/static/css/menu.css'
5. Display the Root controller's index.tt template with default styling

This ensures a consistent experience for domains not in the database without leaking site-specific information.

## Common Issues

### 1. Parameter Order Mismatch

One recurring issue is a parameter order mismatch in the `get_site_details` method call. The correct order is:

```perl
$c->model('Site')->get_site_details($c, $site_id);
```

Incorrect order:

```perl
$c->model('Site')->get_site_details($site_id, $c);  # WRONG!
```

This causes the site details to not be retrieved correctly, resulting in all sites showing the default home page.

### 2. Missing Domain in sitedomain Table

If a domain is not found in the `sitedomain` table, the application will use default settings. Previously, the system incorrectly tried to use CSC as a fallback site, which has been fixed to use truly default values.

### 3. Incorrect home_view Setting

If a site's `home_view` field is set to a controller that doesn't exist, the application will fall back to the Root controller.

### 4. Overriding Default Settings

Be careful not to override default settings by calling methods like `fetch_and_set` or `site_setup` after setting default values. This can cause inconsistent behavior.

## How to Fix Domain Resolution Issues

### 1. Check Parameter Order

Ensure all calls to `get_site_details` have the correct parameter order: context first, then site ID.

### 2. Verify Domain in Database

Make sure the domain is properly added to the `sitedomain` table and associated with the correct site ID.

```sql
SELECT * FROM sitedomain WHERE domain = 'example.com';
```

### 3. Check Site Configuration

Verify that the site record has the correct `home_view` value:

```sql
SELECT id, name, home_view FROM sites WHERE id = [site_id];
```

### 4. Enable Debug Mode

Enable debug mode to see detailed logging about the domain resolution process:

```
http://yourdomain.com/?debug=1
```

### 5. Check Controller Existence

Make sure the controller specified in `home_view` actually exists and is properly configured.

## Recent Fixes (2025-03-29)

### Domain Resolution Fallback Fix

We fixed an issue where domains not found in the sitedomain table were incorrectly using CSC-specific settings instead of default settings. The changes included:

1. Modified the `auto` method in Root.pm to use 'default' as SiteName and 'Root' as ControllerName when a domain is not found
2. Set default values for critical variables like ScriptDisplayName and css_view_name
3. Removed code that was trying to use CSC as a fallback site
4. Commented out calls to `site_setup` and `fetch_and_set` that were overriding default settings

These changes ensure that unknown domains show a generic site with default styling rather than leaking site-specific information.

## Preventing Future Issues

1. **Use Consistent Parameter Order**: Always follow the convention of passing the context (`$c`) as the first parameter.

2. **Add Validation**: Consider adding parameter validation to critical methods to catch incorrect parameter order.

3. **Use Named Parameters**: For complex methods, consider using named parameters:

```perl
$c->model('Site')->get_site_details(
    context => $c,
    site_id => $site_id
);
```

4. **Early Returns**: Use early returns in methods to avoid executing code that might change important settings.

5. **Avoid Overriding Settings**: Be careful not to override carefully set default values by calling methods that might change them.

6. **Regular Testing**: Periodically test all domains to ensure they resolve to the correct sites.

7. **Documentation First**: Always check existing documentation before making changes to understand how the system is supposed to work.

## Troubleshooting Steps

If a site is showing the default home page instead of the expected content:

1. Reset your session: `/reset_session`
2. Enable debug mode: `?debug=1`
3. Check the logs for domain resolution errors
4. Verify the domain exists in the `sitedomain` table
5. Check that the site's `home_view` points to a valid controller
6. Ensure the controller's namespace is correctly set
7. Verify the controller's index method is properly defined

## Testing Domain Resolution

To verify domain resolution is working correctly:

1. Test with a domain that is in the sitedomain table:
   - Should show the correct site-specific theme and content
   - Debug information should show the correct SiteName and ControllerName

2. Test with a domain that is not in the sitedomain table (e.g., 127.0.0.1):
   - Should show the default theme with "This site is currently under construction"
   - Debug information should show SiteName as 'default' and ControllerName as 'Root'
   - No site-specific content or styling should be visible