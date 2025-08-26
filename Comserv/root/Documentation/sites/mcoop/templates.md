# MCOOP Templates Documentation

**Last Updated:** April 1, 2025  
**Author:** Shanta  
**Status:** Active

This document provides detailed information about the Template Toolkit (TT) templates used in the MCOOP site implementation.

## Overview

The MCOOP site uses several specialized templates to render its content. These templates are designed to work with the site's theme and provide a consistent user experience.

## Main Templates

### coop/index.tt

The main landing page template for the MCOOP site.

**Key Features:**
- Displays the Technical Support Center content
- Shows different content for administrators and regular users
- Uses site information from the site table via Root.pm
- Includes debug information when debug mode is enabled

**Template Structure:**
```tt
[% META title = 'Monashee Coop Technical Support' %]
[% PageVersion = 'coop/index.tt,v 0.04 2025/04/01 shanta Exp shanta ' %]

<!-- Debug information section -->
[% IF debug_mode == 1 %]
    [% PageVersion %]
    [% # Use the standard debug message system %]
    [% IF debug_msg.defined && debug_msg.size > 0 %]
        <div class="debug-messages">
            [% FOREACH msg IN debug_msg %]
                <p class="debug">Debug: [% msg %]</p>
            [% END %]
        </div>
    [% END %]
[% END %]

<!-- Main container -->
<div class="container">
    <!-- Header is provided by layout.tt -->
    
    <!-- Info panel with help and account messages -->
    <div class="info-panel">
        <div class="help-message">
            <p>This is the administrative portal for Monashee Coop technical support services.</p>
        </div>
        
        <div class="account-message">
            <p>Please create an account to access member services and support features.</p>
        </div>
    </div>
    
    <!-- Main content area -->
    <main>
        <!-- Content for non-admin users -->
        [% IF !c.session.username || (c.session.roles && !c.session.roles.grep('^admin$').size) %]
            <div class="public-view">
                <h2>Technical Support Center</h2>
                <div class="alert alert-info">
                    <p>Welcome to the Monashee Coop technical support center. Our team is ready to assist you with any technical issues or questions.</p>
                </div>
                
                <!-- Member services card -->
                <div class="card mb-4">
                    <!-- Card content with member services information -->
                </div>
            </div>
        [% END %]
        
        <!-- Admin-only content -->
        [% IF c.session.roles && c.session.roles.grep('^admin$').size %]
            <h2>Administrator Dashboard</h2>
            <!-- Admin dashboard content -->
        [% END %]
    </main>
    
    <!-- Footer -->
    <footer>
        <p>&copy; [% Date.format(Date.now, '%Y') %] Monashee Coop. All rights reserved.</p>
    </footer>
</div>
```

**Controller Integration:**
The template is rendered by the `index` method in the MCoop controller, which sets up the necessary stash variables and theme configuration.

### coop/server_room_plan.tt

Template for the Server Room Plan feature, showing a detailed proposal for server infrastructure.

**Key Features:**
- Displays a comprehensive server room proposal
- Includes equipment requirements with pricing
- Shows options analysis for different configurations
- Provides recommendations for implementation

**Template Structure:**
```tt
[% META title = 'Monashee Coop Server Room Proposal' %]
[% PageVersion = 'coop/server_room_plan.tt,v 0.02 2025/04/01 shanta Exp shanta' %]

<!-- Debug information section -->
[% IF debug_mode == 1 %]
    <!-- Debug content -->
[% END %]

<!-- Main container -->
<div class="container">
    <header>
        <div class="header-banner">
            <h2 class="header-logo">MONASHEE COOP</h2>
        </div>
        <h1>Server Room Plan Proposal</h1>
        <p>Date: [% Date.format(Date.now, '%Y-%m-%d') %]</p>
    </header>
    
    <!-- Info panel -->
    <div class="info-panel">
        <!-- Help and account messages -->
    </div>
    
    <!-- Main content with server room proposal -->
    <main>
        <h2>Transition Team: Server Infrastructure Plan</h2>
        <!-- Detailed server room proposal content -->
    </main>
    
    <!-- Footer -->
    <footer>
        <p>&copy; [% Date.format(Date.now, '%Y') %] Monashee Coop. All rights reserved.</p>
    </footer>
</div>
```

**Controller Integration:**
The template is rendered by the `server_room_plan` method in the MCoop controller, which sets up the necessary stash variables including help and account messages.

## Navigation Templates

### Navigation/admintopmenu.tt

Contains the admin menu structure, including the MCOOP-specific admin menu items.

**Key Features:**
- Includes the MCOOP Admin section that's only visible to admin users on the MCOOP site
- Uses conditional logic to control menu visibility based on user role and site context

**MCOOP-Specific Section:**
```tt
<!-- MCOOP Admin Section -->
[% IF c.session.roles && c.session.roles.grep('^admin$').size && (c.session.SiteName == 'MCOOP' || c.stash.SiteName == 'MCOOP') %]
<div class="submenu-item">
    <span class="submenu-header">MCOOP Admin</span>
    <div class="submenu">
        <a href="/mcoop">MCOOP Home</a>
        <a href="/mcoop/server-room-plan">Server Room Plan</a>
        <a href="/mcoop/network">Network Infrastructure</a>
        <a href="/mcoop/services">COOP Services</a>
        <a href="/mcoop/admin/infrastructure">Infrastructure Management</a>
        <a href="/mcoop/admin/reports">COOP Reports</a>
        <a href="/mcoop/admin/planning">Strategic Planning</a>
    </div>
</div>
[% END %]
```

## Best Practices for MCOOP Templates

1. **Site-Specific Checks**: Always include site-specific checks when adding MCOOP-specific functionality:
   ```tt
   [% IF c.session.SiteName == 'MCOOP' || c.stash.SiteName == 'MCOOP' %]
       <!-- MCOOP-specific content -->
   [% END %]
   ```

2. **Role-Based Access Control**: Combine role checks with site checks for admin features:
   ```tt
   [% IF c.session.roles && c.session.roles.grep('^admin$').size && (c.session.SiteName == 'MCOOP' || c.stash.SiteName == 'MCOOP') %]
       <!-- MCOOP admin-only content -->
   [% END %]
   ```

3. **Debug Information**: Include debug information sections in all templates:
   ```tt
   [% IF debug_mode == 1 %]
       [% PageVersion %]
       <!-- Other debug information -->
   [% END %]
   ```

4. **Consistent Date Format**: Use the Date plugin consistently for date formatting:
   ```tt
   [% USE Date %]
   [% Date.format(Date.now, '%Y-%m-%d') %]
   ```

5. **Version Control**: Maintain version information in all templates:
   ```tt
   [% PageVersion = 'template_name.tt,v X.XX YYYY/MM/DD author Exp author' %]
   ```

## Future Template Enhancements

1. **Responsive Design**: Enhance templates with more responsive design elements for mobile users
2. **Accessibility**: Improve accessibility features in all templates
3. **Localization**: Add support for multiple languages
4. **Theme Customization**: Allow more user-specific theme customization options