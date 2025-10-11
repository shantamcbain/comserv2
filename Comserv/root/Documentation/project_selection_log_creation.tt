# Project Selection and Log Creation

## Overview

This document describes the recent fixes made to the project selection and log creation functionality in the Comserv application.

## Changes Made

### 1. Project List Template

The `project_list.tt` template was updated to use consistent field names:

- Changed select element's id and name from "parent_id" to "project_id"
- Updated the condition for the "None" option to use selected_project_id
- This ensures that the project selection dropdown works correctly in all contexts

### 2. Add Project Template

The `add_project.tt` template was updated to properly include the project_list.tt template:

- Added proper parameters when including project_list.tt
- Now passes projects and selected_project_id to ensure correct project selection
- This fixes the sub-project creation functionality

### 3. Log Form Template

The `log_form.tt` template was updated to properly handle project selection:

- Updated to use selected_project_id instead of form_data.parent_id
- Now properly passes projects and selected_project_id to project_list.tt
- This ensures that the correct project is selected when creating a log entry

### 4. Log Controller

The Log controller was updated to use the correct field names:

- Changed to use project_id instead of parent_id when retrieving form parameters
- Added default value for project_id to prevent NULL values in project_code column
- This fixes the error "Column 'project_code' cannot be null" when creating log entries

## Impact

These changes ensure that:

1. Projects can be properly selected when creating a new todo
2. Sub-projects can be properly created
3. Log entries can be created with the correct project_code value

## Technical Details

The key issue was inconsistent field naming between templates and controllers. The project_list.tt template was using "parent_id" as the field name, but the Todo and Log controllers were expecting "project_id". This caused issues when creating todos, sub-projects, and log entries.

By standardizing on "project_id" as the field name and ensuring that all templates pass the correct parameters, we've fixed these issues and improved the overall reliability of the system.