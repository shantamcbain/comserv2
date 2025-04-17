# Troubleshooting Guide for Developers

**Version:** 1.0  
**Last Updated:** May 31, 2024  
**Author:** Development Team

## Overview

This guide provides comprehensive troubleshooting information for developers working on the Comserv application. It covers common issues, debugging techniques, and solutions for various components of the system.

## Logging System

### Understanding the Logging System

Comserv uses a custom logging system that provides detailed context information:

```perl
$self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'method_name', 
    "Detailed message about the action");
```

Parameters:
- `$c`: Catalyst context
- Log level: 'debug', 'info', 'warn', 'error', or 'fatal'
- `__FILE__`: Current file path
- `__LINE__`: Current line number
- Method name: Identifier for the current method
- Message: Detailed description of the event

### Log File Locations

- Main application log: `/logs/application.log`
- Error log: `/logs/error.log`
- Debug log: `/logs/debug.log` (when debug mode is enabled)

### Enabling Debug Mode

Debug mode can be enabled in several ways:

1. **User Settings**: Users with appropriate permissions can enable debug mode in their account settings
2. **Session Variable**: Set `$c->session->{debug_mode} = 1;` in code
3. **Environment Variable**: Set `CATALYST_DEBUG=1` before starting the application

### Debug Messages

The application supports pushing debug messages to the UI:

```perl
# Add a single debug message
push @{$c->stash->{debug_msg}}, "Debug information: $variable";

# Add multiple debug messages
push @{$c->stash->{debug_msg}}, (
    "First debug message",
    "Second debug message: $variable",
    "Third debug message"
);
```

These messages will be displayed in the debug section of the page when debug mode is enabled.

## Common Issues and Solutions

### 1. Authentication Issues

#### 404 Error on Logout

**Symptoms:**
- User clicks logout and gets a 404 error
- "Page not found" when accessing `/user/logout`

**Possible Causes:**
- Missing logout method in the User controller
- Incorrect URL in the logout link

**Solutions:**
- Ensure the User controller has a properly defined logout method:

```perl
sub logout :Local {
    my ($self, $c) = @_;
    
    # Log the logout action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'logout', 
        "User '" . ($c->session->{username} || 'unknown') . "' logging out");
    
    # Clear the session
    $c->session({});
    
    # Set a success message
    $c->flash->{success_msg} = "You have been successfully logged out.";
    
    # Redirect to the home page
    $c->response->redirect($c->uri_for('/'));
    return;
}
```

- Verify the logout link uses the correct URI:

```html
<a href="[% c.uri_for('/user/logout') %]">Logout</a>
```

#### Login Redirect Issues

**Symptoms:**
- User is redirected to the wrong page after login
- User is stuck in a login loop

**Possible Causes:**
- Incorrect referer handling
- Session issues

**Solutions:**
- Check the referer handling in the login method:

```perl
# Store the referer URL if it hasn't been stored already
my $referer = $c->req->referer || $c->uri_for('/');

# Don't store the login page as the referer
if ($referer !~ m{/user/login} && $referer !~ m{/login} && $referer !~ m{/do_login}) {
    $c->session->{referer} = $referer;
}
```

- Ensure the redirect after login is properly implemented:

```perl
# Get redirect path
my $redirect_path = $c->session->{referer} || '/';

# Ensure we're not redirecting back to the login page
if ($redirect_path =~ m{/user/login} || $redirect_path =~ m{/login} || $redirect_path =~ m{/do_login}) {
    $redirect_path = '/';
}

# Clear the referer to prevent redirect loops
$c->session->{referer} = undef;

# Redirect to the appropriate page
$c->res->redirect($redirect_path);
```

### 2. Template Issues

#### Missing Footer

**Symptoms:**
- Footer is not displayed
- Template error in the logs

**Possible Causes:**
- Missing footer.tt file
- Path issues
- Template syntax errors

**Solutions:**
- Use TRY/CATCH blocks for footer inclusion:

```html
[% TRY %]
    [% INCLUDE 'footer.tt' %]
[% CATCH %]
    <!-- Fallback footer -->
    <footer>
        <div class="footer-content">
            <p>&copy; [% USE date; date.format(date.now, '%Y') %] Comserv. All rights reserved.</p>
            [% IF c.session.debug_mode == 1 %]
                <p>[% PageVersion %]</p>
                <p><a href="[% c.uri_for('/reset_session') %]">Reset Session</a></p>
            [% END %]
        </div>
    </footer>
[% END %]
```

