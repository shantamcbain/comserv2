# HostingSignup Mail Integration

**Last Updated:** August 20, 2024  
**Author:** Shanta  
**Status:** Active

## Overview

The HostingSignup controller integrates with the Mail system to create mail accounts on the Virtualmin server during the hosting signup process. This document explains how this integration works and how to configure it.

## Mail Account Creation Process

When a user signs up for hosting through the HostingSignup controller, the following mail-related actions occur:

1. User provides their email address, password, and domain name in the signup form
2. After successful user and site creation, the system attempts to create a mail account
3. The Mail model's `create_mail_account` method is called with the user's email, password, and domain
4. The Virtualmin API is used to create the mail account on the mail server
5. A welcome email is sent to the user if mail account creation is successful

## Code Flow

```perl
# In HostingSignup.pm
try {
    # Create mail account using Virtualmin API
    my $mail_result = $c->model('Mail')->create_mail_account(
        $c, 
        $params->{email}, 
        $params->{password}, 
        $params->{domain_name}
    );
    
    if ($mail_result) {
        # Send welcome email
        $c->forward('Mail', 'send_welcome_email', [$user]);
    }
} catch {
    # Log error and continue with signup process
}
```

## Configuration

The mail integration requires the following configuration in `comserv.conf`:

```
<Virtualmin>
    host        192.168.1.129
    username    admin
    password    your_secure_password
</Virtualmin>
```

## Error Handling

- If mail account creation fails, the signup process continues
- Errors are logged using `log_with_details`
- Error messages are added to `debug_msg` for display in the UI
- The user is still created and can access the site even if mail account creation fails

## Logging

The mail integration uses comprehensive logging:

```perl
$self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process_signup', 
    "Creating mail account for " . $params->{email} . " on domain " . $params->{domain_name});
```

## Troubleshooting

If mail account creation fails:

1. Check the application logs for detailed error messages
2. Verify Virtualmin API credentials in `comserv.conf`
3. Ensure the Virtualmin server is accessible from the application server
4. Verify that the domain exists on the Virtualmin server
5. Check that the email format is valid

## Related Components

- **Mail Model**: Provides the `create_mail_account` method
- **Mail Controller**: Provides the `send_welcome_email` method
- **Virtualmin API**: Used to create mail accounts on the mail server
- **Root Controller**: Provides fallback email sending functionality