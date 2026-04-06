# User Controller

## Overview
The User controller manages user accounts, authentication, and profile management in the Comserv application. It handles login/logout functionality, user registration, profile management, and password operations.

## Key Features
- User registration and account creation
- User authentication and login with return-to-origin functionality
- Profile management and updates
- Password reset and recovery
- Role-based access control
- Session management

## Methods

### Authentication Methods
- `login`: Displays the login form and stores the referring page for post-login redirection
- `do_login`: Processes login form submissions and authenticates users
- `process_login`: Internal method that handles the core login logic
- `logout`: Handles user logout while preserving site context

### User Management Methods
- `register`: Handles new user registration
- `create_account`: Processes account creation form submissions
- `profile`: Displays and updates user profiles
- `change_password`: Allows users to change their password
- `reset_password`: Handles password reset requests
- `hash_password`: Internal method for secure password hashing

## Login Flow
1. When a user accesses a restricted page, they are redirected to the login page
2. The original page URL is stored in the session as `referer`
3. After successful authentication, the user is redirected back to the original page
4. The system supports explicit redirection through the `return_to` parameter

## Access Control
- Most actions are accessible to all users
- Profile management requires authentication
- Administrative functions require admin role
- Role-based access is enforced through session data

## Related Files
- User model in `/lib/Comserv/Model/User.pm`
- User templates in `/root/templates/user/`
- Authentication configuration in Catalyst configuration
- Login template at `/root/templates/user/login.tt`