- Check the footer.tt file exists and has correct syntax
- Verify the include path in the layout.tt file

#### Template Variable Issues

**Symptoms:**
- Empty content where variables should be displayed
- Raw TT code displayed (e.g., "[% variable %]")

**Possible Causes:**
- Variables not set in the controller
- Typos in variable names
- Incorrect variable scope

**Solutions:**
- Check variable assignment in the controller:

```perl
$c->stash(
    user => $user_data,
    template => 'user/profile.tt'
);
```

- Use defensive programming in templates:

```html
[% IF user.defined %]
    [% user.first_name %]
[% ELSE %]
    Guest
[% END %]
```

- Enable debug mode and inspect the stash contents

### 3. Database Issues

#### Database Connection Errors

**Symptoms:**
- "Database unavailable" errors
- Timeout errors when accessing the database

**Possible Causes:**
- Database server down
- Incorrect connection parameters
- Connection pool exhaustion

**Solutions:**
- Check database server status
- Verify connection parameters in the configuration
- Increase connection pool size if needed
- Add connection retry logic:

```perl
my $max_retries = 3;
my $retry_count = 0;
my $result;

while ($retry_count < $max_retries) {
    eval {
        $result = $c->model('DBEncy::User')->find({ username => $username });
    };
    
    if ($@) {
        $retry_count++;
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'database', 
            "Database connection attempt $retry_count failed: $@");
        sleep(1);  # Wait before retrying
    } else {
        last;  # Success, exit the loop
    }
}

if ($retry_count == $max_retries) {
    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'database', 
        "All database connection attempts failed");
    $c->stash(error_msg => "Database connection error. Please try again later.");
    $c->forward($c->view('TT'));
    return;
}
```

#### Query Performance Issues

**Symptoms:**
- Slow page loads
- Timeout errors
- High database load

**Solutions:**
- Add query logging for performance analysis:

```perl
$self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'database', 
    "Executing query: " . $query->as_query);
my $start_time = Time::HiRes::time();
my $result = $query->all;
my $end_time = Time::HiRes::time();
$self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'database', 
    "Query completed in " . ($end_time - $start_time) . " seconds");
```

- Optimize queries with proper indexing
- Use result caching for frequently accessed data
- Consider pagination for large result sets

## Debugging Techniques

### 1. Session Debugging

To debug session-related issues:

```perl
# Log all session variables
$self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'session', 
    "Session contents: " . Dumper($c->session));

# Add session info to debug messages
push @{$c->stash->{debug_msg}}, "Session ID: " . $c->sessionid;
push @{$c->stash->{debug_msg}}, "Username: " . ($c->session->{username} || 'not set');
push @{$c->stash->{debug_msg}}, "Roles: " . join(', ', @{$c->session->{roles} || []});
```

### 2. Request Debugging

To debug request parameters:

```perl
# Log all request parameters
$self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'request', 
    "Request parameters: " . Dumper($c->req->params));

# Log specific access methods
$self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'request',
    "Using body_parameters: " . Dumper($c->req->body_parameters));
$self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'request',
    "Using query_parameters: " . Dumper($c->req->query_parameters));
```

### 3. Template Debugging

To debug template processing:

1. Enable template debugging in the configuration:

```perl
__PACKAGE__->config(
    'View::TT' => {
        TEMPLATE_EXTENSION => '.tt',
        render_die => 1,
        DEBUG => 'undef',  # Shows undefined variables
    },
);
```

2. Use the DUMP directive in templates:

```html
[% DUMP c.session %]
[% DUMP user %]
```

3. Add debug comments in templates:

```html
<!-- DEBUG: Including navigation -->
[% INCLUDE 'Navigation/TopDropListMain.tt' %]
<!-- DEBUG: Navigation included -->
```

### 4. Database Debugging

To debug database operations:

1. Enable SQL logging in the configuration:

```perl
__PACKAGE__->config(
    'Model::DBEncy' => {
        schema_class => 'Comserv::Schema',
        connect_info => {
            dsn => 'dbi:mysql:database=comserv',
            user => 'username',
            password => 'password',
            AutoCommit => 1,
            RaiseError => 1,
            mysql_enable_utf8 => 1,
            on_connect_do => ['SET NAMES utf8'],
            quote_char => '`',
            name_sep => '.',
            debug => 1,  # Enable SQL debugging
        },
    },
);
```

2. Log database operations manually:

```perl
$self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'database', 
    "Finding user with username: $username");
