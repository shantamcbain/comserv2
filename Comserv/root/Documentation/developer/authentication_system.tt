# Authentication System Documentation

**Version:** 1.1  
**Last Updated:** June 10, 2024  
**Author:** Development Team

## Overview

The Comserv authentication system manages user login, logout, session management, and user profile functionality. This document provides comprehensive information about the implementation, usage, and customization of the authentication system.

## Key Components

### 1. User Controller (`Comserv/lib/Comserv/Controller/User.pm`)

The User controller handles all authentication-related actions:

- **Login**: Authenticates users and creates sessions
- **Logout**: Terminates user sessions
- **Profile Management**: Displays and updates user information
- **Account Creation**: Registers new users
- **Password Management**: Handles password changes and resets

### 2. Authentication Templates

- **Login Form** (`user/login.tt`): User login interface
- **Profile Page** (`user/profile.tt`): Displays user information
- **Settings Page** (`user/settings.tt`): Allows users to update their information
- **Registration Form** (`user/create_account.tt`): New user registration

### 3. Navigation Components

- **Login Dropdown** (`Navigation/TopDropListLogin.tt`): Context-aware login/logout options

## Authentication Flow

### Login Process

1. User accesses a protected page or clicks the login link
2. The `login` method captures the referring URL in the session
3. User submits credentials via the login form
4. `do_login` method validates credentials against the database
5. On success:
   - Session is created with user information
   - User roles are loaded
   - User is redirected to the original referring page
6. On failure:
   - Error message is stored in flash
   - User is redirected back to the login page

```perl
# Storing the referring page in the login method
sub login :Local {
    my ($self, $c) = @_;
    
    # Store the referer URL if it hasn't been stored already
    my $referer = $c->req->referer || $c->uri_for('/');
    
    # Get the return_to parameter if it exists (for explicit redirects)
    my $return_to = $c->req->param('return_to');
    if ($return_to) {
        $referer = $return_to;
    }

    # Don't store the login page as the referer
    if ($referer !~ m{/user/login} && $referer !~ m{/login} && $referer !~ m{/do_login}) {
        $c->session->{referer} = $referer;
    }
    
    # Store the referer in the stash for the template
    $c->stash->{return_to} = $c->session->{referer};
}

# Login validation code in do_login
my $user = $c->model('DBEncy::User')->find({ username => $username });
unless ($user) {
    # Store error message in flash and redirect back to login page
    $c->flash->{error_msg} = 'Invalid username or password.';
    $c->response->redirect($c->uri_for('/user/login'));
    return;
}

if ($self->hash_password($password) ne $user->password) {
    # Store error message in flash and redirect back to login page
    $c->flash->{error_msg} = 'Invalid username or password.';
    $c->response->redirect($c->uri_for('/user/login'));
    return;
}

# Redirect handling after successful login
my $redirect_path = $c->session->{referer} || '/';
$c->res->redirect($redirect_path);
```

### Logout Process

1. User clicks the logout link
2. `logout` method stores the current URL
3. Important site information is preserved
4. Session is properly deleted
5. Success message is displayed
6. User is redirected to an appropriate page based on context

```perl
sub logout :Local {
    my ($self, $c) = @_;

    # Store the current URL before logout
    my $current_url = $c->req->referer || $c->uri_for('/');

    # Log the logout action with the current URL
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'logout',
        "User '" . ($c->session->{username} || 'unknown') . "' logging out, current URL: $current_url");

    # Get username before clearing session (for the success message)
    my $username = $c->session->{username} || 'Guest';

    # Store important site information before clearing the session
    my $site_name = $c->session->{SiteName} || '';
    my $theme_name = $c->session->{theme_name} || '';
    my $controller_name = $c->session->{ControllerName} || '';

    # Properly delete the session (instead of just emptying it)
    $c->delete_session("User logged out");

    # Create a new session with minimal required data
    $c->session->{SiteName} = $site_name if $site_name;
    $c->session->{theme_name} = $theme_name if $theme_name;
    $c->session->{ControllerName} = $controller_name if $controller_name;

    # Set a success message
    $c->flash->{success_msg} = "You have been successfully logged out.";

    # Determine if the current page is accessible to non-logged-in users
    # and redirect appropriately
    my $redirect_url = $c->uri_for('/');
    if ($current_url =~ m{^/([^/]+)}) {
        # Redirect to site-specific page if appropriate
        $redirect_url = $current_url if $site_name;
    }
    
    $c->response->redirect($redirect_url);
    return;
}
```

### Session Management

Sessions are managed using Catalyst's session plugins:

```perl
use Catalyst qw/
    Session
    Session::Store::File
    Session::State::Cookie
    Authentication
    Authorization::Roles
/;
```

