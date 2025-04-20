# Controller Routing Standardization

## Overview

This document outlines the standardization plan for controller routing in the Comserv application. The goal is to establish a consistent, maintainable, and scalable approach to defining routes across all controllers.

## Background

The Comserv application previously used a mix of routing approaches across different controllers:

1. **Path-based Routing**: Using `:Path` attribute with absolute or relative paths
2. **Local-based Routing**: Using `:Local` attribute for controller-relative paths
3. **Chained Routing**: Using `:Chained` attribute to create hierarchical route structures

This inconsistency made the codebase harder to maintain and understand, especially for new developers.

## Case Study: MCoop Controller

The MCoop controller was updated to use chained routing as a pilot for this standardization effort. The controller previously had issues with site name case handling and inconsistent routing definitions.

### Before Standardization

```perl
# Inconsistent routing with Path attributes
sub index :Path :Args(0) {
    # Implementation
}

sub server_room_plan :Path('server_room_plan') :Args(0) {
    # Implementation
}

# Direct path for backward compatibility
sub server_room_plan_underscore :Path('/MCoop/server_room_plan') :Args(0) {
    # Implementation
}
```

### After Standardization

```perl
# Base chain for all actions
sub base :Chained('/') :PathPart('MCoop') :CaptureArgs(0) {
    # Common setup for all actions
}

# Main index page
sub index :Chained('base') :PathPart('') :Args(0) {
    # Implementation
}

# Base for server room plan section
sub server_room_plan_base :Chained('base') :PathPart('server_room_plan') :CaptureArgs(0) {
    # Common setup for server room plan section
}

# Main server room plan page
sub server_room_plan :Chained('server_room_plan_base') :PathPart('') :Args(0) {
    # Implementation
}

# Direct path for backward compatibility
sub direct_server_room_plan :Path('/MCoop/server_room_plan') :Args(0) {
    # Forward to the chained action
}
```

## Standardization Plan

### 1. Chained Routing as the Standard

All controllers should use chained routing as the primary method for defining routes. This approach offers several advantages:

- **Hierarchical Structure**: Creates a clear hierarchy of routes
- **Code Reuse**: Common setup code can be placed in parent chains
- **Flexible URL Structure**: Allows for complex URL structures while keeping code modular
- **Consistent Parameter Handling**: Clear distinction between path segments and parameters
- **Better for RESTful APIs**: Makes implementing RESTful patterns easier
- **Improved Maintainability**: Scales better for larger applications

### 2. Controller Structure Template

Each controller should follow this structure:

```perl
package Comserv::Controller::Example;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }

# Set the namespace for this controller
__PACKAGE__->config(namespace => 'example');

# Auto method for controller-wide setup
sub auto :Private {
    my ($self, $c) = @_;
    # Controller-wide setup
    return 1; # Allow the request to proceed
}

# Base chain for all actions in this controller
sub base :Chained('/') :PathPart('Example') :CaptureArgs(0) {
    my ($self, $c) = @_;
    # Common setup for all actions
}

# Main index page at /Example
sub index :Chained('base') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    # Implementation
}

# Section base at /Example/section
sub section_base :Chained('base') :PathPart('section') :CaptureArgs(0) {
    my ($self, $c) = @_;
    # Setup specific to this section
}

# Section index at /Example/section
sub section_index :Chained('section_base') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    # Implementation
}

# Item page at /Example/section/item/123
sub section_item :Chained('section_base') :PathPart('item') :Args(1) {
    my ($self, $c, $item_id) = @_;
    # Implementation using $item_id
}

# Backward compatibility routes
sub direct_index :Path('/Example') :Args(0) {
    my ($self, $c) = @_;
    $c->forward('index');
}

__PACKAGE__->meta->make_immutable;
1;
```

### 3. Naming Conventions

- **Base Methods**: Use `base` for the controller's base chain and `{section}_base` for section base chains
- **Index Methods**: Use `index` for the main controller index and `{section}_index` for section indices
- **Item Methods**: Use `{section}_{item}` for methods that handle specific items
- **Direct Methods**: Use `direct_{action}` for backward compatibility methods

### 4. Implementation Timeline

1. **Phase 1 (Current)**: Update MCoop controller as a pilot
2. **Phase 2**: Update high-traffic controllers (CSC, USBM, BMaster)
3. **Phase 3**: Update remaining controllers
4. **Phase 4**: Add automated tests to verify routing functionality

### 5. Backward Compatibility

To maintain backward compatibility during the transition:

- Keep direct path methods for existing routes
- Forward direct path methods to their chained counterparts
- Document all URL changes for reference

## Benefits of Standardization

1. **Improved Code Organization**: Clear hierarchy makes code structure more intuitive
2. **Reduced Duplication**: Common setup code is centralized
3. **Better Maintainability**: Adding new sections or subsections is easier
4. **Consistent URL Structure**: URLs follow a predictable pattern
5. **Improved Performance**: Less code execution per request due to shared setup

## Example: MCoop Controller Update

The MCoop controller was updated to use chained routing, which resolved several issues:

1. **Fixed Site Name Case**: Ensured consistent use of "MCoop" instead of "MCOOP"
2. **Improved Code Organization**: Common setup code moved to base chain
3. **Reduced Duplication**: Removed redundant theme and site name setting
4. **Maintained Backward Compatibility**: Added direct path methods for existing URLs

### Key Changes

- Added a base chain for common setup
- Added a server_room_plan_base chain for the server room plan section
- Moved common setup code to the appropriate base methods
- Added direct path methods for backward compatibility

## Next Steps

1. **Documentation Updates**: Update controller documentation to reflect the new routing standard
2. **Developer Training**: Train developers on the new routing standard
3. **Code Reviews**: Ensure new controllers follow the standard
4. **Automated Testing**: Add tests to verify routing functionality

## References

- [Catalyst Chained Actions Documentation](https://metacpan.org/pod/Catalyst::DispatchType::Chained)
- [Catalyst Controller Best Practices](https://metacpan.org/pod/Catalyst::Manual::CatalystAndMoose)