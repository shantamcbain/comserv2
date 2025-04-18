# HelpDesk Controller

## Overview
The HelpDesk controller manages the support ticketing system and knowledge base for Computer System Consulting. It provides a centralized interface for users to submit support tickets, check ticket status, browse the knowledge base, and contact support directly.

## Key Features
- Support ticket submission and management
- Ticket status tracking
- Knowledge base access
- Direct contact with support team
- Chained dispatch system for consistent URL structure
- Debug message handling for troubleshooting

## Methods

### Base Methods
- `auto`: Common setup for all HelpDesk actions, initializes debug messages
- `base`: Base method for chained actions, sets up common stash variables
- `default`: Fallback for HelpDesk URLs that don't match any actions

### Page Methods
- `index`: Main HelpDesk landing page with support options
- `kb`: Knowledge Base page with categorized support articles
- `contact`: Contact Support page with various contact methods

### Ticket Methods
- `ticket_base`: Base method for all ticket-related actions
- `ticket_new`: Form for creating new support tickets
- `ticket_status`: Page for viewing existing ticket status

## URL Structure
- `/HelpDesk` - Main HelpDesk landing page
- `/HelpDesk/ticket/new` - Create new support ticket
- `/HelpDesk/ticket/status` - View ticket status
- `/HelpDesk/kb` - Knowledge base
- `/HelpDesk/contact` - Contact support

## Access Control
This controller is accessible to all users with the following distinctions:
- Anonymous users can view the HelpDesk and submit tickets
- Authenticated users see personalized content and their ticket history
- Admin users have additional management capabilities (to be implemented)

## Related Files
- Template files:
  - `/root/CSC/HelpDesk.tt` - Main HelpDesk template
  - `/root/CSC/HelpDesk/new_ticket.tt` - New ticket form
  - `/root/CSC/HelpDesk/ticket_status.tt` - Ticket status page
  - `/root/CSC/HelpDesk/kb.tt` - Knowledge base
  - `/root/CSC/HelpDesk/contact.tt` - Contact page
- Support content:
  - `/root/CSC/HelpdeskContents.tt` - Shared content included in the main template
  - `/root/CSC/HelpDeskHomePagesql.tt` - SQL-based dynamic content

## Implementation Notes
- Uses the chained dispatch system for consistent URL structure
- Explicitly forwards to the TT view to ensure template rendering
- Maintains debug messages in an array for troubleshooting
- Designed to work without explicit loading in Comserv.pm