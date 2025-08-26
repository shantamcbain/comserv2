# HelpDesk Controller

**Last Updated:** April 24, 2024  
**Author:** Shanta  
**Status:** Active

## Overview
The HelpDesk controller manages the support ticketing system and knowledge base for Computer System Consulting. It provides a centralized interface for users to submit support tickets, check ticket status, browse the knowledge base, and contact support directly.

## Key Features
- Support ticket submission and management
- Ticket status tracking
- Knowledge base access with Linux commands reference
- Administrative interface for HelpDesk management
- Direct contact with support team
- Chained dispatch system for consistent URL structure
- Debug message handling for troubleshooting
- Integration with Documentation and FAQ systems

## Methods

### Base Methods
- `auto`: Common setup for all HelpDesk actions, initializes debug messages
- `base`: Base method for chained actions, sets up common stash variables
- `default`: Fallback for HelpDesk URLs that don't match any actions

### Page Methods
- `index`: Main HelpDesk landing page with support options
- `kb`: Knowledge Base page with categorized support articles
- `contact`: Contact Support page with various contact methods
- `admin`: Administrative interface for managing the HelpDesk system (admin-only)
- `linux_commands`: Reference page for common Linux commands (admin-only)

### Ticket Methods
- `ticket_base`: Base method for all ticket-related actions
- `ticket_new`: Form for creating new support tickets
- `ticket_status`: Page for viewing existing ticket status

## URL Structure
- `/HelpDesk` - Main HelpDesk landing page
- `/HelpDesk/admin` - HelpDesk administration (admin-only)
- `/HelpDesk/ticket/new` - Create new support ticket
- `/HelpDesk/ticket/status` - View ticket status
- `/HelpDesk/kb` - Knowledge base
- `/HelpDesk/kb/linux_commands` - Linux commands reference
- `/HelpDesk/contact` - Contact support

## Access Control
This controller implements role-based access control:
- Anonymous users can view the HelpDesk and submit tickets
- Authenticated users see personalized content and their ticket history
- Admin users have additional management capabilities through the admin interface

## Navigation Integration
The HelpDesk system is integrated into the main navigation through the `TopDropListHelpDesk.tt` template, providing easy access to all HelpDesk components:
- HelpDesk Home
- Submit a Ticket
- Check Ticket Status
- Documentation
- Knowledge Base
- Linux Commands (admin-only)
- FAQ
- Contact Support

## Related Files
- Template files:
  - `/root/CSC/HelpDesk.tt` - Main HelpDesk template
  - `/root/CSC/HelpDesk/admin.tt` - HelpDesk administration interface
  - `/root/CSC/HelpDesk/new_ticket.tt` - New ticket form
  - `/root/CSC/HelpDesk/ticket_status.tt` - Ticket status page
  - `/root/CSC/HelpDesk/kb.tt` - Knowledge base
  - `/root/CSC/HelpDesk/linux_commands.tt` - Linux commands reference
  - `/root/CSC/HelpDesk/contact.tt` - Contact page
- Support content:
  - `/root/CSC/HelpdeskContents.tt` - Shared content included in the main template
  - `/root/CSC/HelpDeskHomePagesql.tt` - SQL-based dynamic content
- Navigation:
  - `/root/Navigation/TopDropListHelpDesk.tt` - HelpDesk dropdown menu

## Logging and Debugging
The HelpDesk controller uses comprehensive logging with `log_with_details`:

```perl
$self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'method_name', 
    "Detailed message with relevant information");
```

Debug messages are stored in the stash for display in templates when debug mode is enabled:

```perl
push @{$c->stash->{debug_msg}}, "Debug message";
```

## Implementation Notes
- Uses the chained dispatch system for consistent URL structure
- Explicitly forwards to the TT view to ensure template rendering
- Maintains debug messages in an array for troubleshooting
- Designed to work without explicit loading in Comserv.pm
- Integrates with the Documentation and FAQ systems for comprehensive support

## Related Documentation
- [HelpDesk System Documentation](/Documentation/HelpDeskSystem)
- [FAQ Controller Documentation](/Documentation/controllers/FAQ)
- [Documentation System Guide](/Documentation/documentation_config_guide)