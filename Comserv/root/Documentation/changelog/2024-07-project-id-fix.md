# Project ID Fix in Todo System

## Issue Description

The Todo system was experiencing an error when creating new todo items. The error message was:

```
DBIx::Class::Storage::DBI::_dbh_execute(): DBI Exception: DBD::mysql::st execute failed: Column 'project_id' cannot be null [for Statement "INSERT INTO todo (...) VALUES (...)" with ParamValues: ... 15=undef, ...]
```

This error occurred because the project selection dropdown in the `project_list.tt` template was using incorrect field names, causing the selected project ID not to be passed to the controller.

## Root Cause

In the `project_list.tt` template, the select element was defined with:

```html
<select id="parent_id" name="parent_id">
    <option value="" [% IF !selected_project_id %]selected[% END %]>None</option>
    [% display_project_options(projects, selected_project_id, 0) %]
</select>
```

However, the Todo controller's `create` method was expecting a parameter named `project_id`:

```perl
my $project_id = $c->request->params->{project_id};
```

This mismatch in field names caused the `project_id` parameter to be null when creating a new todo item.

## Solution

The fix was to update the select element in the `project_list.tt` template to use the correct field name:

```html
<select id="project_id" name="project_id">
    <option value="" [% IF !selected_project_id %]selected[% END %]>None</option>
    [% display_project_options(projects, selected_project_id, 0) %]
</select>
```

This ensures that when the form is submitted, the selected project ID is passed with the parameter name `project_id`, which is what the controller is expecting.

## Implementation Details

1. Identified the issue by examining the error message and tracing it to the relevant code.
2. Located the `project_list.tt` template and found the mismatch in field names.
3. Updated the select element to use `id="project_id" name="project_id"` instead of `id="parent_id" name="parent_id"`.
4. Verified that the fix resolved the issue by testing the creation of a new todo item.

## Impact

This fix ensures that:
- New todo items can be created with the correct project association
- The project_id field is properly populated in the database
- Users can select projects from the dropdown and have them correctly associated with their todo items

## Date Implemented

July 2024