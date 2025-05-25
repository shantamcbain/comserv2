# Todo System Documentation

**File:** /home/shanta/PycharmProjects/comserv/Comserv/root/Documentation/todo_system.md

## Overview

The Todo System in Comserv is a comprehensive task management solution that allows users to create, view, edit, and track tasks across different projects. This document provides a complete overview of the Todo System's functionality, components, and recent enhancements.

## Key Features

### 1. Todo Creation

Users can create new todo items with the following information:
- Site name
- Start date
- Project association
- Due date
- Subject
- Description
- Estimated man hours
- Accumulative time
- Status (NEW, IN PROGRESS, DONE)
- Priority (1-10)
- Sharing options (Public/Private)
- User assignment

### 2. Multiple Views

The Todo System offers several views to help users manage their tasks effectively:

#### List View
- Displays todos in a tabular format
- Includes filtering options
- Shows key information for each todo
- Provides action buttons for each todo (Add Log, Details, Edit)

#### Day View
- Shows todos for a specific day
- Includes navigation to move between days
- Color-codes todos based on priority
- Provides the same action buttons as the list view

#### Week View
- Displays todos in a calendar-style layout for the entire week
- Includes navigation to move between weeks
- Color-codes todos based on priority
- Allows adding todos for specific days

#### Month View
- Shows a calendar-style layout for the entire month
- Displays todos on their respective days
- Provides navigation between months
- Allows adding todos for specific days
- Color-codes todos based on priority

### 3. Filtering and Search

The Todo System includes comprehensive filtering options:
- Filter by time period (day, week, month, all)
- Filter by project
- Filter by status (new, in progress, completed, all)
- Search in subject, description, and comments

### 4. Todo Details and Editing

Users can view and edit todo details:

#### Details View
- Shows all information about a todo item
- Provides a form for updating the todo
- Includes buttons for adding log entries
- Features navigation buttons to return to different views:
  - Return to List View
  - Return to Day View
  - Return to Week View
  - Return to Month View
  - Return to Previous Page

#### Edit View
- Provides a comprehensive form for editing todo items
- Pre-fills the form with the current todo data
- Includes dropdowns for projects and users
- Features the same navigation buttons as the Details View

### 5. Log Integration

The Todo System integrates with the Log System:
- Users can create log entries directly from todo items
- Log entries can track time spent on todos
- The accumulative time is calculated and displayed on todo items

## Technical Components

### Templates

1. **addtodo.tt**
   - Form for creating new todo items
   - Includes project selection dropdown

2. **todo.tt**
   - Main list view template
   - Includes filtering options and view buttons
   - Displays todos in a tabular format

3. **day.tt**
   - Day view template
   - Shows todos for a specific day

4. **week.tt**
   - Week view template
   - Shows todos in a calendar-style layout

5. **month.tt**
   - Month view template
   - Shows todos in a monthly calendar

6. **details.tt**
   - Details view template
   - Shows all information about a todo item
   - Includes form for updating the todo

7. **edit.tt**
   - Edit form template
   - Provides a comprehensive form for editing todo items

8. **project_list.tt**
   - Reusable template for project selection
   - Used in addtodo.tt, edit.tt, and other templates
   - Contains a select element with name="project_id" for proper form submission
   - Implements a recursive macro to display projects with their sub-projects in a hierarchical structure

### Controller Actions

1. **index**
   - Main entry point for the Todo System
   - Handles filtering and displays the list view

2. **day**
   - Displays the day view
   - Handles navigation between days

3. **week**
   - Displays the week view
   - Handles navigation between weeks

4. **month**
   - Displays the month view
   - Handles navigation between months

5. **addtodo**
   - Displays the form for creating new todo items

6. **create**
   - Processes the form submission from addtodo
   - Creates new todo items in the database
   - Handles both project_id from the dropdown and manual_project_id from text input
   - Sets default values for missing fields
   - Validates and processes all form inputs before database insertion

7. **details**
   - Displays the details view for a specific todo item

8. **edit**
   - Displays the edit form for a specific todo item
   - Pre-fills the form with the current todo data

9. **modify**
   - Processes the form submission from edit or details
   - Updates todo items in the database

## Recent Enhancements

### 1. Enhanced Navigation in Details and Edit Views

Added comprehensive navigation options to both the details and edit views:
- Return to List View
- Return to Day View
- Return to Week View
- Return to Month View
- Return to Previous Page

These navigation buttons are displayed at both the top and bottom of the pages, ensuring users can easily return to their preferred view after viewing or editing a todo item.

### 2. Improved Filtering and Views

Enhanced the filtering and view options:
- Added a filter panel with dropdowns for time period, project, and status
- Added a search box for finding todos by keywords
- Added view buttons for switching between list, day, week, and month views
- Implemented color-coding based on priority

### 3. Project Selection and Log Creation

Fixed issues with project selection and log creation:
- Standardized field naming between templates and controllers
- Ensured proper parameter passing to project_list.tt
- Fixed the "Column 'project_code' cannot be null" error when creating log entries
- Fixed the "Column 'project_id' cannot be null" error when creating new todo items (July 2024)
  - Updated the select element in project_list.tt to use name="project_id" instead of name="parent_id"
  - This ensures the selected project ID is correctly passed to the controller

### 4. Todo Edit Functionality

Implemented a comprehensive edit functionality:
- Added a new edit action to the Todo controller
- Created a new edit.tt template
- Ensured the edit form includes all necessary fields and dropdowns
- Fixed the issue with the edit button in the todo list

## Usage Guidelines

### Creating a New Todo

1. Navigate to the Todo System by clicking on "Todo" in the main menu
2. Click on "Add New Todo" button
3. Fill in the required fields:
   - Site Name (pre-filled)
   - Start Date
   - Project (select from dropdown) - This field is required and must be selected
   - Due Date
   - Subject
   - Description
   - Estimated Man Hours
   - Priority
   - Status
4. Optional: If your project is not in the dropdown, you can enter a Manual Project ID
5. Click "Add Todo" to create the todo item

**Note:** The project selection is critical for proper todo creation. The system will use either the selected project from the dropdown or the manually entered project ID. If neither is provided, the database will reject the todo creation with a "Column 'project_id' cannot be null" error.

### Viewing Todos

1. Navigate to the Todo System
2. Use the view buttons to switch between list, day, week, and month views
3. Use the filter panel to filter todos by time period, project, status, or search terms

### Editing a Todo

1. Find the todo item you want to edit in any of the views
2. Click the "Edit" button for that todo
3. Update the fields as needed
4. Click "Update Todo" to save your changes

### Adding a Log Entry for a Todo

1. Find the todo item you want to log time for
2. Click the "Add Log" button for that todo
3. Fill in the log entry form
4. Click "Submit" to create the log entry

## Conclusion

The Todo System in Comserv provides a comprehensive solution for task management. With its multiple views, filtering options, and integration with the Log System, it helps users effectively manage their tasks and track their progress.