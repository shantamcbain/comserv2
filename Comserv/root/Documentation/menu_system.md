# Menu System Documentation

## Overview
The menu system in Comserv provides navigation throughout the application. It uses a combination of CSS and JavaScript to create dropdown menus and submenus.

## Components

### CSS Files
- `menu.css`: Contains all styling for menus, dropdowns, and submenus
- `components/navigation.css`: Contains additional navigation-specific styling

### JavaScript Files
- `menu.js`: Handles all menu functionality including dropdowns and submenus

## Recent Fixes

### Menu Dropdown Issues (October 2025)
The admin top menu dropdown lists were not displaying properly. When hovering over menu items, the dropdown lists would appear as blank boxes with no items visible, and submenus were not functioning.

#### Root Causes
1. Event listeners not being properly reinitialized after page navigation
2. CSS color variables not properly following the site's theme
3. Submenu positioning issues on different screen sizes

#### Solution
1. Restructured the JavaScript to reinitialize menus after page loads and AJAX updates
2. Updated CSS to use theme variables consistently
3. Improved submenu positioning logic
4. Added proper event handling for both mouse and touch interactions

#### Implementation Details
- Consolidated all menu functionality into `menu.js`
- Removed duplicate admin-specific menu files
- Updated CSS to use theme variables for colors
- Added event listeners that properly handle menu state across page navigations

## Usage
To implement a menu in a template:

```html
<link rel="stylesheet" href="/static/css/menu.css">
<link rel="stylesheet" href="/static/css/components/navigation.css">
<script src="/static/js/menu.js"></script>

<ul class="horizontal-menu">
    <li class="horizontal-dropdown">
        <a href="/path" class="dropbtn">Menu Item</a>
        <div class="dropdown-content">
            <a href="/subpath">Dropdown Item</a>
            
            <!-- Submenu Example -->
            <div class="submenu-item">
                <span class="submenu-header">Submenu Title</span>
                <div class="submenu">
                    <a href="/submenu-item">Submenu Item</a>
                </div>
            </div>
        </div>
    </li>
</ul>
```

## Theming
The menu system uses CSS variables for theming:

- `--nav-bg`: Background color for navigation elements
- `--nav-text`: Text color for navigation elements
- `--nav-hover-bg`: Background color for hover states
- `--dropdown-bg`: Background color for dropdown menus
- `--border-color`: Color for borders
- `--text-color`: General text color
- `--text-muted`: Color for less prominent text