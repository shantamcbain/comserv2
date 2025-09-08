# Controllers Documentation

## Overview

This page provides an index of all controller documentation in the Comserv system. Controllers are responsible for handling requests, processing data, and rendering views.

## Core Controllers

- [Root Controller](Root_Controller.md) - The main controller that handles the root path and determines which site to display
- [Documentation Controller](Documentation_Controller.md) - Handles the documentation system
- [Admin Controller](Admin_Controller.md) - Handles administrative functions
- [User Controller](User_Controller.md) - Handles user authentication and management

## Site-Specific Controllers

- [USBM Controller](USBM_Controller.md) - Universal School of Business Management site
- [CSC Controller](CSC_Controller.md) - Computer System Consulting site
- [Shanta Controller](Shanta_Controller.md) - Shanta's personal site

## Feature Controllers

- [HelpDesk Controller](HelpDesk_Controller.md) - Support ticket system
- [Todo Controller](Todo_Controller.md) - Task management system
- [Project Controller](Project_Controller.md) - Project management system
- [Proxy Controller](Proxy_Controller.md) - Proxy management system

## Guidelines

- [Controller Routing Guidelines](/Documentation/controller_routing_guidelines) - Best practices for setting up routes
- [Controller Naming Conventions](/Documentation/controller_naming_conventions) - Standards for naming controllers
- [Controller Testing](/Documentation/controller_testing) - How to test controllers

## Common Issues

- [Filename/Package Mismatch](/Documentation/documentation_filename_issue) - Critical issue with controller filenames not matching package names
- [All Sites Showing Same Content](/Documentation/all_sites_same_content) - Issue with controllers capturing the root path incorrectly

## Creating New Controllers

When creating a new controller:

1. Ensure the filename matches the package name
2. Set the namespace explicitly
3. Use appropriate action attributes
4. Include proper logging
5. Forward to the view explicitly

Example:

```perl
package Comserv::Controller::NewFeature;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

# Set the namespace
__PACKAGE__->config(namespace => 'NewFeature');

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', 
        "NewFeature controller auto method called");
    return 1;
}

sub index :Path :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        "NewFeature index action called");
    $c->stash(template => 'NewFeature/index.tt');
    $c->forward($c->view('TT'));
}

__PACKAGE__->meta->make_immutable;

1;
```