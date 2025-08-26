# Ve7tit Controller Documentation

## Overview
The Ve7tit controller manages the VE7TIT amateur radio station section of the application. It provides information about radio equipment, operating modes, and amateur radio activities.

## URL Structure
- `/ve7tit` - Main landing page (lowercase URL)
- `/Ve7tit` - Alternative access with mixed case (redirects to main page)
- `/ve7tit/equipment/{equipment-id}` - Individual equipment pages
- `/Ve7tit/{equipment-id}` - Alternative access to equipment with mixed case

## Controller Methods

### Base Method
```perl
sub base :Chained('/') :PathPart('ve7tit') :CaptureArgs(0)
```
- Sets up the base chain for all Ve7tit actions
- Sets the mail server to "http://webmail.ve7tit.com"

### Index Method
```perl
sub index :Chained('base') :PathPart('') :Args(0)
```
- Renders the main landing page
- Uses template: `ve7tit/index.tt`

### Direct Index Method
```perl
sub direct_index :Path('/Ve7tit') :Args(0)
```
- Handles mixed case URL access to the landing page
- Forwards to the index method

### Equipment Method
```perl
sub equipment :Chained('base') :PathPart('equipment') :Args(1)
```
- Handles equipment pages with the URL pattern `/ve7tit/equipment/{equipment-id}`
- Checks if the requested equipment template exists
- If found, renders the template
- If not found, shows a helpful error page with available equipment

### Direct Equipment Method
```perl
sub direct_equipment :Chained('base') :PathPart('') :Args(1)
```
- Handles direct access to equipment pages without the `/equipment/` path
- Checks if the template exists or if it looks like equipment
- Forwards to the equipment action if appropriate

### Mixed Case Direct Equipment Method
```perl
sub mixed_case_direct_equipment :Path('/Ve7tit') :Args(1)
```
- Handles mixed case URLs for equipment pages
- Forwards to the direct_equipment method

### Default Method
```perl
sub default :Private
```
- Catch-all for any other paths
- Forwards to the index method

### Helper Method: _get_available_equipment
```perl
sub _get_available_equipment
```
- Internal helper method to list all available equipment templates
- Used for error handling to show available options

## Templates

### Main Template
- `ve7tit/index.tt` - Main landing page with equipment categories

### Equipment Templates
- `ve7tit/FT-897.tt` - Yaesu FT-897 HF/VHF/UHF All Mode Transceiver
- `ve7tit/FT-891.tt` - Yaesu FT-891 HF/50MHz Transceiver

## Error Handling
When a user attempts to access a non-existent equipment page, the system displays a helpful error message with a list of available equipment pages.

## Recent Fixes

### Mixed Case URL Handling
- Added support for mixed case URLs (`/Ve7tit` and `/Ve7tit/{equipment-id}`)
- Ensures consistent user experience regardless of URL capitalization

### Equipment Page Error Handling
- Improved error messages for non-existent equipment pages
- Added display of available equipment options when a page is not found
- Enhanced logging for better debugging

### Template Creation
- Added detailed equipment templates with consistent structure
- Each template includes specifications, description, setup details, and resources

## Adding New Equipment Pages
To add a new equipment page:

1. Create a new template file in `/Comserv/root/ve7tit/` with the name `{equipment-id}.tt`
2. Follow the standard template structure with specifications, description, etc.
3. Add a link to the new equipment page in the `index.tt` file under the appropriate category

## Related Files
- `/Comserv/lib/Comserv/Controller/Ve7tit.pm` - Controller file
- `/Comserv/root/ve7tit/index.tt` - Main landing page template
- `/Comserv/root/ve7tit/FT-897.tt` - Equipment template example
- `/Comserv/root/ve7tit/FT-891.tt` - Equipment template example
- `/Comserv/root/error.tt` - Error template used for not-found equipment