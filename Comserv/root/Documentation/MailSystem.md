# Comserv Mail System Documentation

**Last Updated:** August 20, 2024  
**Author:** Shanta  
**Status:** Active

## Overview

The Comserv application manages email functionality for multiple sites, including SMTP configuration, email sending, and Virtualmin integration for mail account creation.

## Components

### 1. Comserv::Controller::Mail

- **Routes**:
  - `/mail`: Displays mail overview and webmail links.
  - `/mail/add_mail_config_form`: Form for SMTP configuration.
  - `/mail/add_mail_config`: Saves SMTP settings to `site_config`.
  - `/mail/create_mail_account`: Creates mail accounts via Virtualmin API.
  - `/mail/send_welcome_email`: Sends welcome emails to new users.

- **Methods**:
  - `index`: Displays the mail index page.
  - `send_welcome_email`: Sends welcome email to new users.
  - `add_mail_config_form`: Displays the SMTP configuration form.
  - `add_mail_config`: Processes and saves SMTP configuration.
  - `create_mail_account`: Creates mail accounts via Virtualmin API.

### 2. Comserv::Model::Mail

- **Methods**:
  - `send_email`: Sends emails using SMTP configuration from the database.
  - `get_smtp_config`: Retrieves SMTP settings from `site_config` based on `site_id`.
  - `create_mail_account`: Creates mail accounts via Virtualmin API.

- **Features**:
  - Detailed logging with `log_with_details`.
  - Error handling with `try/catch`.
  - Hostname to IP address conversion for mail1.ht.home.
  - Debug message storage in `debug_msg`.

### 3. Comserv::Controller::Root

- **Method**: `send_email`
  - Centralized email sending with fallback to hardcoded config.
  - Uses the Mail model first, then falls back to direct Email::Sender.
  - Logs actions and errors with `log_with_details`.
  - Stores error messages in `debug_msg`.

### 4. Comserv::Controller::HostingSignup

- **Integration**:
  - Creates mail accounts during hosting signup.
  - Sends welcome emails to new users.
  - Handles errors gracefully to continue signup process.

### 5. Templates

- `user/mail.tt`: Displays webmail links.
- `mail/add_mail_config_form.tt`: Form for SMTP settings.

## Configuration

### SMTP Settings

SMTP settings are stored in the `site_config` table with the following keys:

- `smtp_host`: SMTP server hostname or IP address.
- `smtp_port`: SMTP server port (usually 25, 465, or 587).
- `smtp_ssl`: Whether to use SSL/TLS (0 or 1).
- `smtp_username`: SMTP authentication username.
- `smtp_password`: SMTP authentication password.
- `smtp_from`: Default sender email address.

### Virtualmin API

Virtualmin API credentials are stored in `comserv.conf`:

```
<Virtualmin>
    host        192.168.1.129
    username    admin
    password    your_secure_password
</Virtualmin>
```

### Fallback SMTP

Fallback SMTP settings are stored in `comserv.conf`:

```
<FallbackSMTP>
    host        192.168.1.129
    port        587
    ssl         starttls
    username    noreply@computersystemconsulting.ca
    password    your_secure_password
</FallbackSMTP>
```

## Hostname Resolution

The mail system automatically converts the hostname `mail1.ht.home` to the IP address `192.168.1.129` in the following places:

1. In `get_smtp_config` when retrieving SMTP settings.
2. In `create_mail_account` when connecting to the Virtualmin API.
3. In the fallback SMTP configuration in Root controller's `send_email` method.
4. In the `comserv.conf` file, we now use the IP address directly instead of the hostname.

## Email Sending Implementation

The mail system now uses `Net::SMTP` and `MIME::Lite` for more reliable email sending:

1. Direct SMTP Connection:
   - Uses `Net::SMTP` to establish a direct connection to the SMTP server
   - Provides detailed debugging information for troubleshooting
   - Handles each step of the SMTP protocol separately for better error handling

2. TLS Configuration:
   - Uses `starttls()` method for STARTTLS connections
   - Disables certificate verification for internal servers
   - Provides detailed error messages for TLS negotiation issues

3. Authentication:
   - Uses `Authen::SASL` for SMTP authentication
   - Supports various authentication methods (LOGIN, PLAIN, etc.)

These improvements are implemented in both the Mail model and the Root controller's fallback email method.

## Error Handling

