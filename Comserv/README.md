# Comserv Application

## Overview
Comserv is a comprehensive Catalyst-based web application for managing various aspects of business operations, including project management, documentation, and site administration.

## Key Features
- Project Management System
- Documentation System
- Todo Management
- Site Administration
- User Management
- Theme System

## Documentation
All documentation is located in the `Comserv/root/Documentation` directory. The documentation is accessible through the application's Documentation controller.

For developers and administrators, please refer to the documentation within the application for:
- Project Management System
- Documentation System
- Theme System
- Controller and Model documentation
- Installation and configuration guides

## Recent Updates
- Fixed project creation issue where 'group_of_poster' was being set to null
- Improved error handling and logging throughout the application
- Enhanced theme system with better organization and customization options

## Getting Started
1. Clone the repository
2. Install dependencies using `cpanm --installdeps .` or run the server script which will install dependencies automatically
3. Configure your database settings in `db_config.json` (see Documentation/general/database_connection.md for details)
4. Start the application with `perl Comserv/script/comserv_server.pl`

## Development Guidelines
- All documentation should be placed in the `Comserv/root/Documentation` directory
- Use .tt template files for documentation rather than .md files
- All CSS should be part of the theme system (located in `Comserv/root/static/css/themes/`)
- Follow the existing file structure and naming conventions
- Use the scripts in the `Comserv/script` directory for common development tasks

## Important Notes for Developers
- When working with documentation, prefer .tt files over .md files
- When both .tt and .md files exist for the same content, merge the content into the .tt file and remove the .md file
- Always check for existing files before creating new ones to avoid duplication
- All CSS should be managed through the theme system rather than in individual files