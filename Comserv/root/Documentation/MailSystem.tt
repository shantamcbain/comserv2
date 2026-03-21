# Mail System Documentation

## Overview

The Comserv Mail System provides functionality for sending emails and managing mail configurations across different sites. This document explains how to use and configure the mail system, including troubleshooting common issues.

## Components

The mail system consists of the following components:

1. **Mail Controller** (`Comserv::Controller::Mail`): Handles mail-related routes and actions
2. **Mail Model** (`Comserv::Model::Mail`): Provides email sending functionality
3. **Configuration Storage**: Stores SMTP settings in the database
4. **Templates**: Email templates and configuration forms
5. **Fallback Mechanism**: Alternative email sending method when primary method fails

## Mail Controller

The Mail Controller (`/lib/Comserv/Controller/Mail.pm`) provides the following actions:

- `index`: Displays the mail page with webmail links
- `send_welcome_email`: Sends a welcome email to new users
- `add_mail_config_form`: Displays the form to add mail configuration
- `add_mail_config`: Processes the mail configuration form submission

### Routes

- `/mail` - Main mail page with webmail links
- `/mail/add_mail_config_form` - Form to add mail configuration
- `/mail/add_mail_config` - Endpoint to process mail configuration

## Mail Model

The Mail Model (`/lib/Comserv/Model/Mail.pm`) provides the following methods:

- `send_email`: Sends an email using the configured SMTP settings
- `_get_smtp_config`: Retrieves SMTP configuration from the database

### Email Sending Process

1. Retrieve SMTP configuration from the database
2. Create an email using Email::Simple
3. Set up SMTP transport with the configuration
4. Send the email using Email::Sender::Simple
5. Log the result (success or failure)

## Configuration

### SMTP Configuration

SMTP settings are stored in the `site_config` table with the following keys:

- `smtp_host`: SMTP server hostname
- `smtp_port`: SMTP server port
- `smtp_username`: SMTP authentication username
- `smtp_password`: SMTP authentication password
- `smtp_from`: Default sender email address

### Adding Mail Configuration

To add mail configuration for a site:

1. Navigate to `/mail/add_mail_config_form`
2. Enter the site ID and SMTP settings
3. Submit the form
4. The configuration will be stored in the database

## Webmail Access

The system provides webmail access through the `/mail` route. The webmail URL is determined based on the current site:

```perl
$c->session->{MailServer} = "http://webmail.example.com";
```

Different sites have different webmail servers configured:

- ENCY/EV/Forager: `webmail.forager.com:20000`
- CS/LumbyThrift: `webmail.countrystores.ca:20000`
- Organic/Sky/AltPower: `webmail.computersystemconsulting.ca:20000`
- CSC/CSCDev/Extropia: `webmail.computersystemconsulting.ca:20000`
- ECF: `webmail.beemaster.ca:20000`
- USBM/3d/ENCY: `webmail.usbm.ca:20000`
- HE: `webmail.helpfullearth.com:20000`
- Skye: `webmail.skyefarm.com:20000`
- Apis/BMaster/Shanta/Brew/CSPS/TelMark: `webmail.beemaster.ca:20000`

## Fallback Mechanism

If the primary email sending method fails, the system uses a fallback mechanism in the Root controller:

```perl
# In Root.pm
sub send_email {
    # First try to use the Mail model
    eval {
        $c->model('Mail')->send_email(...);
    };
    
    # If Mail model fails, try fallback method
    if ($@) {
        # Use direct Email::Sender with fallback configuration
    }
}
```

## Troubleshooting

### Common Issues

1. **Missing SMTP Configuration**
   - Error: "SMTP configuration is missing"
   - Solution: Add SMTP configuration using the `/mail/add_mail_config_form` form

2. **Email Module Missing**
   - Error: "Can't locate Catalyst/View/Email.pm in @INC"
   - Solution: Follow the instructions in `/EMAIL_MODULE_FIX.md`

3. **Authentication Failure**
   - Error: "Authentication failed" or "Invalid credentials"
   - Solution: Verify SMTP username and password in the configuration

4. **Connection Issues**
   - Error: "Connection refused" or "Timeout"
   - Solution: Check if the SMTP server is accessible and the port is correct

### Logging

The mail system uses comprehensive logging to track email sending:

```perl
$self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'method_name',
    "Detailed message with relevant information");
```

Check the application log for detailed error messages:

```
/home/shanta/PycharmProjects/comserv2/Comserv/script/logs/application.log
```

## Best Practices

1. **Configuration Management**
   - Store sensitive SMTP credentials securely
   - Use environment variables for production credentials
   - Regularly rotate SMTP passwords

2. **Email Templates**
   - Use Template Toolkit for email templates
   - Include both HTML and plain text versions
   - Test templates with different email clients

3. **Error Handling**
   - Always check for errors when sending emails
   - Provide user-friendly error messages
   - Log detailed error information for debugging

4. **Security**
   - Use TLS/SSL for SMTP connections
   - Validate email addresses before sending
   - Implement rate limiting to prevent abuse

## Related Documentation

- [Email Module Fix](/EMAIL_MODULE_FIX.md)
- [Server Deployment](/SERVER_DEPLOYMENT.md)
- [Documentation System Overview](/Documentation/documentation_system_overview.md)