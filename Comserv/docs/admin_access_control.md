# Admin Access Control Documentation

## Overview

This document explains how admin access control works in the Comserv application, with a focus on the Template Toolkit (.tt) files and their interaction with the controller logic.

## Role-Based Access Control

The application uses a role-based access control system where users are assigned roles (such as 'admin', 'user', etc.) that determine their access to different parts of the application.

### Key Components

1. **User Model (`Comserv/lib/Comserv/Model/User.pm`)**
   - Handles user authentication and role retrieval
   - The `roles` method returns the user's roles as an array reference
   - Special handling for the 'Shanta' user to ensure admin access

2. **Admin Controller (`Comserv/lib/Comserv/Controller/Admin.pm`)**
   - Checks if the user has the 'admin' role before allowing access to admin pages
   - Implements a bypass for the 'Shanta' user to ensure admin access
   - Redirects non-admin users to the login page

3. **Root Controller (`Comserv/lib/Comserv/Controller/Root.pm`)**
   - Provides the `check_user_roles` method used throughout the application
   - Logs detailed information about role checks for debugging

## Template Toolkit (.tt) Files

The .tt files are crucial for implementing the UI aspects of access control:

### 1. `pagetop.tt`

This file controls the display of the top navigation menu based on user roles:

```tt
[% SET roles = c.session.roles || [] %]
[% SET is_admin = roles.grep('admin').size > 0 ? 1 : 0 %]

[% IF is_admin || c.session.debug_mode == 1 %]
<div class="server-info">
    <!-- Server information displayed only to admins -->
</div>
[% END %]

<!-- Main Menu -->
<nav>
    <ul class="horizontal-menu">
        <!-- Common navigation items -->
        
        [% IF is_admin %]
            [% INCLUDE 'Navigation/admintopmenu.tt' %]
        [% END %]
        
        <!-- Other navigation items -->
    </ul>
</nav>
```

The key points:
- `roles.grep('admin').size > 0` checks if the user has the 'admin' role
- The admin menu is only included if the user is an admin
- Server information is shown only to admins or in debug mode

### 2. `admintopmenu.tt`

This file defines the admin menu structure that's included for admin users:

```tt
<li class="horizontal-dropdown">
    <a href="/admin" class="dropbtn"><i class="icon-admin"></i>Admin</a>
    <div class="dropdown-content">
        <!-- Admin menu items -->
        
        <!-- Sections that require specific role checks -->
        [% IF c.session.roles.grep('admin').size || c.session.roles.grep('developer').size %]
            <div class="submenu-section">
                <span class="submenu-section-title">Admin Resources</span>
                <!-- Admin-specific resources -->
            </div>
        [% END %]
        
        <!-- More admin menu items -->
    </div>
</li>
```

The key points:
- The entire menu is only included if the user is an admin (controlled by `pagetop.tt`)
- Some sections within the admin menu have additional role checks
- Role checks use the `grep` function to search the roles array

### 3. Other Template Files

Many other template files use similar role-checking patterns:

```tt
[% IF c.session.roles.grep('admin').size %]
    <!-- Admin-only content -->
[% ELSIF c.session.roles.grep('user').size %]
    <!-- Regular user content -->
[% ELSE %]
    <!-- Guest content -->
[% END %]
```

## Recent Fixes

Recent changes to fix admin access issues:

1. Added a bypass in the Admin controller for the 'Shanta' user
2. Ensured the User model always returns the 'admin' role for the 'Shanta' user
3. Added detailed logging to help diagnose role-related issues

## Best Practices for Template Role Checks

When implementing role checks in .tt files:

1. Use consistent patterns for role checking:
   ```tt
   [% IF c.session.roles.grep('admin').size > 0 %]
   ```

2. Store the result in a variable for multiple checks:
   ```tt
   [% SET is_admin = c.session.roles.grep('admin').size > 0 ? 1 : 0 %]
   [% IF is_admin %]
   ```

3. Handle undefined roles gracefully:
   ```tt
   [% SET roles = c.session.roles || [] %]
   ```

4. Use role-based includes for modular templates:
   ```tt
   [% IF is_admin %]
       [% INCLUDE 'admin_section.tt' %]
   [% END %]
   ```

## Troubleshooting

If users are experiencing issues with admin access:

1. Check the application logs for role-related messages
2. Verify the user's roles in the database
3. Ensure the `roles` method in the User model is correctly processing the roles
4. Check for any session-related issues that might be clearing the roles