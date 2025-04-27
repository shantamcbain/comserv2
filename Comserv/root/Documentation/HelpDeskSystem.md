# Comserv HelpDesk System Documentation

**Last Updated:** April 24, 2024  
**Author:** Shanta  
**Status:** Active

## Overview

The Comserv HelpDesk system provides a comprehensive support infrastructure for users, combining ticketing, knowledge base, documentation, and direct contact options. The system is designed to be user-friendly while providing powerful tools for support staff to manage and resolve user issues efficiently.

## System Components

### 1. HelpDesk Controller

The HelpDesk controller (`Comserv::Controller::HelpDesk`) manages the core functionality of the HelpDesk system using Catalyst's chained dispatch system for consistent URL structure.

#### Key Methods:

- **Base Methods**:
  - `auto`: Common setup for all HelpDesk actions, initializes debug messages
  - `base`: Base method for chained actions, sets up common stash variables
  - `default`: Fallback for HelpDesk URLs that don't match any actions

- **Page Methods**:
  - `index`: Main HelpDesk landing page with support options
  - `kb`: Knowledge Base page with categorized support articles
  - `contact`: Contact Support page with various contact methods
  - `admin`: Administrative interface for managing the HelpDesk system (admin-only)
  - `linux_commands`: Reference page for common Linux commands (admin-only)

- **Ticket Methods**:
  - `ticket_base`: Base method for all ticket-related actions
  - `ticket_new`: Form for creating new support tickets
  - `ticket_status`: Page for viewing existing ticket status

#### URL Structure:

- `/HelpDesk` - Main HelpDesk landing page
- `/HelpDesk/admin` - HelpDesk administration (admin-only)
- `/HelpDesk/ticket/new` - Create new support ticket
- `/HelpDesk/ticket/status` - View ticket status
- `/HelpDesk/kb` - Knowledge base
- `/HelpDesk/kb/linux_commands` - Linux commands reference
- `/HelpDesk/contact` - Contact support

### 2. FAQ Controller

The FAQ controller (`Comserv::Controller::FAQ`) provides a dedicated system for frequently asked questions, organized by categories.

#### Key Methods:

- `index`: Main FAQ page with category listings and popular questions
- `category`: Category-specific FAQ pages

#### URL Structure:

- `/faq` - Main FAQ page
- `/faq/category/{id}` - Category-specific FAQ pages

### 3. Documentation System

The Documentation system (`Comserv::Controller::Documentation`) provides comprehensive documentation for all aspects of the Comserv system, including user guides, admin guides, and technical documentation.

#### URL Structure:

- `/Documentation` - Main documentation page
- `/Documentation/{page}` - Specific documentation pages

### 4. Navigation Integration

The HelpDesk system is integrated into the main navigation through the `TopDropListHelpDesk.tt` template, providing easy access to all HelpDesk components:

- HelpDesk Home
- Submit a Ticket
- Check Ticket Status
- Documentation
- Knowledge Base
- Linux Commands (admin-only)
- FAQ
- Contact Support

## Template Structure

### HelpDesk Templates:

- `CSC/HelpDesk.tt` - Main HelpDesk template
- `CSC/HelpDesk/admin.tt` - HelpDesk administration interface
- `CSC/HelpDesk/new_ticket.tt` - New ticket form
- `CSC/HelpDesk/ticket_status.tt` - Ticket status page
- `CSC/HelpDesk/kb.tt` - Knowledge base
- `CSC/HelpDesk/linux_commands.tt` - Linux commands reference
- `CSC/HelpDesk/contact.tt` - Contact page

### FAQ Templates:

- `CSC/FAQ/index.tt` - Main FAQ template
- `CSC/FAQ/category.tt` - Category-specific FAQ template

### Support Content:

- `CSC/HelpdeskContents.tt` - Shared content included in the main template
- `CSC/HelpDeskHomePagesql.tt` - SQL-based dynamic content

## Access Control

The HelpDesk system implements role-based access control:

- **Anonymous Users**: Can view the HelpDesk, FAQ, and submit tickets
- **Authenticated Users**: See personalized content and their ticket history
- **Admin Users**: Have additional management capabilities through the admin interface

## Logging and Debugging

The HelpDesk system uses comprehensive logging with `log_with_details`:

```perl
$self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'method_name', 
    "Detailed message with relevant information");
```

Debug messages are stored in the stash for display in templates when debug mode is enabled:

```perl
push @{$c->stash->{debug_msg}}, "Debug message";
```

## Recent Enhancements

### April 24, 2024 Update:

1. **Menu Integration**:
   - Fixed all links in the HelpDesk dropdown menu
   - Ensured all links point to valid internal routes
   - Added proper icons for better visual identification
   - Improved role-based access control for admin features

2. **New Features**:
   - Added HelpDesk Admin interface for managing the HelpDesk system
   - Implemented a dedicated FAQ system with category support
   - Enhanced Linux Commands reference with copy-to-clipboard functionality

3. **Bug Fixes**:
   - Fixed external links that pointed to non-existent resources
   - Corrected the Knowledge Base link to use the proper internal route
   - Improved error handling and logging throughout the system

## Future Plans

1. **Ticket System Enhancement**:
   - Implement ticket categories and priorities
   - Add email notifications for ticket updates
   - Create a ticket assignment system for support staff

2. **Knowledge Base Expansion**:
   - Implement a search function for the knowledge base
   - Add category filtering and tagging
   - Create a rating system for articles

3. **Admin Tools**:
   - Develop reporting and analytics for support tickets
   - Create user management tools for support staff
   - Implement customizable email templates for notifications

## Related Documentation

- [HelpDesk Controller Documentation](controllers/HelpDesk.md)
- [FAQ Controller Documentation](controllers/FAQ.md)
- [Documentation System Guide](documentation_config_guide.md)
- [Mail System Documentation](MailSystem.md)