- Errors are logged using `log_with_details` to `/home/shanta/PycharmProjects/comserv2/Comserv/script/logs/application.log`.
- User-facing errors are stored in `debug_msg` and displayed in templates.
- The system uses `try/catch` blocks for robust error handling.

## Logging

The mail system uses comprehensive logging with `log_with_details`:

```perl
$self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'method_name', 
    "Detailed message with relevant information");
```

## Setup Instructions

1. Ensure `site_config` table has SMTP settings for each site.
2. Configure Virtualmin on mail1.ht.home (192.168.1.129) for domains.
3. Update `comserv.conf` with Virtualmin API credentials.
4. Update `comserv.conf` with fallback SMTP settings.

## Troubleshooting

### Common Issues

1. **SMTP Connection Errors**:
   - Check if the SMTP server is reachable (ping, telnet).
   - Verify that the hostname resolves to the correct IP address.
   - Use the IP address directly instead of the hostname (we now use 192.168.1.129 directly).
   - Check if the SMTP port is open and accessible.
   - If you see "unable to establish SMTP connection to (mail1.ht.home)", it means the hostname-to-IP conversion is not working properly.
   - If you see "can't STARTTLS: 2.0.0 Ready to start TLS", it means there's an issue with the TLS negotiation. Check the SSL/TLS settings in the configuration.
   - If you see "unable to establish SMTP connection to (192.168.1.129) port 587", check if the SMTP server is running and accessible from the application server.
   
   The system now uses Net::SMTP for more reliable connections with better error reporting.

2. **Authentication Errors**:
   - Verify SMTP username and password.
   - Check if the SMTP server requires SSL/TLS.
   - Verify that the SMTP server allows the authentication method.

3. **Virtualmin API Errors**:
   - Check if the Virtualmin server is reachable.
   - Verify Virtualmin API credentials.
   - Check if the domain exists on the Virtualmin server.
   - Verify that the user has permission to create mail accounts.

### Debugging Steps

1. Check the application log for detailed error messages:
   ```
   tail -n 100 /home/shanta/PycharmProjects/comserv2/Comserv/script/logs/application.log
   ```

2. Test SMTP connectivity:
   ```
   telnet 192.168.1.129 587
   ```
   
   If the connection is successful, you should see a response like:
   ```
   Connected to 192.168.1.129.
   Escape character is '^]'.
   220 mail1.computersystemconsulting.ca ESMTP Postfix (Ubuntu)
   ```
   
   You can then test the SMTP protocol manually:
   ```
   EHLO localhost
   STARTTLS
   EHLO localhost
   AUTH LOGIN
   (enter base64-encoded username)
   (enter base64-encoded password)
   MAIL FROM: <noreply@computersystemconsulting.ca>
   RCPT TO: <recipient@example.com>
   DATA
   Subject: Test Email
   
   This is a test email.
   .
   QUIT
   ```

3. Test Virtualmin API connectivity:
   ```
   curl -k -u admin:password https://192.168.1.129:10000/virtual-server/remote.cgi
   ```

4. Check DNS resolution:
   ```
   nslookup mail1.ht.home
   ```
   
5. Test email sending with a simple Perl script:
   ```perl
   #!/usr/bin/perl
   use strict;
   use warnings;
   use Net::SMTP;
   use MIME::Lite;
   
   my $smtp = Net::SMTP->new(
       '192.168.1.129',
       Port => 587,
       Debug => 1,
       Timeout => 30
   );
   
   die "Could not connect to SMTP server" unless $smtp;
   
   $smtp->starttls();
   $smtp->auth('noreply@computersystemconsulting.ca', 'your_password');
   $smtp->mail('noreply@computersystemconsulting.ca');
   $smtp->to('recipient@example.com');
   $smtp->data();
   $smtp->datasend("Subject: Test Email\n\nThis is a test email.\n");
   $smtp->dataend();
   $smtp->quit();
   
   print "Email sent successfully\n";
   ```

## Server Context

- **Mail Server**: mail1.ht.home (192.168.1.129) is the target for mail accounts, running Virtualmin.
- **Catalyst App**: ComservProduction1 (172.30.50.206:5000) hosts the app.
- **PMG**: ProxmoxMailGateway (192.168.1.128, 172.30.244.163) relays SMTP to mail1.ht.home.

## Related Documentation

- [Mail Controller Documentation](controllers/Mail.md)
- [HostingSignup Mail Integration](controllers/HostingSignup_Mail.md)