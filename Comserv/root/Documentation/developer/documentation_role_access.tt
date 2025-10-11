# Documentation System Role-Based Access Control

**Last Updated:** April 10, 2025  
**Author:** Shanta

## Overview

This document explains how role-based access control works in the Documentation system. The Documentation system uses a combination of user roles and session roles to determine which documentation categories and pages a user can access.

## Role Detection

The Documentation controller uses the following process to determine a user's role:

1. First, it checks the session roles array (`$c->session->{roles}`)
2. If the session roles array contains 'admin', the user is given admin access
3. If no admin role is found but other roles exist, the first role is used
4. If no session roles are found but the user is authenticated, it falls back to `$c->user->role`
5. If no role can be determined, the default role 'normal' is used

### Code Example

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
}
# If no role found in session but user exists, try to get role from user object
elsif ($c->user_exists) {
    $user_role = $c->user->role || 'normal';
}
```

## Category Access Control

Each documentation category has a list of roles that are allowed to access it. The system uses the following process to determine if a user can access a category:

1. If the user is an admin (either by `user_role` or session roles), they can access all categories
2. Otherwise, the system checks if any of the user's roles match the roles allowed for the category
3. There's a special case for the 'normal' role, which grants access to any authenticated user

### Code Example

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
```

## Page Access Control

Similar to categories, each documentation page has metadata that includes a list of roles that are allowed to access it. The system uses a similar process to determine if a user can access a page:

1. If the user is an admin, they can access all pages
2. Otherwise, the system checks if any of the user's roles match the roles allowed for the page
3. There's also a site-specific check to ensure users only see pages relevant to their site (unless they're admins)

### Code Example

```perl
# Check if user is admin (either by user_role or session roles)
my $is_admin = ($user_role eq 'admin');

# Also check if admin is in session roles
if (!$is_admin && $c->session->{roles} && ref $c->session->{roles} eq 'ARRAY') {
    $is_admin = grep { $_ eq 'admin' } @{$c->session->{roles}};
}

# Skip if this is site-specific documentation for a different site
# But allow admins to see all site-specific documentation
if ($metadata->{site} ne 'all' && $metadata->{site} ne $site_name) {
    # Only skip for non-admins
    next unless $is_admin;
}

# Skip if the user doesn't have the required role
# But always include for admins
my $has_role = $is_admin; # Admins can see everything

unless ($has_role) {
    foreach my $role (@{$metadata->{roles}}) {
        # Check various role conditions...
    }
}
```

## Template Role Checking

In the template, role-based access control is implemented using Template Toolkit conditionals:

```tt
<!-- Admin Documentation Sections - Only visible to administrators -->
[% IF user_role == 'admin' || c.session.roles.grep('admin').size %]
    <!-- Admin-only content here -->
[% END %]
```

## Debugging Role Issues

If you're experiencing issues with role-based access control, you can enable debug mode in the session:

```perl
$c->session->{debug_mode} = 1;
```

This will display detailed debug information on the documentation index page, including:

- User role from the controller
- Display role from the template
- Session roles
- Available admin categories
- Other role-related information

## Best Practices

1. **Always check both user_role and session roles**: Some parts of the application may set only one of these
2. **Prioritize admin role**: If a user has multiple roles including admin, always use the admin role
3. **Log role decisions**: Add logging statements to help diagnose access control issues
4. **Use consistent role checking**: Use the same approach to role checking across the application
5. **Add debug information**: Include debug information to help diagnose role-related issues

## Common Issues

1. **User has admin in session roles but can't see admin content**: Make sure the template is checking both `user_role` and `c.session.roles`
2. **Admin categories not appearing**: Check if the categories exist and if the filtering logic is correctly identifying admin users
3. **Role detection inconsistency**: Ensure that role detection is consistent across the application

## Future Improvements

1. Create a unified role management system
2. Implement more granular permission controls
3. Add a role management interface for administrators
4. Improve logging and debugging for role-based access control