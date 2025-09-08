# Controller Fixes - August 2024

## Overview

This document details the fixes made to the application's controllers in August 2024, focusing on resolving routing issues and improving error handling.

## Issues Fixed

### 1. ProxyManager and Hosting Controller Loading

The ProxyManager and Hosting controllers were not being explicitly loaded in the application, causing "Page Not Found" errors when accessing these controllers.

**Solution:**
- Added explicit loading of these controllers in `Comserv.pm`:
  ```perl
  use Comserv::Controller::ProxyManager;
  use Comserv::Controller::Hosting;
  ```

### 2. Case-Sensitive Routing

The application was using case-sensitive routes, causing issues when users accessed URLs with different capitalization (e.g., `/ProxyManager` vs. `/proxymanager`).

**Solution:**
- Added case-insensitive route handlers in the Root controller:
  ```perl
  # Handle lowercase version
  sub proxymanager :Path('proxymanager') :Args(0) { ... }
  
  # Handle uppercase version
  sub ProxyManager :Path('ProxyManager') :Args(0) { ... }
  ```

### 3. Error Template Paths

Error templates were not properly defined, causing template not found errors when access was denied or pages were not found.

**Solution:**
- Created standardized error templates in `root/CSC/error/`:
  - `not_found.tt` - For 404 errors
  - `access_denied.tt` - For 403 errors
- Updated all controllers to use the correct template paths

### 4. User Role Checking

The application was using inconsistent methods for checking user roles, causing authentication issues even when users had the correct roles. Additionally, roles were stored as arrays in the session, but the code was treating them as strings.

**Solution:**
- Implemented a custom `check_user_roles` method in the Root controller that handles both array and string role formats:
  ```perl
  sub check_user_roles {
      my ($self, $c, $role) = @_;
      
      # First check if the user exists
      return 0 unless $self->user_exists($c);
      
      # Get roles from session
      my $roles = $c->session->{roles};
      
      # Check if the user has the admin role in the session
      if ($role eq 'admin') {
          # For admin role, check if user is in the admin group or has admin privileges
          return 1 if $c->session->{is_admin};
          
          # Check roles array
          if (ref($roles) eq 'ARRAY') {
              foreach my $user_role (@$roles) {
                  return 1 if lc($user_role) eq 'admin';
              }
          }
          # Check roles string
          elsif (defined $roles && !ref($roles)) {
              return 1 if $roles =~ /\badmin\b/i;
          }
          
          # Check user_groups
          my $user_groups = $c->session->{user_groups};
          if (ref($user_groups) eq 'ARRAY') {
              foreach my $group (@$user_groups) {
                  return 1 if lc($group) eq 'admin';
              }
          }
          elsif (defined $user_groups && !ref($user_groups)) {
              return 1 if $user_groups =~ /\badmin\b/i;
          }
      }
      
      # For other roles, check if the role is in the user's roles
      if (ref($roles) eq 'ARRAY') {
          foreach my $user_role (@$roles) {
              return 1 if lc($user_role) eq lc($role);
          }
      }
      elsif (defined $roles && !ref($roles)) {
          return 1 if $roles =~ /\b$role\b/i;
      }
      
      # Role not found
      return 0;
  }
  ```
- Updated controllers to use this method for role checking:
  ```perl
  my $root_controller = $c->controller('Root');
  unless ($root_controller->user_exists($c) && $root_controller->check_user_roles($c, 'admin')) {
      # Handle unauthorized access
  }
  ```
- Added improved logging for debugging role-based access issues:
  ```perl
  # Format roles for logging
  my $roles_debug = 'none';
  if (defined $c->session->{roles}) {
      if (ref($c->session->{roles}) eq 'ARRAY') {
          $roles_debug = join(', ', @{$c->session->{roles}});
      } else {
          $roles_debug = $c->session->{roles};
      }
  }
  
  $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'index',
      "Unauthorized access attempt. User: " . 
      ($c->session->{username} || 'none') . ", Roles: " . $roles_debug);
  ```

### 5. Environment-Specific NPM Configuration

Implemented environment-specific configuration for NPM API keys and settings:
- Added configuration files for different environments (production, staging, development)
- Updated controllers to load configuration from these files
- Added access scope restrictions based on environment

## Configuration Files

The following configuration files were created or updated:
- `/config/npm-production.conf`
- `/config/npm-staging.conf`
- `/config/npm-development.conf`

Each file follows this format:
```
<NPM>
  api_key = "npm_yourgeneratedkey123_1234567890"
  endpoint = "http://npm-host:81"
  environment = "production"  # or "staging"/"development"
  access_scope = "full"       # or "read-only"/"localhost-only"
</NPM>
```

## Controllers Updated

1. **ProxyManager.pm**
   - Added environment-specific configuration loading
   - Implemented access scope restrictions
   - Updated error template paths

2. **Hosting.pm**
   - Added environment-specific configuration loading
   - Implemented access scope restrictions
   - Updated error template paths

3. **Root.pm**
   - Added case-insensitive route handlers
   - Added default action for 404 errors
   - Added forwarding methods for ProxyManager and Hosting controllers

## Testing

The changes have been tested in the following scenarios:
- Accessing `/proxymanager` and `/ProxyManager` (both should work)
- Accessing `/hosting` and `/Hosting` (both should work)
- Testing access restrictions based on environment settings
- Verifying error pages display correctly

## Remote Access Improvements

### 1. Allowing Admin Access from Remote Locations

The application previously restricted access to the ProxyManager and Hosting controllers to localhost only, which prevented legitimate admin users from accessing these features remotely.

**Solution:**
- Modified the localhost-only restriction to allow admin users to access from any location
- Added support for private network ranges (192.168.x.x, 10.x.x.x, 172.16-31.x.x)
- Implemented security warnings for users accessing from remote locations
- Enhanced logging for remote access attempts

**Code Changes:**
```perl
# Check if this is a localhost-only environment and we're not on localhost or private network
# But allow admin users to access from anywhere
if ($self->npm_api->{access_scope} eq 'localhost-only' && 
    $c->req->address !~ /^127\.0\.0\.1$|^::1$|^192\.168\.|^10\.|^172\.(1[6-9]|2[0-9]|3[0-1])\./) {
    
    # Log the access attempt
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "Remote access to ProxyManager from IP: " . $c->req->address . 
        " by user: " . ($c->session->{username} || 'none'));
    
    # For security, add a warning in the stash that will be displayed to the user
    $c->stash->{security_warning} = "You are accessing this page from a remote location (" . 
        $c->req->address . "). For security reasons, some operations may be restricted.";
}
```

## Future Improvements

1. **URL Normalization**
   - Consider implementing a URL normalization middleware to handle case sensitivity globally

2. **Template Organization**
   - Reorganize templates into a more structured hierarchy (e.g., `/templates/errors/`, `/templates/admin/`, etc.)

3. **Configuration Management**
   - Implement a more robust configuration management system for environment-specific settings

4. **Remote Access Security**
   - Consider implementing additional security measures for remote admin access:
     - Two-factor authentication for admin users
     - IP whitelisting configuration
     - Rate limiting for failed authentication attempts