---
description: "Application logging standards"
globs: ["**/*.pm"]
alwaysApply: false
---

# Logging Protocol

**Standard**: Use `logging_with_details` method for all application logging.

## Example Format
```perl
$self->logging->log_with_details($c, __FILE__, __LINE__,
    'method_name',
    "Descriptive message with variables: $variable_value");
```

## Log Locations
- `/home/shanta/PycharmProjects/comserv2/Comserv/logs/application.log`
- `/home/shanta/PycharmProjects/comserv2/logs/application.log`
