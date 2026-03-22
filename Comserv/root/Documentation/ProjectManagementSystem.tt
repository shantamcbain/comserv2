# Project Management System

## Overview

The Project Management System in Comserv provides a comprehensive solution for creating, organizing, and tracking projects and their sub-projects. It supports hierarchical project structures, priority levels, status tracking, and integration with the Todo system.

## Features

### Project Hierarchy

- **Parent Projects**: Top-level projects that can contain sub-projects
- **Sub-Projects**: Projects that belong to a parent project, creating a hierarchical structure
- **Multi-Level Hierarchy**: Support for multiple levels of sub-projects (up to 3 levels deep)

### Project Properties

- **Name and Description**: Basic project identification
- **Priority Levels**: High, Medium, Low priorities with color-coded badges
- **Status Tracking**: New, In Progress, Completed status indicators
- **Dates**: Start date and end date tracking
- **Personnel**: Developer and client information
- **Project Code**: Unique identifier for the project

### Project Display and Navigation

- **Vertical Card Layout**: Projects displayed as collapsible cards in a vertical layout
- **Collapsible Interface**: Projects are collapsed by default and can be expanded to show details
- **Sub-Project Nesting**: Sub-projects displayed within their parent project cards
- **Visual Hierarchy**: Clear visual indicators for project relationships

### Filtering and Organization

- **Project/Sub-Project Filter**: Filter the display to show a specific project or sub-project
- **Priority Filter**: Filter projects by their priority level
- **Hierarchical Awareness**: When filtering by a sub-project, relevant parent projects remain visible
- **Clear Filters**: Option to reset all filters and view the complete project list

### Project Management

- **Add New Projects**: Create new top-level projects
- **Create Sub-Projects**: Add sub-projects to existing projects
- **Edit Projects**: Modify project details (admin users only)
- **View Project Details**: Access comprehensive project information

### Integration with Todo System

- **Project-Todo Association**: Todos can be associated with specific projects
- **Project Details View**: View all todos associated with a project
- **Todo Filtering**: Filter todos by project in the Todo system

## User Interface

### Project List Page

The main project list page (`/project/project`) displays all projects and provides filtering capabilities:

1. **Filter Panel**: Located at the top of the page
   - Project/sub-project dropdown
   - Priority filter dropdown
   - Apply and Clear buttons

2. **Project Cards**: Vertical list of collapsible project cards
   - Card header with project name and priority badge
   - Collapse/expand toggle
   - Project details when expanded (description, status, dates, personnel)
   - Action buttons (Details, Edit)
   - Sub-projects section (if applicable)

3. **Add New Project**: Button at the bottom of the page

### Project Details Page

The project details page (`/project/details`) provides comprehensive information about a specific project:

1. **Project Information**: Complete project details
2. **Associated Todos**: List of todos linked to the project
3. **Sub-Projects**: List of sub-projects (if any)
4. **Action Buttons**: Edit project, add sub-project, etc.

## Technical Implementation

### Templates

- **project.tt**: Main project list template with filtering and collapsible cards
- **projectdetails.tt**: Project details display
- **add_project.tt**: Form for adding new projects
- **editproject.tt**: Form for editing existing projects
- **project_list.tt**: Reusable component for project selection dropdowns

### Controller

The `Project.pm` controller handles all project-related actions:

- **project**: Displays the main project list with filtering
- **details**: Shows detailed information for a specific project
- **add_project**: Displays the form for adding a new project
- **create_project**: Processes the form submission for a new project
- **editproject**: Displays the form for editing a project
- **update_project**: Processes the form submission for editing a project

### Database Schema

Projects are stored in the `project` table with the following key fields:

- **id**: Unique identifier
- **name**: Project name
- **description**: Project description
- **parent_id**: Reference to parent project (null for top-level projects)
- **status**: Project status (1=New, 2=In Progress, 3=Completed)
- **priority**: Project priority (1=High, 2=Medium, 3=Low)
- **start_date**: Project start date
- **end_date**: Project end date
- **developer_name**: Name of the developer
- **client_name**: Name of the client
- **project_code**: Unique project code

## Usage Examples

### Filtering Projects

1. Navigate to the Projects page (`/project/project`)
2. Use the Project dropdown to select a specific project or sub-project
3. Use the Priority dropdown to filter by priority level
4. Click "Apply Filters" to update the display
5. Click "Clear Filters" to reset and show all projects

### Adding a New Project

1. Click the "Add New Project" button on the Projects page
2. Fill in the project details in the form
3. Select a parent project if creating a sub-project
4. Click "Create Project" to save

### Viewing Project Details

1. Find the project in the list
2. Click the "Details" button on the project card
3. View comprehensive project information and associated todos

### Editing a Project

1. Find the project in the list
2. Click the "Edit" button on the project card (admin users only)
3. Modify the project details in the form
4. Click "Update Project" to save changes

## Recent Updates

- **August 25, 2025**: Implemented vertical card layout with filtering capabilities
- **July 2024**: Fixed project ID issue in Todo system
- **June 2024**: Fixed project edit functionality

## Future Enhancements

- Project archiving functionality
- Enhanced reporting and analytics
- Project templates for quick creation
- Resource allocation and tracking
- Timeline visualization