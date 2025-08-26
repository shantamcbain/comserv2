# Hosting Signup Templates

**Last Updated:** August 30, 2025  
**Author:** Shanta  
**Status:** Active

## Overview

The hosting signup templates provide the user interface for the hosting signup process. These templates include the signup form and the success page displayed after a successful signup. The system now includes duplicate site prevention and a complete site deletion feature.

## Template Files

### 1. Signup Form Template

**File Path:** `/root/hosting/signup_form.tt`

This template displays the form for signing up for hosting services. It includes fields for account information, website information, and displays the details of the hosting package.

#### Key Features

- Responsive design using Bootstrap
- Form validation using HTML5 and JavaScript
- Clear error message display
- Detailed hosting package information
- Terms and conditions acceptance checkbox
- Duplicate site prevention feedback

#### Template Structure

1. **Metadata Section**
   - Title and version information
   - Debug information display (when debug mode is enabled)

2. **Form Section**
   - Account Information
     - Full Name
     - Email Address
     - Username
     - Password
   - Website Information
     - Domain Name
     - Site Name
     - Display Name (optional)
     - Description (optional)
   - Hosting Package Details
     - Features and specifications
     - Price information
   - Terms and Conditions
     - Acceptance checkbox
   - Submission Button

3. **JavaScript Section**
   - Form validation script
   - Error handling

#### Debug Features

The template includes debug features that are displayed when debug mode is enabled:
- Page version information
- Debug messages from the controller
- Form processing information

### 2. Success Page Template

**File Path:** `/root/hosting/signup_success.tt`

This template displays a success message and account information after a successful signup.

### 3. Site Deletion Confirmation Template

**File Path:** `/root/site/delete_confirm.tt`

This template displays a confirmation page before deleting a site, ensuring that users understand the implications of site deletion.

#### Key Features

- Clear warning about the irreversible nature of site deletion
- Detailed display of site information to be deleted
- Confirmation checkbox to prevent accidental deletions
- Cancel option to return to site details
- Responsive design using Bootstrap

#### Template Structure

1. **Warning Section**
   - Alert with warning about permanent deletion
   - List of components that will be deleted (configuration, domains, files)

2. **Site Details Section**
   - Table displaying site ID, name, display name, and description
   - Provides clear information about which site will be deleted

3. **Confirmation Form**
   - Hidden fields for site ID and confirmation flag
   - Required checkbox for confirming deletion understanding
   - Submit button for deletion
   - Cancel button to return to site details

### 4. Site Deletion Error Template

**File Path:** `/root/site/error.tt`

This template displays error messages when site deletion encounters problems.

#### Key Features

- Clear error message display
- Option to return to site list
- Detailed error information for troubleshooting

#### Key Features

- Confirmation message
- Account information display
- Website information display
- Next steps guidance
- Support contact information

#### Template Structure

1. **Metadata Section**
   - Title and version information
   - Debug information display (when debug mode is enabled)

2. **Confirmation Section**
   - Success message
   - Account Information
     - Username
     - Email
     - Full Name
   - Website Information
     - Domain Name
     - Site Name
     - Display Name

3. **Next Steps Section**
   - Instructions for getting started
   - Links to related resources
   - Support contact information

#### Debug Features

The template includes debug features that are displayed when debug mode is enabled:
- Page version information
- Debug messages from the controller
- Account creation details

## Usage

These templates are used by the HostingSignup controller to display the signup form and success page, and by the Site controller to handle site deletion. The controllers pass the following data to the templates:

### Signup Form Template

- `form_action`: URL for form submission
- `errors`: Array of validation errors (if any)
- `form_data`: Previously submitted form data (for redisplay after validation errors)
- `debug_msg`: Debug messages (when debug mode is enabled)

### Success Page Template

- `user`: User object with account information
- `site`: Site object with website information
- `domain`: Domain object with domain information
- `debug_msg`: Debug messages (when debug mode is enabled)

### Site Deletion Confirmation Template

- `site`: Site object with information about the site to be deleted
- `form_action`: URL for form submission
- `title`: Page title
- `debug_msg`: Debug messages (when debug mode is enabled)

### Site Deletion Error Template

- `error_message`: Specific error message about what went wrong
- `title`: Page title
- `debug_errors`: Array of detailed error messages for troubleshooting
- `debug_msg`: Debug messages (when debug mode is enabled)

## Styling

The templates use Bootstrap for styling and responsive design. Key styling elements include:

- Card-based layout for form sections
- Alert components for error messages
- List groups for feature lists
- Responsive grid system for layout
- Custom styling for the hosting package display

## Form Validation

The signup form includes both client-side and server-side validation:

1. **Client-Side Validation**
   - HTML5 required attributes
   - Input type validation (email, etc.)
   - JavaScript validation for more complex rules
   - Visual feedback using Bootstrap validation classes

2. **Server-Side Validation**
   - Performed by the HostingSignup controller
   - Validation errors are passed back to the template for display

## Related Files

- **Controller**: `/lib/Comserv/Controller/HostingSignup.pm`
- **CSS**: Bootstrap framework (loaded via CDN)
- **JavaScript**: Form validation script (included in the template)

## Best Practices

These templates follow these best practices:

1. **Separation of Concerns**
   - Template focuses on presentation
   - Logic is handled by the controller

2. **Responsive Design**
   - Works on mobile, tablet, and desktop devices
   - Uses Bootstrap grid system for layout

3. **Accessibility**
   - Proper form labels
   - ARIA attributes where appropriate
   - Semantic HTML structure

4. **Error Handling**
   - Clear error messages
   - Form data preservation on validation failure
   - Visual indication of error fields

5. **Debug Information**
   - Conditional display of debug information
   - Version tracking
   - Detailed error reporting

## Site Management

### Duplicate Site Prevention

The system now includes robust duplicate site prevention:

1. **User Feedback**: When a user attempts to create a site with a name that already exists, the system displays a clear error message.
2. **Form Data Preservation**: All form data is preserved when a duplicate site error occurs, allowing the user to modify just the site name.
3. **Detailed Error Messages**: The error messages specifically indicate that the site name is already in use.

### Site Deletion

The site deletion feature provides a clean way to manage the site lifecycle:

1. **Access Methods**:
   - By ID: `/site/delete?id=X` (where X is the site ID)
   - By name: `/site/delete?name=sitename` (where sitename is the site name)

2. **User Experience**:
   - Clear confirmation page with site details
   - Required confirmation checkbox for safety
   - Complete cleanup of all site components
   - Success message after deletion
   - Automatic redirect to site list

3. **Error Handling**:
   - Detailed error messages for various failure scenarios
   - Logging of all deletion attempts and results
   - User-friendly error display

## Future Enhancements

Potential future enhancements for these templates include:

1. **Multi-step Form Process**
   - Break the signup into multiple steps for better user experience
   - Progress indicator for multi-step process

2. **Enhanced Validation**
   - Real-time validation as the user types
   - Password strength meter
   - Domain availability checking

3. **Payment Integration**
   - Credit card input fields
   - Payment method selection
   - Order summary

4. **Plan Selection**
   - Allow users to select from multiple hosting plans
   - Dynamic pricing based on selected options
   - Feature comparison table

5. **Site Management Enhancements**
   - Batch site operations
   - Site cloning functionality
   - Site backup and restore options
   - Site suspension/reactivation features