Session configuration in `Comserv.pm`:

```perl
'Plugin::Session' => {
    storage => '/tmp/session_data',
    expires => 3600,
},
```

## User Profile System

### Profile Display

The profile page displays user information retrieved from the database:

```perl
sub profile :Local {
    my ($self, $c) = @_;
    
    # Check if user is logged in
    unless ($c->session->{username}) {
        $c->flash->{error_msg} = "You must be logged in to view your profile.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    # Get user data from database
    my $user = $c->model('DBEncy::User')->find({ username => $c->session->{username} });
    
    # Prepare user data for display
    my $user_data = {
        username => $user->username,
        first_name => $user->first_name,
        last_name => $user->last_name,
        email => $user->email,
        roles => $c->session->{roles} || [],
    };
    
    # Set template and stash data
    $c->stash(
        user => $user_data,
        template => 'user/profile.tt'
    );
}
```

### Settings Management

Users can update their information through the settings page:

1. User accesses the settings page
2. Form is pre-populated with current information
3. User submits changes
4. `update_settings` method validates and saves changes
5. Session is updated to reflect changes
6. User is redirected to the profile page

## Role-Based Access Control

The authentication system integrates with Catalyst's Authorization::Roles plugin to provide role-based access control:

```perl
# Check if user has admin role
[% IF c.session.roles.grep('admin').size %]
    <!-- Admin-specific content -->
[% END %]
```

Roles are loaded during login:

```perl
# Fetch user role(s)
my $roles = $user->roles;

# Check if the roles field contains a single role (string) and wrap it into an array
if (defined $roles && !ref $roles) {
    $roles = [ $roles ];  # Convert single role to array.
}

# Assign roles to session
$c->session->{roles} = $roles;
```

## Debugging and Logging

The authentication system includes comprehensive logging for debugging:

```perl
$self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'login', 
    "User '$username' successfully authenticated.");
```

Debug mode can be enabled in user settings to display additional information:

```perl
[% IF c.session.debug_mode == 1 %]
    <div class="debug">
        [% PageVersion %]
        [% INCLUDE 'debug.tt' %]
    </div>
[% END %]
```

## Customization

### Adding Custom Fields

To add custom fields to the user profile:

1. Add the field to the User database table
2. Update the profile and settings templates to include the new field
3. Modify the `update_settings` method to handle the new field

### Styling

The authentication components use CSS classes that can be customized in your theme:

- `.user-profile-container`: Main container for profile page
- `.settings-container`: Main container for settings page
- `.form-group`: Form field containers
- `.action-button`: Action buttons (Edit, Save, etc.)

## Troubleshooting

### Common Issues

1. **404 on Logout**
   - Ensure the logout method is properly defined in the User controller
   - Check that the logout link uses the correct URI: `[% c.uri_for('/user/logout') %]`

2. **Session Not Persisting**
   - Verify session configuration in Comserv.pm
   - Check permissions on the session storage directory
   - Ensure `delete_session` is used properly instead of just clearing the session hash

3. **Login Redirect Issues**
   - Ensure the referer URL is properly captured and sanitized
   - Check for circular redirects back to the login page
   - Verify that login-related pages are excluded from the referer list
   - Check that the `return_to` parameter is being properly processed

4. **Template Not Found Errors**
   - Ensure error handling uses redirects instead of trying to render templates directly
   - Use flash messages instead of stash for error messages that need to persist across redirects

### Debugging Tips

1. Enable debug mode in your session: `$c->session->{debug_mode} = 1;`
2. Check the application log for detailed error messages
3. Use the browser's developer tools to inspect session cookies

## Security Considerations

1. **Password Storage**
   - Passwords are hashed using SHA-256
   - Consider upgrading to bcrypt or Argon2 for stronger security

2. **Session Security**
   - Sessions expire after 1 hour (configurable)
   - Consider implementing CSRF protection for forms

3. **Input Validation**
   - All user input is validated before processing
   - Email addresses are checked against a regex pattern

## Future Enhancements

Planned improvements to the authentication system:

1. Two-factor authentication support
2. OAuth integration for social login
3. Enhanced password policies
4. Account lockout after failed attempts
5. User activity logging and auditing
6. Improved return-to-origin functionality with better security checks
7. Support for multiple authentication methods in a single deployment
8. Enhanced session security with IP binding and browser fingerprinting

## Recent Changes

### Version 1.1 (June 10, 2024)
1. Improved login redirect functionality to better handle return-to-origin
2. Added support for explicit `return_to` parameter in login URLs
3. Fixed template rendering issues in authentication error handling
4. Enhanced session preservation during logout to maintain site context
5. Improved documentation and added more detailed logging
6. Added debug information to the stash for better troubleshooting