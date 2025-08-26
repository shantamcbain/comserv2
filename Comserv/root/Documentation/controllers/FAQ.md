# FAQ Controller

**Last Updated:** April 24, 2024  
**Author:** Shanta  
**Status:** Active

## Overview
The FAQ controller manages the Frequently Asked Questions system for Computer System Consulting. It provides a categorized interface for users to find answers to common questions without needing to submit a support ticket.

## Key Features
- Categorized FAQ organization
- Interactive question and answer display
- Integration with the HelpDesk system
- Debug message handling for troubleshooting
- Responsive design for all devices

## Methods

### Base Methods
- `auto`: Common setup for all FAQ actions, initializes debug messages

### Page Methods
- `index`: Main FAQ page with category listings and popular questions
- `category`: Category-specific FAQ pages with relevant questions and answers

## URL Structure
- `/faq` - Main FAQ page with all categories and popular questions
- `/faq/category/{id}` - Category-specific FAQ pages

## Access Control
This controller is accessible to all users:
- Anonymous users can view all FAQ content
- No special permissions are required

## Navigation Integration
The FAQ system is integrated into the HelpDesk dropdown menu in the main navigation through the `TopDropListHelpDesk.tt` template, providing easy access to the FAQ system.

## Related Files
- Template files:
  - `/root/CSC/FAQ/index.tt` - Main FAQ template with categories and popular questions
  - `/root/CSC/FAQ/category.tt` - Category-specific FAQ template
- Navigation:
  - `/root/Navigation/TopDropListHelpDesk.tt` - HelpDesk dropdown menu with FAQ link

## Logging and Debugging
The FAQ controller uses comprehensive logging with `log_with_details`:

```perl
$self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'method_name', 
    "Detailed message with relevant information");
```

Debug messages are stored in the stash for display in templates when debug mode is enabled:

```perl
push @{$c->stash->{debug_msg}}, "Debug message";
```

## Implementation Notes
- Uses JavaScript for interactive question and answer display
- Implements responsive design for all devices
- Maintains debug messages in an array for troubleshooting
- Designed to work without explicit loading in Comserv.pm
- Integrates with the HelpDesk system for comprehensive support

## Future Enhancements
- Search functionality for finding specific questions
- User feedback system for FAQ usefulness
- Admin interface for managing FAQ content
- Integration with the Knowledge Base for more detailed answers

## Related Documentation
- [HelpDesk System Documentation](/Documentation/HelpDeskSystem)
- [HelpDesk Controller Documentation](/Documentation/controllers/HelpDesk)
- [Documentation System Guide](/Documentation/documentation_config_guide)