my $user = $c->model('DBEncy::User')->find({ username => $username });
$self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'database', 
    "User found: " . ($user ? 'yes' : 'no'));
```

## Performance Optimization

### 1. Template Caching

Enable template caching for production:

```perl
__PACKAGE__->config(
    'View::TT' => {
        TEMPLATE_EXTENSION => '.tt',
        CACHE_SIZE => 128,  # Cache up to 128 templates
        PRE_PROCESS => 'config/main',
    },
);
```

### 2. Database Optimization

Optimize database access:

```perl
# Cache frequently accessed data
my $cache_key = "user_$username";
my $user;

if ($c->cache->get($cache_key)) {
    $user = $c->cache->get($cache_key);
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'cache', 
        "User retrieved from cache: $username");
} else {
    $user = $c->model('DBEncy::User')->find({ username => $username });
    if ($user) {
        $c->cache->set($cache_key, $user, 3600);  # Cache for 1 hour
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'cache', 
            "User added to cache: $username");
    }
}
```

### 3. Session Optimization

Optimize session handling:

```perl
# Only update session if necessary
if ($c->session->{last_updated} < time() - 300) {  # 5 minutes
    $c->session->{last_updated} = time();
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'session', 
        "Session updated");
}
```

## Security Considerations

### 1. Input Validation

Always validate user input:

```perl
# Validate email format
unless ($email =~ /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/) {
    $c->flash->{error_msg} = "Invalid email format.";
    $c->response->redirect($c->uri_for('/user/settings'));
    return;
}
```

### 2. CSRF Protection

Implement CSRF protection for forms:

```perl
# In the controller that displays the form
sub display_form :Local {
    my ($self, $c) = @_;
    
    # Generate a CSRF token
    my $csrf_token = $self->generate_csrf_token($c);
    $c->session->{csrf_token} = $csrf_token;
    
    $c->stash(
        csrf_token => $csrf_token,
        template => 'form.tt'
    );
}

# In the form template
<form method="post" action="[% c.uri_for('/submit_form') %]">
    <input type="hidden" name="csrf_token" value="[% csrf_token %]">
    <!-- Form fields -->
    <button type="submit">Submit</button>
</form>

# In the controller that processes the form
sub submit_form :Local {
    my ($self, $c) = @_;
    
    # Verify CSRF token
    my $submitted_token = $c->req->params->{csrf_token};
    my $stored_token = $c->session->{csrf_token};
    
    unless ($submitted_token && $stored_token && $submitted_token eq $stored_token) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'security', 
            "CSRF token validation failed");
        $c->flash->{error_msg} = "Security validation failed. Please try again.";
        $c->response->redirect($c->uri_for('/display_form'));
        return;
    }
    
    # Clear the token to prevent reuse
    $c->session->{csrf_token} = undef;
    
    # Process the form
    # ...
}
```

### 3. SQL Injection Prevention

Use parameterized queries to prevent SQL injection:

```perl
# Unsafe
my $result = $c->model('DB')->schema->resultset('User')
    ->search_literal("username = '$username'");  # DON'T DO THIS

# Safe
my $result = $c->model('DB')->schema->resultset('User')
    ->search({ username => $username });  # DO THIS
```

## Advanced Debugging

### 1. Using the Catalyst Debug Screen

Enable the Catalyst debug screen for development:

```perl
# In your development environment
$ENV{CATALYST_DEBUG} = 1;
```

This provides:
- Request details
- Stash contents
- Session information
- Timing data
- Log messages

### 2. Remote Debugging

For remote debugging:

1. Install the Catalyst::Plugin::RemoteDebug module
2. Configure it in your application
3. Connect to the debug port from your development machine

### 3. Profiling

Profile your application to identify bottlenecks:

```perl
use Devel::NYTProf;

# Start profiling
DB::enable_profile();

# Code to profile
# ...

# Stop profiling
DB::disable_profile();
```

Generate a report:

```bash
nytprofhtml --file=/path/to/nytprof.out --out=/path/to/report
```

## Getting Help

If you encounter issues not covered in this guide:

1. Check the application logs for detailed error messages
2. Review the Catalyst documentation for framework-specific issues
3. Search the developer forums for similar problems
4. Submit a detailed bug report with:
   - Error messages
   - Steps to reproduce
   - Expected vs. actual behavior
   - Relevant code snippets
   - Log excerpts