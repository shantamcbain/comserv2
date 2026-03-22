# MCoop URL Case Sensitivity Fix

**Date:** April 13, 2025  
**Author:** Shanta  
**Status:** Implemented  
**Issue:** "The page you requested could not be found: /mcoop/server-room-plan"

## Overview

This update addresses an issue with the MCoop module's server room plan page, where the URL was case-sensitive and causing "page not found" errors when accessed from the admin home page. The link on the admin home page was using lowercase `/mcoop/server-room-plan` while the controller was only handling uppercase `/MCoop/server-room-plan` routes.

## Changes Made

1. **Updated links in admin home page**:
   - Modified links in `coop/index.tt` to use the correct case: `/MCoop/server-room-plan` instead of `/mcoop/server-room-plan`
   - Changed two instances:
     - Line 67: Main quick access link
     - Line 77: Infrastructure section link

2. **Added case-insensitive route handlers**:
   - Added route handlers in `MCoop.pm` to support lowercase URLs:
     ```perl
     # Handle lowercase mcoop URLs with hyphen
     sub server_room_plan_hyphen_lowercase :Path('/mcoop/server-room-plan') :Args(0) {
         my ($self, $c) = @_;
         $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
             'server_room_plan_hyphen_lowercase', 'Lowercase mcoop URL accessed');
         $c->forward('server_room_plan');
     }

     # Handle lowercase mcoop URLs with underscore
     sub server_room_plan_underscore_lowercase :Path('/mcoop/server_room_plan') :Args(0) {
         my ($self, $c) = @_;
         $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 
             'server_room_plan_underscore_lowercase', 'Lowercase mcoop URL with underscore accessed');
         $c->forward('server_room_plan');
     }
     ```
   - These handlers follow the existing naming convention and forward to the main handler

3. **Updated documentation**:
   - Updated `mcoop_module.md` with:
     - Current date (April 13, 2025)
     - Added information about URL case sensitivity
     - Updated code examples to match the current implementation
     - Added reference to this changelog entry
   - Created this changelog entry to document the fix

## Technical Details

The issue was caused by a case mismatch between:
- The controller routes (which use uppercase "MCoop" in the URL path)
- The links in the admin home page (which used lowercase "mcoop")

The solution maintains the existing controller structure while adding compatibility routes that forward to the main handler. This approach:
1. Preserves the existing code structure and naming conventions
2. Maintains logging consistency with the rest of the application
3. Avoids redirects that would cause additional page loads
4. Provides backward compatibility for any bookmarked lowercase URLs

## Testing

The following URLs now all correctly display the server room plan page:
- `/MCoop/server_room_plan` (original uppercase with underscore)
- `/MCoop/server-room-plan` (original uppercase with hyphen)
- `/mcoop/server_room_plan` (lowercase with underscore)
- `/mcoop/server-room-plan` (lowercase with hyphen)

## Related Documentation

- [MCoop Module Documentation](/Documentation/mcoop_module.md)
- [MCoop Server Room Plan Implementation](/Documentation/changelog/2025-04-mcoop-server-room-plan.md)