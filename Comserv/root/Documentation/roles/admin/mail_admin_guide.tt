# Mail System Administration Guide

## Overview

This guide provides comprehensive instructions for administrators to configure, manage, and troubleshoot the Comserv Mail System. It covers SMTP configuration, email templates, monitoring, and best practices for maintaining reliable email functionality.

## System Architecture

The mail system consists of:

1. **Mail Controller** (`Comserv::Controller::Mail`): Handles mail-related routes and actions
2. **Mail Model** (`Comserv::Model::Mail`): Provides email sending functionality
3. **Configuration Storage**: Stores SMTP settings in the database
4. **Templates**: Email templates and configuration forms
5. **Fallback Mechanism**: Alternative email sending method when primary method fails

## Initial Setup

### Installing Required Modules

Ensure all required email modules are installed:

```bash
cd /home/shanta/PycharmProjects/comserv2/Comserv/script
./install_email_only.pl
```

This script installs:
- Email::Simple
- Email::Sender::Simple
- Email::Sender::Transport::SMTP
- Email::MIME
- Email::MIME::Creator

### Testing Module Installation

Verify that the modules are correctly installed:

```bash
cd /home/shanta/PycharmProjects/comserv2/Comserv/script
./test_email_modules.pl
```

## SMTP Configuration

### Adding SMTP Configuration

1. Navigate to `/mail/add_mail_config_form`
2. Enter the following information:
   - **Site ID**: The ID of the site for which you're configuring mail
   - **SMTP Host**: The hostname of your SMTP server
   - **SMTP Port**: The port number (typically 587 for TLS)
   - **SMTP Username**: Your SMTP authentication username
   - **SMTP Password**: Your SMTP authentication password
3. Click "Add Configuration"

### Configuration Storage

SMTP settings are stored in the `site_config` table with the following structure:

| site_id | config_key    | config_value        |
|---------|---------------|---------------------|
| 1       | smtp_host     | smtp.example.com    |
| 1       | smtp_port     | 587                 |
| 1       | smtp_username | user@example.com    |
| 1       | smtp_password | (encrypted password) |
| 1       | smtp_from     | noreply@example.com |

### Updating Configuration

To update existing configuration:

1. Use the same form at `/mail/add_mail_config_form`
2. Enter the site ID and new values
3. The system will update existing records or create new ones

### Multiple Site Configuration

For multi-site installations:

1. Configure each site separately using its site ID
2. Each site can have different SMTP settings
3. Ensure the `site_id` in the session matches the configured site

## Email Templates

### Default Templates

The system includes several default email templates:

1. **Welcome Email**: Sent to new users
2. **Password Reset**: Sent for password recovery
3. **Account Notification**: Sent when account details change

### Customizing Templates

To customize email templates:

1. Locate the template files in `/root/email/`
2. Edit the templates using Template Toolkit syntax
3. Templates support both HTML and plain text formats
4. Variables are passed from the controller to the template

Example template structure:

```
[% WRAPPER email/layouts/default.tt %]
<h1>Welcome to [% site_name %]</h1>
<p>Hello [% user.first_name %],</p>
<p>Your account has been created successfully.</p>
<p>Username: [% user.username %]</p>
[% END %]
```

## Monitoring and Maintenance

### Logging

The mail system logs all email activity:

```perl
$self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'method_name',
    "Detailed message with relevant information");
```

Check the application log for email-related entries:

```bash
cat /home/shanta/PycharmProjects/comserv2/Comserv/script/logs/application.log
```

### Testing Email Functionality

To test if emails are being sent correctly:

1. Navigate to the user management section
2. Create a test user with your email address
3. The system should send a welcome email
4. Check your inbox and the application logs

### Monitoring Email Queue

If using a queuing system:

1. Check the queue status regularly
2. Monitor for stuck or failed emails
3. Implement alerts for queue issues

## Security Considerations

### SMTP Authentication

1. Use strong, unique passwords for SMTP authentication
2. Rotate credentials regularly
3. Consider using app-specific passwords for services like Gmail

### TLS/SSL

1. Always use TLS/SSL for SMTP connections
2. Verify certificate validity
3. Keep SSL libraries updated

### Access Control

1. Restrict access to mail configuration pages
2. Audit configuration changes
3. Implement IP-based restrictions for sensitive operations

## Troubleshooting

### Common Issues

1. **Authentication Failures**
   - Verify SMTP username and password
   - Check if the account has 2FA enabled
   - For Gmail, ensure you're using an App Password

2. **Connection Issues**
   - Verify the SMTP host is correct
   - Check if the SMTP port is open and accessible
   - Test connectivity from the server

3. **Rate Limiting**
   - Check if your email provider has sending limits
   - Implement a queue system for high-volume sending
   - Consider using a dedicated email service provider

### Debugging Techniques

1. **Enable Debug Logging**
   - Increase log verbosity
   - Check logs for detailed error messages

2. **Test Direct SMTP Connection**
   - Use command-line tools to test SMTP connectivity
   - Verify authentication works outside the application

3. **Check Email Modules**
   - Verify all required modules are installed
   - Check for version conflicts

## Advanced Configuration

### Fallback SMTP Servers

Configure fallback SMTP servers in case the primary server fails:

1. Edit the `send_email` method in `Root.pm`
2. Update the fallback SMTP configuration
3. Test the fallback mechanism

```perl
# Example fallback configuration
my $transport = Email::Sender::Transport::SMTP->new({
    host => 'backup-smtp.example.com',
    port => 587,
    ssl => 'starttls',
    sasl_username => 'backup-user',
    sasl_password => 'backup-password',
});
```

### Email Throttling

Implement email throttling to prevent rate limiting:

1. Add a delay between emails
2. Batch emails for bulk sending
3. Implement a proper queuing system for high volume

### Custom Transport

For advanced needs, implement a custom transport:

```perl
package MyApp::EmailTransport;
use Moose;
extends 'Email::Sender::Transport::SMTP';

# Override methods as needed
```

## Best Practices

1. **Configuration Management**
   - Document all SMTP configurations
   - Use environment variables for sensitive data
   - Maintain backups of working configurations

2. **Testing**
   - Test email functionality after configuration changes
   - Implement regular automated tests
   - Test with different email clients and providers

3. **Monitoring**
   - Monitor email sending success rates
   - Set up alerts for persistent failures
   - Track delivery metrics

4. **Documentation**
   - Maintain up-to-date documentation
   - Document troubleshooting procedures
   - Create guides for common tasks

## Related Documentation

- [Mail System Documentation](/Documentation/mail_system.md)
- [Mail Configuration Guide](/Documentation/mail_configuration_guide.md)
- [Mail Troubleshooting Guide](/Documentation/mail_troubleshooting.md)
- [Email Module Fix](/EMAIL_MODULE_FIX.md)