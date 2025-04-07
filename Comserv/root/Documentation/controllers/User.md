# User Controller

## Overview
The User controller manages user accounts, authentication, and profile management in the Comserv application.

## Key Features
- User registration and account creation
- User authentication and login
- Profile management and updates
- Password reset and recovery
- Role-based access control

## Methods
- `login`: Handles user login
- `logout`: Handles user logout
- `register`: Handles new user registration
- `profile`: Displays and updates user profiles
- `change_password`: Allows users to change their password
- `reset_password`: Handles password reset requests

## Access Control
- Most actions are accessible to all users
- Profile management requires authentication
- Administrative functions require admin role

## Related Files
- User model in `/lib/Comserv/Model/User.pm`
- User templates in `/root/templates/user/`
- Authentication configuration