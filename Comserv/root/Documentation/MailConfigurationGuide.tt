# Mail Configuration Guide

## Overview

This guide explains how to configure and manage email settings in the Comserv application. Proper mail configuration is essential for system notifications, user registration emails, password resets, and other email-based features.

## Prerequisites

Before configuring the mail system, ensure you have:

1. Access to an SMTP server
2. SMTP server credentials (username and password)
3. Administrator access to the Comserv application

## Configuration Process

### Step 1: Access the Mail Configuration Form

1. Log in to the Comserv application with administrator credentials
2. Navigate to `/mail/add_mail_config_form` in your browser
3. You will see the mail configuration form

### Step 2: Enter SMTP Settings

Fill in the following fields:

1. **Site ID**: The ID of the site for which you're configuring mail
2. **SMTP Host**: The hostname of your SMTP server (e.g., `smtp.gmail.com`)
3. **SMTP Port**: The port number (typically 587 for TLS, 465 for SSL, or 25 for non-encrypted)
4. **SMTP Username**: Your SMTP authentication username
5. **SMTP Password**: Your SMTP authentication password

### Step 3: Submit the Configuration

1. Click the "Add Configuration" button
2. If successful, you'll see a confirmation message
3. The settings will be stored in the database for the specified site

## Testing the Configuration

After configuring the mail settings, you should test to ensure emails are sent correctly:

1. Navigate to the user management section
2. Create a test user with your email address
3. The system should send a welcome email
4. Check your inbox for the welcome email

If you don't receive the email, check the application logs for error messages.

## Configuration Storage

Mail configuration is stored in the `site_config` table with the following structure:

| site_id | config_key    | config_value        |
|---------|---------------|---------------------|
| 1       | smtp_host     | smtp.example.com    |
| 1       | smtp_port     | 587                 |
| 1       | smtp_username | user@example.com    |
| 1       | smtp_password | (encrypted password) |
| 1       | smtp_from     | noreply@example.com |

Each site can have its own mail configuration, allowing for different email settings across multiple sites.

## Updating Configuration

To update existing mail configuration:

1. Navigate to `/mail/add_mail_config_form`
2. Enter the site ID and new SMTP settings
3. Submit the form
4. The system will update the existing configuration or create a new one if it doesn't exist

## Troubleshooting

### Common Configuration Issues

1. **Authentication Failure**
   - Error: "Authentication failed" or "Invalid credentials"
   - Solution: Verify SMTP username and password

2. **Connection Issues**
   - Error: "Connection refused" or "Timeout"
   - Solution: Check if the SMTP server is accessible and the port is correct

3. **TLS/SSL Issues**
   - Error: "TLS/SSL negotiation failed"
   - Solution: Ensure you're using the correct port and security settings

4. **Missing Configuration**
   - Error: "SMTP configuration is missing"
   - Solution: Add the configuration using the form

### Checking Logs

To diagnose mail issues, check the application logs:

```bash
cat /home/shanta/PycharmProjects/comserv2/Comserv/script/logs/application.log
```

Look for entries related to email sending, which will include detailed error messages.

## Security Considerations

1. **Password Security**
   - Use app-specific passwords for services like Gmail
   - Regularly rotate SMTP passwords
   - Consider using environment variables for sensitive credentials

2. **TLS/SSL**
   - Always use TLS/SSL for SMTP connections when possible
   - Avoid using unencrypted connections (port 25)

3. **Sender Verification**
   - Ensure the "From" address is valid and authorized
   - Use domain verification if required by your email provider

## Gmail Configuration Example

If using Gmail as your SMTP server:

1. **SMTP Host**: smtp.gmail.com
2. **SMTP Port**: 587
3. **SMTP Username**: your.email@gmail.com
4. **SMTP Password**: (app-specific password)

Note: For Gmail, you'll need to:
- Enable 2-Step Verification
- Generate an App Password
- Use the App Password instead of your regular Gmail password

## Office 365 Configuration Example

If using Office 365:

1. **SMTP Host**: smtp.office365.com
2. **SMTP Port**: 587
3. **SMTP Username**: your.email@yourdomain.com
4. **SMTP Password**: (your password)

## Related Documentation

- [Mail System Documentation](/Documentation/mail_system.md)
- [Email Module Fix](/EMAIL_MODULE_FIX.md)
- [Server Deployment](/SERVER_DEPLOYMENT.md)