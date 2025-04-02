# Template System Documentation

**Version:** 1.0  
**Last Updated:** May 31, 2024  
**Author:** Development Team

## Overview

The Comserv application uses the Template Toolkit (TT) system for rendering views. This document provides comprehensive information about the template structure, includes, variables, and best practices for working with templates in the application.

## Template Structure

### Directory Organization

Templates are organized in the following directory structure:

```
Comserv/root/
├── layout.tt           # Main layout template
├── pagetop.tt          # Top navigation and header
├── footer.tt           # Footer content
├── AdminNotes.tt       # Admin-specific notes
├── debug.tt            # Debug information
├── Navigation/         # Navigation components
│   ├── TopDropListMain.tt
│   ├── TopDropListLogin.tt
│   ├── TopDropListGlobal.tt
│   ├── TopDropListHosted.tt
│   ├── TopDropListMember.tt
│   ├── admintopmenu.tt
│   └── TopDropListHelpDesk.tt
├── user/               # User-related templates
│   ├── login.tt
│   ├── profile.tt
│   ├── settings.tt
│   └── create_account.tt
└── Documentation/      # Documentation templates
    ├── index.tt
    ├── roles/
    ├── sites/
    └── ...
```

### Template Hierarchy

The template rendering follows this hierarchy:

1. `layout.tt` - Main container template
2. `pagetop.tt` - Header and navigation
3. Content-specific template (e.g., `user/profile.tt`)
4. `AdminNotes.tt` - Administrative notes
5. `footer.tt` - Footer content

## Main Layout Template

The `layout.tt` file serves as the main container for all pages:

```html
<!DOCTYPE html>
<html>
    [% INCLUDE 'Header.tt' %]
<body class="theme-[% theme_name || c.stash.theme_name || c.session.theme_name || 'default' %]">
    [% INCLUDE 'pagetop.tt' %]
    [% content %]
    [% INCLUDE 'AdminNotes.tt' %]
    [% TRY %]
        [% INCLUDE 'footer.tt' %]
    [% CATCH %]
        <!-- Fallback footer -->
        <footer>
            <div class="footer-content">
                <p>&copy; [% USE date; date.format(date.now, '%Y') %] Comserv. All rights reserved.</p>
                [% IF c.session.debug_mode == 1 %]
                    <p>[% PageVersion %]</p>
                    <p><a href="[% c.uri_for('/reset_session') %]">Reset Session</a></p>
                [% END %]
            </div>
        </footer>
    [% END %]
</body>
</html>
```

Key features:
- Dynamic theme selection based on user preferences
- Content placeholder for page-specific content
- Error handling for footer inclusion
- Debug information display when in debug mode

## Common Template Components

### Page Header (`pagetop.tt`)

The `pagetop.tt` file contains:
- Debug information (when debug mode is enabled)
- Welcome message with user information
- Main navigation menu
- Error and success message display

```html
[% IF c.session.debug_mode == 1 %]
<div class="debug">
    [% PageVersion %]
    [% INCLUDE 'debug.tt' %]
</div>
[% END %]

<header>
    <h1>
        Welcome [% IF roles.grep('admin').size %]
            [% c.session.first_name %] [% c.session.last_name %] Administrator
        [% ELSIF roles.grep('user').size %]
            <p> [% c.session.first_name %] [% c.session.last_name %] User
        [% ELSE %]
            <p> Guest
        [% END %] to [% c.stash.ScriptDisplayName %]!
    </h1>

    <!-- Main Menu -->
    <nav>
        <ul class="horizontal-menu">
            <!-- Navigation items -->
        </ul>
    </nav>
</header>

[% IF error_msg %]<div class="alert error">[% error_msg %]</div>[% END %]
[% IF success_msg %]<div class="alert success">[% success_msg %]</div>[% END %]
```

### Navigation Components

Navigation is modularized into separate components:

- `TopDropListMain.tt` - Main site navigation
- `TopDropListLogin.tt` - Login/logout and user account options
- `TopDropListGlobal.tt` - Global site links
- `admintopmenu.tt` - Admin-specific navigation

Example of the login dropdown (`TopDropListLogin.tt`):

```html
<li class="horizontal-dropdown">
    [% IF c.session.username %]
        <!-- User is logged in -->
        <a href="#" class="dropbtn">[% c.session.username %]</a>
        <div class="dropdown-content">
            <a href="[% c.uri_for('/user/profile') %]">My Profile</a>
            <a href="[% c.uri_for('/user/settings') %]">Account Settings</a>
            <div class="dropdown-divider"></div>
            <a href="[% c.uri_for('/user/logout') %]">Logout</a>
        </div>
    [% ELSE %]
        <!-- User is not logged in -->
        <a href="[% c.uri_for('/user/login') %]" class="dropbtn">Login</a>
        <div class="dropdown-content">
            <a href="[% c.uri_for('/user/login') %]">Login</a>
            <a href="[% c.uri_for('/user/create_account') %]">Register</a>
            <a href="[% c.uri_for('/user/forgot_password') %]">Forgot Password</a>
        </div>
    [% END %]
</li>
```

### Footer (`footer.tt`)

