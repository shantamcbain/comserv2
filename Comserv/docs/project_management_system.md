# Project Management System

## Overview
The Project Management System allows users to create, view, and manage projects within the Comserv application. Projects can be organized hierarchically with parent-child relationships, and each project can have associated tasks.

## Recent Updates

### 2025-04-17: Fixed Project Creation Issue
- **Issue**: Project creation was failing with the error "Column 'group_of_poster' cannot be null"
- **Fix**: Added a default value for the `group_of_poster` field when no user roles are available
- **Implementation**: 
  - Modified `create_project` method in `Project.pm` to check if user roles exist
  - Added a default value of 'general' for the `group_of_poster` field
  - Added appropriate logging for better troubleshooting

## Project Structure
Projects in the system can have the following attributes:
- Name
- Description
- Start and End Dates
- Status
- Project Code
- Project Size
- Estimated Man Hours
- Developer Name
- Client Name
- Comments
- Parent Project (for hierarchical organization)

## Key Components

### Controllers
- `Project.pm`: Main controller for project-related actions
  - `add_project`: Displays the form for adding a new project
  - `create_project`: Processes the form submission and creates a new project
  - `project`: Displays a list of all projects
  - `details`: Shows detailed information about a specific project

### Database
The projects are stored in the `projects` table with the following key fields:
- `id`: Unique identifier for the project
- `name`: Project name
- `description`: Project description
- `start_date`: Project start date
- `end_date`: Project end date
- `status`: Current status of the project
- `parent_id`: ID of the parent project (if any)
- `group_of_poster`: Group of the user who created the project (required field)
- `username_of_poster`: Username of the user who created the project

## Best Practices
1. Always ensure that required fields have default values to prevent database errors
2. Use proper error handling and logging for debugging issues
3. Validate user input before submitting to the database
4. Check for session variables before using them, as they might not always be available

## Troubleshooting
If you encounter issues with project creation:
1. Check if the user has proper roles assigned
2. Verify that all required fields are being populated
3. Review the application logs for detailed error messages
4. Ensure database schema matches the expected field structure