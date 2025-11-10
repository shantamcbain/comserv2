# Documentation Admin Visibility Fix

**Date:** April 10, 2025  
**Author:** Shanta  
**Status:** Completed

## Overview

This document outlines the fix for an issue where admin users were not seeing admin-specific documentation categories in the Documentation system. The problem was that the system was not properly recognizing users with the 'admin' role in their session roles array.

## Changes Made

### 1. Improved Role Detection

The Documentation controller was updated to properly detect admin users by checking both the `user_role` value and the session roles array:

- Modified the controller to check for admin role in both `user_role` and session roles
- Prioritized session roles over user object roles
- Added more detailed logging of role detection

### 2. Enhanced Page and Category Filtering

The page and category filtering logic was updated to ensure admin users can see all documentation:

- Updated the page filtering logic to consider both `user_role` and session roles
- Updated the category filtering logic to properly recognize admin users
- Added additional logging for category access decisions

### 3. Simplified Template Conditions

The template conditions for displaying admin sections were simplified and made more consistent:

- Simplified the admin section visibility conditions in the template
- Made the conditions more consistent across different sections
- Added comprehensive debug information to help diagnose role issues

## Technical Details

### Controller Changes

The changes were made in the `Documentation.pm` controller file located at:
`Comserv/lib/Comserv/Controller/Documentation.pm`

**Before (Role Detection):**
```perl
# Get the current user's role
my $user_role = 'normal';  # Default to normal user
if ($c->user_exists) {
    # Check if roles are stored in session
    if ($c->session->{roles} && ref $c->session->{roles} eq 'ARRAY' && @{$c->session->{roles}}) {
        # If user has multiple roles, prioritize admin role
        if (grep { $_ eq 'admin' } @{$c->session->{roles}}) {
            $user_role = 'admin';
        } else {
            # Otherwise use the first role
            $user_role = $c->session->{roles}->[0];
        }
    } else {
        # Fallback to user->role if available
        $user_role = $c->user->role || 'normal';
    }
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index', "User role determined: $user_role");
}
```

**After (Role Detection):**
```perl
# Get the current user's role
my $user_role = 'normal';  # Default to normal user

# First check session roles (this works even if user is not fully authenticated)
if ($c->session->{roles} && ref $c->session->{roles} eq 'ARRAY' && @{$c->session->{roles}}) {
    # If user has multiple roles, prioritize admin role
    if (grep { $_ eq 'admin' } @{$c->session->{roles}}) {
        $user_role = 'admin';
    } else {
        # Otherwise use the first role
        $user_role = $c->session->{roles}->[0];
    }
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
        "User role determined from session: $user_role");
}
# If no role found in session but user exists, try to get role from user object
elsif ($c->user_exists) {
    $user_role = $c->user->role || 'normal';
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
        "User role determined from user object: $user_role");
}

# Log the final role determination
$self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
    "Final user role determined: $user_role");
```

**Before (Category Filtering):**
```perl
# Skip if the user doesn't have the required role
# But always include for admins
my $has_role = ($user_role eq 'admin'); # Admins can see everything

unless ($has_role) {
    foreach my $role (@{$category->{roles}}) {
        if ($role eq $user_role || ($role eq 'normal' && $user_role)) {
            $has_role = 1;
            last;
        }
    }
}
```

**After (Category Filtering):**
```perl
# Skip if the user doesn't have the required role
# But always include for admins (check both user_role and session roles)
my $has_role = ($user_role eq 'admin'); # Check if user_role is admin

# Also check if admin is in session roles
if (!$has_role && $c->session->{roles} && ref $c->session->{roles} eq 'ARRAY') {
    $has_role = grep { $_ eq 'admin' } @{$c->session->{roles}};
}

# If still not admin, check for other matching roles
unless ($has_role) {
    foreach my $role (@{$category->{roles}}) {
        # Check if role matches user_role or is in session roles
        if ($role eq $user_role) {
            $has_role = 1;
            last;
        }
        # Check session roles
        elsif ($c->session->{roles} && ref $c->session->{roles} eq 'ARRAY') {
            if (grep { $_ eq $role } @{$c->session->{roles}}) {
                $has_role = 1;
                last;
            }
        }
        # Special case for normal role
        elsif ($role eq 'normal' && $user_role) {
            $has_role = 1;
            last;
        }
    }
}

# Log role access decision
$self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
    "Category $category_key access: " . ($has_role ? "granted" : "denied"));
```

### Template Changes

The changes were made in the `index.tt` template file located at:
`Comserv/root/Documentation/index.tt`

**Before:**
```tt
<!-- Admin Documentation Sections - Only visible to administrators -->
[% IF display_role == 'Administrator' || user_role == 'admin' %]
```

**After:**
```tt
<!-- Admin Documentation Sections - Only visible to administrators -->
[% IF user_role == 'admin' || c.session.roles.grep('admin').size %]
```

## Benefits

- **Improved Access Control**: Admin users now correctly see all admin documentation categories
- **Better Role Detection**: The system now properly recognizes admin users from session roles
- **Enhanced Debugging**: Added comprehensive debug information to help diagnose role issues
- **Consistent User Experience**: Admin users now have access to all documentation they should see

## Future Considerations

- Consider implementing a more comprehensive role-based access control system
- Add more detailed logging for role-based access decisions
- Create a unified approach to role checking across the application
- Consider adding a role management interface for administrators