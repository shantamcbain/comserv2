# Comserv Application

## Overview
Comserv is a comprehensive web application for managing various aspects of business operations, including project management, documentation, and site administration.

## Key Features
- Project Management System
- Documentation System
- Todo Management
- Site Administration
- User Management
- Theme System

## Documentation
Detailed documentation for each module can be found in the `docs` directory:

- [Project Management System](docs/project_management_system.md)
- [Documentation System](docs/documentation_system.md)
- [Theme System](docs/THEME_SYSTEM_README.md)

## Recent Updates
- Fixed project creation issue where 'group_of_poster' was being set to null
- Improved error handling and logging throughout the application
- Enhanced theme system with better organization and customization options

## Getting Started
1. Clone the repository
2. Install dependencies using `cpanm --installdeps .`
3. Configure your database settings in `config/database.yml`
4. Start the application with `plackup -r`

## Development
- Use the scripts in the `scripts` directory for common development tasks
- Follow the coding standards outlined in the documentation
- Submit bug reports and feature requests through the issue tracker