# HostingSignup Controller

**Last Updated:** August 30, 2025  
**Author:** Shanta  
**Status:** Active

## Overview

The HostingSignup controller manages the process of signing up for hosting services. It handles the display of the signup form, validation of user input, creation of user and site records, and display of the success page. The system now includes duplicate site prevention and a complete site deletion feature.

## Key Features

- Displays the hosting signup form
- Validates user input for required fields and format
- Creates user accounts for new hosting customers
- Creates site records for new hosting customers
- Associates domains with sites
- Prevents duplicate site creation
- Handles error conditions gracefully
- Provides detailed logging for troubleshooting

## Controller Structure

### Attributes

- `logging`: Logging utility instance for detailed logging

### Methods

#### `auto`

Private method that runs before any action. It logs controller activity and initializes the debug_errors array.

#### `index`

Main entry point that displays the hosting signup form. Sets up the form with the appropriate action URL.

#### `process_signup`

Processes the form submission:
1. Validates required fields (full name, email, username, password, domain name, site name)
2. Validates format of email, username, password, and domain name
3. Creates a user account if validation passes
4. Creates a site record associated with the user
5. Creates a domain record associated with the site
6. Displays success page or error messages as appropriate

#### `success`

Displays the success page after a successful signup. This page is normally reached via a redirect from process_signup.

## Form Validation

The controller performs the following validations:

1. **Required Fields**:
   - Full name
   - Email address
   - Username
   - Password
   - Domain name
   - Site name

2. **Format Validation**:
   - Email: Must be a valid email format
   - Username: Alphanumeric and underscore characters only
   - Password: Minimum 8 characters
   - Domain name: Valid domain name format

## Error Handling

The controller handles errors at multiple levels:

1. **Validation Errors**: Redisplays the form with error messages
2. **User Creation Errors**: Displays specific error messages about user creation failures
3. **Site Creation Errors**: Displays specific error messages about site creation failures
4. **Exception Handling**: Uses Try::Tiny to catch and handle any exceptions during processing

## Logging

The controller uses the Comserv::Util::Logging module to log detailed information:

1. **Request Information**: Logs request path, method, and controller name
2. **Form Processing**: Logs when form processing begins
3. **Validation Errors**: Logs specific validation errors
4. **User Creation**: Logs success or failure of user creation
5. **Site Creation**: Logs success or failure of site creation
6. **Domain Association**: Logs domain association with site
7. **Exceptions**: Logs any exceptions that occur during processing

## Templates

The controller uses the following templates:

1. **signup_form.tt**: Displays the hosting signup form
2. **signup_success.tt**: Displays the success page after signup

## Related Files

- **Controller**: `/lib/Comserv/Controller/HostingSignup.pm`
- **Form Template**: `/root/hosting/signup_form.tt`
- **Success Template**: `/root/hosting/signup_success.tt`
- **Model**: `/lib/Comserv/Model/User.pm` (for user creation)
- **Model**: `/lib/Comserv/Model/Site.pm` (for site creation)
- **Model**: `/lib/Comserv/Model/DBEncy/SiteDomain.pm` (for domain association)

## Usage Flow

1. User clicks "Sign Up Now" on the hosting page
2. User is presented with the signup form
3. User fills out the form and submits
4. Controller validates the input
5. If validation fails, user is shown errors
6. If validation passes, controller creates user, site, and domain records
7. User is shown the success page with account details

## Debug Information

When debug mode is enabled, the controller:
1. Logs detailed information about each step of the process
2. Adds debug messages to the stash for display in the template
3. Pushes error messages to the debug_errors array for troubleshooting

## Duplicate Site Prevention

The system now includes robust duplicate site prevention:

1. **Proactive Checking**: The `add_site` method in Site.pm checks for existing sites with the same name before attempting to create a new site.
2. **Error Handling**: If a site with the same name already exists, the system returns a descriptive error message.
3. **Detailed Logging**: The system logs all duplicate site detection events for troubleshooting.
4. **User Feedback**: Clear error messages are displayed to the user when a duplicate site is detected.

## Site Deletion Feature

A complete site deletion system has been implemented and is accessible via `/site/delete`. This feature:

1. **Access Methods**:
   - By ID: `/site/delete?id=X` (where X is the site ID)
   - By name: `/site/delete?name=sitename` (where sitename is the site name)

2. **Confirmation Process**:
   - Shows a confirmation page with site details
   - Requires explicit confirmation via checkbox to prevent accidental deletions
   - Provides clear warnings about the irreversible nature of the action

3. **Complete Cleanup**:
   - Removes all database records related to the site
   - Deletes all associated domains
   - Removes controller files
   - Cleans up template directories

4. **User Feedback**:
   - Provides detailed error handling
   - Shows success messages after deletion
   - Redirects to the site list after successful deletion

## Future Enhancements

Potential future enhancements for this controller include:
1. Integration with payment processing
2. Support for additional hosting plans
3. Email confirmation of signup
4. Automatic provisioning of hosting resources
5. Integration with domain registration services
6. Batch site management operations