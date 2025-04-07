# Navigation System Documentation

**Version:** 1.0  
**Last Updated:** April 12, 2025  
**Author:** Development Team

## Overview

The Comserv application uses a modular navigation system with dropdown menus to provide access to different parts of the application. This document provides comprehensive information about the navigation structure, components, and best practices for working with the navigation system.

## Navigation Structure

### Directory Organization

Navigation templates are organized in the following directory structure:

```
Comserv/root/Navigation/
├── TopDropListMain.tt       # Main navigation menu
├── TopDropListLogin.tt      # Login/logout options
├── TopDropListGlobal.tt     # Global site links
├── TopDropListHosted.tt     # Hosted services links
├── TopDropListMember.tt     # Member-specific links
├── TopDropListHelpDesk.tt   # Help and support links
├── admintopmenu.tt          # Admin-specific navigation
└── ... other navigation components
```

### Navigation Hierarchy

The navigation system follows this hierarchy:

1. Main horizontal menu bar (defined in `pagetop.tt`)
2. Dropdown menus for each main section
3. Submenu items within each dropdown
4. Nested submenus for complex sections (like Admin)

## Main Navigation Components

### Main Menu (`TopDropListMain.tt`)

The main menu provides access to the primary sections of the application:

- Home
- About
- Services
- Products
- Contact

### Login Menu (`TopDropListLogin.tt`)

The login menu provides authentication options:

- Login/Logout
- Profile
- Account Settings
- Registration

### HelpDesk Menu (`TopDropListHelpDesk.tt`)

The HelpDesk menu provides access to support resources:

- HelpDesk
- Documentation
- FAQ
- Knowledge Base
- Support Ticket Submission

### Admin Menu (`admintopmenu.tt`)

The Admin menu provides access to administrative functions, organized into logical sections:

#### Admin Dashboard
- View Log
- Open Log

#### Projects
- Project Dashboard
- Add New Project
- Project List (dynamically generated)

#### Documentation
- All Documentation
- User Guides
- Admin Guides
- Tutorials
- Changelog
- Edit Documentation (admin/developer only)

#### ToDo System
- All Todos
- Add New Todo
- Time-based Views (Today, Week, Month)
- Recent Todos

#### File Management
- File Dashboard
- Upload Files
- Files in Database
- File Type Search

#### User Management
- List All Users
- User Administration
- Add New User (admin only)

#### System Setup
- Site Management
- System Configuration

#### Domain Selection
- Production Sites
- Local Development
- Other Options

#### System Links
- Admin Notes
- Dynamic Admin Links
- TTML Links

#### MCOOP Admin (site-specific)
- MCOOP Home
- Server Room Plan
- Network Infrastructure
- COOP Services

#### Debug Options
- Toggle Debug Mode
- Debug Console

## CSS Styling

The navigation system styling is defined in:

```
Comserv/root/static/css/components/navigation.css
```

Key styling components include:

### Horizontal Menu
- Top-level menu bar styling
- Dropdown button appearance
- Hover effects

### Dropdown Content
- Dropdown menu containers
- Link styling within dropdowns
- Hover effects for dropdown items

### Submenu System
- Submenu positioning
- Submenu headers
- Nested submenu display

### Enhanced Components
- Project list styling
- File search form styling
- Recent todos styling
- Domain list styling

## JavaScript Functionality

The navigation system includes JavaScript for:

- Dropdown menu toggling
- Submenu expansion/collapse
- Active state management
- Mobile responsiveness

## Role-Based Navigation

The navigation system adapts based on user roles:

### Guest Users
- Limited access to basic navigation
- Login/registration options
- Public documentation

### Regular Users
- Access to user-specific features
- Profile and account management
- User-level documentation

### Administrators
- Full access to all navigation options
- Admin-specific menus and submenus
- System configuration options

## Best Practices

### 1. Consistent Structure

Maintain consistent structure across navigation components:

```html
<li class="horizontal-dropdown">
    <a href="/section" class="dropbtn"><i class="icon-section"></i>Section Name</a>
    <div class="dropdown-content">
        <!-- Dropdown items -->
    </div>
</li>
```

### 2. Icon Usage

Use consistent icons for navigation items:

```html
<a href="/path"><i class="icon-name"></i>Link Text</a>
```

### 3. Role-Based Visibility

Control visibility based on user roles:

```html
[% IF c.session.roles.grep('admin').size %]
    <!-- Admin-only navigation -->
[% END %]
```

### 4. Section Organization

Organize complex dropdowns into logical sections:

```html
<div class="submenu-section">
    <span class="submenu-section-title">Section Title</span>
    <!-- Section links -->
</div>
```

### 5. Landing Pages

Ensure section headers link to appropriate landing pages:

```html
<span class="submenu-header">
    <a href="/section" class="dropbtn"><i class="icon-section"></i>Section Name</a>
</span>
```

## Extending the Navigation System

### Adding New Navigation Items

To add a new navigation item:

1. Identify the appropriate navigation component
2. Add the new item following the established pattern
3. Include appropriate role-based access control
4. Update CSS if new styling is needed

### Adding New Dropdown Sections

To add a new dropdown section:

1. Create a new dropdown in the appropriate navigation component
2. Follow the established structure for dropdowns
3. Add appropriate submenu items
4. Update CSS for any new styling needs

## Troubleshooting

### Common Navigation Issues

1. **Dropdown Not Appearing**
   - Check CSS class names
   - Verify HTML structure matches established pattern
   - Check for JavaScript errors

2. **Role-Based Access Not Working**
   - Verify role check syntax
   - Check session role values
   - Test with different user accounts

3. **Styling Inconsistencies**
   - Ensure CSS classes are applied correctly
   - Check for CSS conflicts
   - Verify theme compatibility

### Debugging Navigation

1. Enable debug mode to see template versions
2. Check browser developer tools for CSS/JS issues
3. Test navigation with different user roles
4. Review application logs for errors