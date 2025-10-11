# Mail System Troubleshooting Guide

## Overview

This guide provides detailed troubleshooting steps for common mail system issues in the Comserv application. It includes diagnostic procedures, error interpretation, and solutions for various email-related problems.

## Diagnosing Mail Issues

### Check Application Logs

The first step in troubleshooting is to check the application logs:

```bash
cat /home/shanta/PycharmProjects/comserv2/Comserv/script/logs/application.log
```

Look for entries with the following patterns:
- "Failed to send email"
- "Email sent successfully"
- "SMTP configuration is missing"
- "Mail model failed"

### Verify Mail Configuration

Check if mail configuration exists for the current site:

1. Access the database and query the `site_config` table:
   ```sql
   SELECT * FROM site_config WHERE site_id = [YOUR_SITE_ID] AND config_key LIKE 'smtp_%';
   ```

2. Ensure all required configuration keys exist:
   - smtp_host
   - smtp_port
   - smtp_username
   - smtp_password
   - smtp_from

### Test Email Modules

Verify that the required email modules are installed and working:

```bash
cd /home/shanta/PycharmProjects/comserv2/Comserv/script
./test_email_modules.pl
```

If modules are missing, install them:

```bash
cd /home/shanta/PycharmProjects/comserv2/Comserv/script
./install_email_only.pl
```

## Common Issues and Solutions

### 1. Missing SMTP Configuration

**Symptoms:**
- "SMTP configuration is missing" error in logs
- Redirect to `/site/add_smtp_config_form`

**Solution:**
1. Navigate to `/mail/add_mail_config_form`
2. Enter the site ID and SMTP settings
3. Submit the form
4. Restart the application if necessary

### 2. Authentication Failures

**Symptoms:**
- "Authentication failed" in logs
- "Invalid credentials" error messages

**Solution:**
1. Verify SMTP username and password
2. For Gmail, ensure you're using an App Password
3. Check if the account has 2FA enabled
4. Test the credentials with another mail client

### 3. Connection Issues

**Symptoms:**
- "Connection refused" errors
- "Timeout" when sending emails

**Solution:**
1. Verify the SMTP host is correct
2. Check if the SMTP port is open and accessible
3. Test connectivity from the server:
   ```bash
   telnet smtp.example.com 587
   ```
4. Check for firewall or network restrictions

### 4. TLS/SSL Issues

**Symptoms:**
- "TLS/SSL negotiation failed"
- "Handshake failed" errors

**Solution:**
1. Ensure you're using the correct port for TLS/SSL
2. Verify SSL libraries are installed:
   ```bash
   cpanm --installdeps IO::Socket::SSL
   ```
3. Update SSL certificates if needed

### 5. Email Module Missing

**Symptoms:**
- "Can't locate Catalyst/View/Email.pm in @INC"
- "Email::Sender::Simple not found"

**Solution:**
Follow the instructions in `/EMAIL_MODULE_FIX.md`:
1. Make the helper scripts executable
2. Install only the essential email modules
3. Test if the modules are properly installed
4. Restart the server

### 6. Rate Limiting or Sending Quota

**Symptoms:**
- Emails work initially but stop after sending several
- "Daily sending quota exceeded" errors

**Solution:**
1. Check if your email provider has sending limits
2. Implement a queue system for high-volume sending
3. Consider using a dedicated email service provider

## Debugging Techniques

### Enable Debug Logging

Increase log verbosity to get more detailed information:

1. Edit the logging configuration to set the level to DEBUG
2. Restart the application
3. Attempt to send an email
4. Check the logs for detailed information

### Test Direct SMTP Connection

Test SMTP connection directly from the command line:

```bash
perl -MNet::SMTP -e '$smtp = Net::SMTP->new("smtp.example.com", Port => 587, Debug => 1); $smtp->auth("username", "password"); print "Connected\n" if $smtp;'
```

### Check Email Queue

If using a queuing system, check the email queue status:

```bash
# Example for a system using a file-based queue
ls -la /path/to/email/queue/
```

### Test with Simplified Code

Create a simple test script to isolate mail sending issues:

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Email::Simple;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTP;

my $email = Email::Simple->create(
    header => [
        To      => 'recipient@example.com',
        From    => 'sender@example.com',
        Subject => 'Test Email',
    ],
    body => "This is a test email.",
);

my $transport = Email::Sender::Transport::SMTP->new({
    host          => 'smtp.example.com',
    port          => 587,
    sasl_username => 'username',
    sasl_password => 'password',
});

eval {
    sendmail($email, { transport => $transport });
    print "Email sent successfully\n";
};
if ($@) {
    print "Error sending email: $@\n";
}
```

## Advanced Troubleshooting

### Check for Module Conflicts

Sometimes module conflicts can cause email issues:

```bash
perl -MEmail::Sender::Simple -e 'print $INC{"Email/Sender/Simple.pm"}, "\n"'
```

Ensure the path is within your application's library path.

### Verify SMTP Server Settings

Different SMTP servers have different requirements:

1. **Gmail**:
   - Requires TLS
   - Requires App Password if 2FA is enabled
   - Has sending limits

2. **Office 365**:
   - Requires TLS
   - May require specific authentication methods
   - May have tenant-specific restrictions

3. **Self-hosted**:
   - Check server logs for rejected connections
   - Verify DNS and reverse DNS settings
   - Check for IP blacklisting

### Test with Different Email Libraries

If persistent issues occur, try alternative email libraries:

```perl
# Using MIME::Lite
use MIME::Lite;

my $msg = MIME::Lite->new(
    From    => 'sender@example.com',
    To      => 'recipient@example.com',
    Subject => 'Test Email',
    Data    => "This is a test email."
);

$msg->send('smtp', 'smtp.example.com', AuthUser => 'username', AuthPass => 'password');
```

## Preventive Measures

### Regular Testing

Implement regular email testing:

1. Create a scheduled task to send test emails
2. Monitor delivery success rates
3. Set up alerts for email failures

### Configuration Backups

Maintain backups of working email configurations:

1. Export SMTP settings to a secure location
2. Document any special configuration requirements
3. Keep a history of configuration changes

### Fallback Mechanisms

Implement fallback mechanisms for critical emails:

1. Configure alternative SMTP servers
2. Use different email service providers as backups
3. Implement retry logic with exponential backoff

## Related Documentation

- [Mail System Documentation](/Documentation/mail_system.md)
- [Mail Configuration Guide](/Documentation/mail_configuration_guide.md)
- [Email Module Fix](/EMAIL_MODULE_FIX.md)
- [Server Deployment](/SERVER_DEPLOYMENT.md)