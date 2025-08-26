# Controller Routing Guidelines

## Overview

This document provides guidelines for setting up controllers in the Comserv application to ensure proper routing and prevent common issues like the "all sites returning the USBM home page" problem.

## Common Issues

One recurring issue in our application has been that all sites sometimes return the USBM home page. This happens when a controller incorrectly captures the root path (`/`) for all domains.

## Proper Controller Setup

### 1. Always Set a Namespace

Every controller should explicitly set its namespace to match the controller name:

```perl
# In Comserv::Controller::MySite
__PACKAGE__->config(namespace => 'MySite');
```

This ensures that the controller only responds to paths that start with `/MySite`.

### 2. Use Appropriate Action Attributes

- **:Path** - Use with caution. If used without arguments, it captures the controller's namespace.
  - `:Path('/')` - Captures the root path for ALL domains (avoid this in site-specific controllers)
  - `:Path('/specific')` - Captures a specific absolute path
  - `:Path` - Captures the controller's namespace path

- **:Local** - Safer option. Appends the method name to the controller's namespace.
  - `sub method :Local` - Captures `/Namespace/method`

- **:Chained** - Best for complex applications. Creates a chain of actions.

### 3. Include Proper Logging

Always include logging in your controllers:

```perl
use Comserv::Util::Logging;

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', 
        "Controller auto method called");
    return 1;
}
```

### 4. Forward to View

Always explicitly forward to the view in your action methods:

```perl
$c->stash(template => 'MyTemplate.tt');
$c->forward($c->view('TT'));
```

## Site-Specific Controllers

For site-specific controllers:

1. Name the controller after the site (e.g., `Comserv::Controller::USBM` for USBM site)
2. Set the namespace to match the site name
3. Use `:Path` without arguments or `:Local` for the index method
4. Do NOT use `:Path('/')` in site-specific controllers

## Root Controller

Only the `Comserv::Controller::Root` should handle the root path (`/`). It determines which site to display based on the domain and other factors.

## Testing

After creating or modifying a controller, test it with multiple domains to ensure it doesn't capture routes it shouldn't.

## Troubleshooting

If all sites start showing the same content:

1. Check for controllers using `:Path('/')` incorrectly
2. Verify the `sitedomain` table has correct entries
3. Check the logging for routing issues
4. Ensure the `Root` controller's `auto` and `index` methods are working correctly