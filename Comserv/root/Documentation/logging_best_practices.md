# Logging Best Practices

## Introduction

Proper logging is essential for debugging, monitoring, and maintaining the Comserv system. This document outlines best practices for logging throughout the application, with a focus on the `log_with_details` method.

## The `log_with_details` Method

The preferred logging method in the Comserv system is `log_with_details`, which provides comprehensive context for each log entry:

```perl
$self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'method_name',
    "Detailed message with relevant information");
```

### Parameters

1. **Context (`$c`)**: The Catalyst context object
2. **Log Level**: One of 'debug', 'info', 'warn', 'error', or 'fatal'
3. **File**: The current file (use `__FILE__`)
4. **Line**: The current line number (use `__LINE__`)
5. **Method Name**: The name of the current method
6. **Message**: A detailed description of what's happening

## Log Levels

Use appropriate log levels based on the importance and impact of the event:

- **debug**: Detailed information for debugging purposes
- **info**: General information about system operation
- **warn**: Warning conditions that don't affect normal operation
- **error**: Error conditions that affect specific operations
- **fatal**: Critical errors that prevent the system from functioning

## When to Log

### Always Log

1. **Route Access**: Log when a controller action is accessed
   ```perl
   $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'action_name',
       "Accessing action with parameters: " . join(', ', @parameters));
   ```

2. **Authentication Events**: Log login attempts, logouts, and permission checks
   ```perl
   $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_permission',
       "User $username checking permission for $resource: " . ($has_permission ? "granted" : "denied"));
   ```

3. **Data Modifications**: Log when data is created, updated, or deleted
   ```perl
   $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_record',
       "Updated record ID $id with values: " . $c->req->dump);
   ```

4. **Errors and Exceptions**: Log all errors with detailed information
   ```perl
   $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'process_data',
       "Error processing data: $error_message");
   ```

### Debug Logging

Use debug logging for detailed information that helps during development and troubleshooting:

```perl
$self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'complex_calculation',
    "Intermediate result: $result, inputs: $input1, $input2");
```

## User Feedback

In addition to logging, provide appropriate feedback to users:

```perl
# Log the error
$self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'save_document',
    "Failed to save document: $error_message");

# Add to stash for display
$c->stash(
    error_msg => "Unable to save your document. Please try again.",
    debug_msg => "Technical details: $error_message" # Only shown in debug mode
);
```

## Success Messages

For successful operations, log the success and provide user feedback:

```perl
# Log the success
$self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_user',
    "Successfully created user: $username");

# Add to stash for display
$c->stash(
    success_msg => "User account created successfully."
);
```

## Viewing Logs

Application logs are stored in:
- `/home/shanta/PycharmProjects/comserv2/Comserv/logs/application.log`

To view recent logs, use:
```bash
tail -n 50 /home/shanta/PycharmProjects/comserv2/Comserv/logs/application.log
```

To search for specific log entries:
```bash
grep -i "error" /home/shanta/PycharmProjects/comserv2/Comserv/logs/application.log
```

## Common Logging Patterns

### Controller Actions

```perl
sub action_name :Path('path') :Args(0) {
    my ($self, $c) = @_;
    
    # Log the action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'action_name',
        "Accessing action_name");
    
    # Action logic...
    
    # Log success
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'action_name',
        "Successfully completed action_name");
}
```

### Error Handling

```perl
eval {
    # Code that might fail
};
if ($@) {
    # Log the error
    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'method_name',
        "Error occurred: $@");
    
    # Add to stash for display
    $c->stash(
        error_msg => "An error occurred: " . $self->_user_friendly_error($@)
    );
}
```

## Conclusion

Consistent and detailed logging is essential for maintaining and troubleshooting the Comserv system. Always use the `log_with_details` method to ensure comprehensive logging throughout the application.