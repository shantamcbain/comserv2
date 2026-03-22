# MCoop Admin Menu Restriction

**Date:** April 1, 2025  
**Author:** Shanta  
**Status:** Completed

## Overview

This document outlines the implementation of a security enhancement to restrict the MCoop admin menu items to only appear when the current site is MCOOP. Previously, these menu items were visible to admin users on all sites, which could lead to confusion and potential security issues.

## Changes Made

### 1. Menu Visibility Restriction

The MCoop admin menu section in the admin top menu was modified to only display when:
- The user has the 'admin' role AND
- The current site is specifically 'MCOOP'

This was implemented by updating the conditional check in the `admintopmenu.tt` template:

```tt
[% IF c.session.roles && c.session.roles.grep('^admin$').size && (c.session.SiteName == 'MCOOP' || c.stash.SiteName == 'MCOOP') %]
```

### 2. Site-Specific Menu Logic

The implementation checks for the MCOOP site name in both the session and stash to ensure all cases are covered:
- `c.session.SiteName == 'MCOOP'` - Checks if the site name is stored in the session
- `c.stash.SiteName == 'MCOOP'` - Checks if the site name is stored in the stash

This dual check ensures that the menu appears correctly regardless of how the site context was set.

## Technical Details

### Template Changes

The change was made in the `admintopmenu.tt` template file located at:
`Comserv/root/Navigation/admintopmenu.tt`

**Before:**
```tt
[% IF c.session.roles && c.session.roles.grep('^admin$').size %]
<div class="submenu-item">
    <span class="submenu-header">MCOOP Admin</span>
    <div class="submenu">
        <!-- MCOOP menu items -->
    </div>
</div>
[% END %]
```

**After:**
```tt
[% IF c.session.roles && c.session.roles.grep('^admin$').size && (c.session.SiteName == 'MCOOP' || c.stash.SiteName == 'MCOOP') %]
<div class="submenu-item">
    <span class="submenu-header">MCOOP Admin</span>
    <div class="submenu">
        <!-- MCOOP menu items -->
    </div>
</div>
[% END %]
```

## Benefits

- **Improved Security**: MCoop administrative features are now properly restricted to the MCOOP site context
- **Reduced Confusion**: Admin users on other sites no longer see irrelevant MCOOP menu items
- **Better Organization**: The admin menu now only shows relevant items based on the current site context
- **Consistent User Experience**: Users only see menu items that are applicable to their current context

## Future Considerations

- Consider implementing similar site-specific restrictions for other site-specific admin features
- Develop a more comprehensive role-based access control system that combines both user roles and site context
- Create a configuration interface that allows administrators to define which menu items should appear for which sites