The footer contains:
- Copyright information
- Debug information (when in debug mode)
- Session reset link (when in debug mode)
- Live chat integration

## Template Variables

### Common Variables

| Variable | Description | Source |
|----------|-------------|--------|
| `c.session.username` | Current user's username | Session |
| `c.session.first_name` | User's first name | Session |
| `c.session.last_name` | User's last name | Session |
| `c.session.roles` | Array of user roles | Session |
| `c.session.debug_mode` | Debug mode flag (0 or 1) | Session |
| `c.session.theme_name` | User's theme preference | Session |
| `c.stash.ScriptDisplayName` | Current site display name | Stash |
| `error_msg` | Error message to display | Stash/Flash |
| `success_msg` | Success message to display | Stash/Flash |
| `PageVersion` | Template version information | Template |

### Accessing Session Data

Session data can be accessed using the `c.session` object:

```html
[% IF c.session.username %]
    Welcome back, [% c.session.first_name %]!
[% END %]
```

### Stash Variables

The stash contains variables set by the controller:

```html
[% IF c.stash.debug_msg.defined && c.stash.debug_msg.size > 0 %]
    <div class="debug-messages">
        <h4>Debug Messages</h4>
        [% FOREACH msg IN c.stash.debug_msg %]
            <p class="debug">Debug [% loop.index %]: [% msg %]</p>
        [% END %]
    </div>
[% END %]
```

## Template Directives

### Includes

Include other templates:

```html
[% INCLUDE 'Navigation/TopDropListMain.tt' %]
```

### Conditionals

Check conditions:

```html
[% IF c.session.roles.grep('admin').size %]
    <!-- Admin content -->
[% ELSIF c.session.username %]
    <!-- Logged-in user content -->
[% ELSE %]
    <!-- Guest content -->
[% END %]
```

### Loops

Iterate through collections:

```html
[% FOREACH role IN c.session.roles %]
    <span class="role-badge">[% role %]</span>
[% END %]
```

### Error Handling

Handle template errors:

```html
[% TRY %]
    [% INCLUDE 'some_template.tt' %]
[% CATCH %]
    <!-- Error fallback -->
    <p>Error: [% error.info %]</p>
[% END %]
```

## Debug Mode

Debug mode provides additional information for developers:

1. Enable debug mode in user settings or set `$c->session->{debug_mode} = 1;` in code
2. Debug information is displayed at the top of the page
3. Template versions are shown
4. Session reset link is available

Debug output example:

```html
<div class="debug">
    pagetop.tt,v 0.022 2025/02/27 shanta Exp shanta
    <!-- Additional debug information -->
</div>
```

## Best Practices

### 1. Template Versioning

Include version information at the top of each template:

```html
[% PageVersion = 'template_name.tt,v 0.01 2024/05/31 shanta Exp shanta ' %]
[% IF c.session.debug_mode == 1 %]
    [% PageVersion %]
[% END %]
```

### 2. URI Generation

Always use `c.uri_for()` to generate URLs:

```html
<a href="[% c.uri_for('/user/profile') %]">My Profile</a>
```

### 3. Error Handling

Use TRY/CATCH blocks for potentially problematic includes:

```html
[% TRY %]
    [% INCLUDE 'template.tt' %]
[% CATCH %]
    <!-- Fallback content -->
[% END %]
```

### 4. Conditional Display

Check for variable existence before using:

```html
[% IF variable.defined %]
    [% variable %]
[% ELSE %]
    Default value
[% END %]
```

### 5. Modularization

Break complex templates into smaller, reusable components:

```html
[% INCLUDE 'components/user_card.tt' user=current_user %]
```

## Troubleshooting

### Common Template Issues

1. **Missing Variables**
   - Symptom: Empty content or "[% variable %]" displayed
   - Solution: Ensure the variable is set in the controller

2. **Template Not Found**
   - Symptom: "file error - template.tt: not found" error
   - Solution: Check the path and ensure the file exists

3. **Syntax Errors**
   - Symptom: "parse error - template.tt line X: unexpected token" error
   - Solution: Check TT syntax, especially unclosed tags or quotes

### Debugging Templates

1. Enable debug mode to see template versions and paths
2. Use `[% DUMP variable %]` to inspect variable contents
3. Check the Catalyst debug output for template processing information
4. Review the application log for template-related errors

## Extending the Template System

### Adding New Templates

1. Create the template file in the appropriate directory
2. Use the standard header with version information
3. Include necessary components and styling
4. Reference the template in your controller:

```perl
$c->stash(template => 'path/to/template.tt');
$c->forward($c->view('TT'));
```

### Custom Template Plugins

To add custom TT plugins:

1. Create a plugin in `lib/Template/Plugin/YourPlugin.pm`
2. Configure the plugin in your TT view configuration
3. Use the plugin in templates: `[% USE YourPlugin %]`

## Template Performance Considerations

1. **Caching**: Templates are cached by default for performance
2. **Complexity**: Avoid deeply nested includes and complex logic
3. **Inline CSS/JS**: Consider moving inline styles to external files
4. **Large Templates**: Break large templates into smaller components