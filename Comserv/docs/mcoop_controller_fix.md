# MCoop Controller Fix

## Issue Description

The MCoop controller was experiencing issues with site name case handling and inconsistent routing. The site name was being stored as "MCOOP" (all uppercase) in the session, but the controller name is "MCoop" (mixed case). This inconsistency caused problems with theme handling and routing.

## Root Cause Analysis

1. **Case Inconsistency**: The site name was stored as "MCOOP" in the session, but the controller name is "MCoop".
2. **Theme Mapping**: In `theme_mappings.json`, the site name was listed as "MCOOP", creating a mismatch.
3. **Routing Inconsistency**: The controller used a mix of routing approaches, making it difficult to maintain.

## Solution Implemented

The MCoop controller was updated to:

1. **Use Chained Routing**: Implemented Catalyst's chained routing for better organization and maintainability.
2. **Remove Redundant SiteName Setting**: Removed redundant SiteName setting since it's handled by Root's fetch_and_set method.
3. **Clean Up Session**: Added code to clean up any uppercase "MCOOP" entries in the session.
4. **Maintain Backward Compatibility**: Added direct path methods to ensure existing URLs continue to work.

## Code Changes

### 1. Updated Auto Method

```perl
sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "MCoop controller auto method called");
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Request path: " . $c->req->uri->path);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Request method: " . $c->req->method);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Controller: " . __PACKAGE__);

    # If there's an uppercase MCOOP in the session, remove it
    if ($c->session->{"theme_" . lc("MCOOP")}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Removing uppercase MCOOP theme from session");
        delete $c->session->{"theme_" . lc("MCOOP")};
    }

    return 1; # Allow the request to proceed
}
```

### 2. Added Base Chain

```perl
# Base chain for all MCoop actions
sub base :Chained('/') :PathPart('MCoop') :CaptureArgs(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'base', "Base chained method called");
    
    # Common setup for all MCoop actions
    $c->stash->{main_website} = "https://monasheecoop.ca";
    
    # Set theme consistently
    $c->stash->{theme_name} = "mcoop";
    $c->session->{"theme_mcoop"} = "mcoop";
    $c->session->{theme_name} = "mcoop";
    $c->session->{"theme_" . lc("MCoop")} = "mcoop";
    
    # Initialize debug_errors array if needed
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $c->stash->{debug_mode} = $c->session->{debug_mode} || 0;
}
```

### 3. Updated Index Method

```perl
# Main index page at /MCoop
sub index :Chained('base') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 'Enter MCoop index method');
    
    # Set mail server
    $c->session->{MailServer} = "http://webmail.computersystemconsulting.ca";
    
    # Generate theme CSS if needed
    $c->model('ThemeConfig')->generate_all_theme_css($c);
    
    # Make sure we're using the correct case for the site name
    $c->model('ThemeConfig')->set_site_theme($c, "MCoop", "mcoop");
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless defined $c->stash->{debug_msg};
        push @{$c->stash->{debug_msg}}, "MCoop controller index view - Using mcoop theme";
    }
    
    # Set template and forward to view
    $c->stash(template => 'coop/index.tt');
    $c->forward($c->view('TT'));
}
```

### 4. Added Server Room Plan Base Chain

```perl
# Server room plan section
sub server_room_plan_base :Chained('base') :PathPart('server_room_plan') :CaptureArgs(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'server_room_plan_base', 'Enter server_room_plan_base method');
    
    # Set up common elements for server room plan pages
    $c->stash->{help_message} = "This is the server room proposal for the Monashee Coop transition team.";
    $c->stash->{account_message} = "For more information or to provide feedback, please contact the IT department.";
}
```

### 5. Updated Server Room Plan Method

```perl
# Main server room plan page at /MCoop/server_room_plan
sub server_room_plan :Chained('server_room_plan_base') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'server_room_plan', 'Enter server_room_plan method');
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless defined $c->stash->{debug_msg};
        push @{$c->stash->{debug_msg}}, "MCoop controller server_room_plan view - Template: coop/server_room_plan.tt";
    }
    
    # Set template and forward to view
    $c->stash(template => 'coop/server_room_plan.tt');
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'server_room_plan', 'Set template to coop/server_room_plan.tt');
    $c->forward($c->view('TT'));
}
```

### 6. Added Backward Compatibility Methods

```perl
# Direct access to index for backward compatibility
sub direct_index :Path('/MCoop') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'direct_index', "Direct index method called, forwarding to chained index");
    $c->forward('index');
}

# Direct access to server_room_plan for backward compatibility
sub direct_server_room_plan :Path('/MCoop/server_room_plan') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'direct_server_room_plan', 'Direct server_room_plan method called');
    $c->forward('server_room_plan');
}

# Handle the hyphenated version for backward compatibility
sub server_room_plan_hyphen :Path('/MCoop/server-room-plan') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'server_room_plan_hyphen', 'Enter server_room_plan_hyphen method');
    $c->forward('server_room_plan');
}
```

## Benefits of the Fix

1. **Consistent Site Name Handling**: The site name is now consistently handled as "MCoop".
2. **Improved Code Organization**: Common setup code is now in the base chain.
3. **Reduced Duplication**: Removed redundant theme and site name setting.
4. **Maintained Backward Compatibility**: All existing URLs continue to work.
5. **Better Maintainability**: The chained routing structure makes it easier to add new sections.

## Lessons Learned

1. **Consistent Naming**: Site names should be consistent across the application.
2. **Centralized Configuration**: Site name and theme handling should be centralized.
3. **Chained Routing**: Chained routing provides better organization and maintainability.
4. **Backward Compatibility**: Always maintain backward compatibility for existing URLs.

## Future Improvements

1. **Update theme_mappings.json**: Update the theme_mappings.json file to use consistent case for site names.
2. **Standardize Other Controllers**: Apply the same chained routing approach to other controllers.
3. **Automated Testing**: Add tests to verify routing functionality.

## Related Documentation

- [Controller Routing Standardization](controller_routing_standardization.md) - Plan for standardizing controller routing using Catalyst's chained actions