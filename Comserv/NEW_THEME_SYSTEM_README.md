# New Theme System

## Overview

The theme system has been refactored to follow a cleaner MVC pattern with centralized functionality. This makes the code more maintainable, reduces duplication, and provides a clear structure for future enhancements.

## Components

### 1. Model

**`Comserv::Model::Theme`** - Central model for all theme-related data operations:
- Loading and saving theme definitions
- Managing theme mappings
- Generating CSS files
- Theme validation

### 2. Controller

**`Comserv::Controller::Admin::Theme`** - Unified controller for all theme-related actions:
- Theme selection
- Theme editing
- CSS generation
- Theme preview
- Legacy URL redirection

### 3. Utilities

**`Comserv::Util::ThemeUtils`** - Helper functions for theme operations:
- CSS variable extraction
- Theme validation
- CSS generation helpers
- Preview generation

### 4. Configuration Files

All theme configuration is stored in a single location:
- `/comserv/Comserv/root/static/config/theme_definitions.json` - All theme definitions
- `/comserv/Comserv/root/static/config/theme_mappings.json` - Site to theme mappings

### 5. CSS Files

Theme CSS files are generated and stored in:
- `/comserv/Comserv/root/static/css/themes/`

### 6. Templates

All theme-related templates are in:
- `/comserv/Comserv/root/admin/theme/`

## How to Use the Theme System

### Setting a Theme for a Site

```perl
$c->model('Theme')->set_site_theme($c, $site_name, $theme_name);
```

### Getting a Site's Theme

```perl
my $theme = $c->model('Theme')->get_site_theme($c, $site_name);
```

### Creating a New Theme

```perl
my $theme_data = {
    name => "Theme Name",
    description => "Theme Description",
    variables => {
        "primary-color" => "#ffffff",
        "secondary-color" => "#f9f9f9",
        # ... other variables
    }
};

$c->model('Theme')->create_theme($c, $theme_name, $theme_data);
```

### Generating CSS Files

```perl
$c->model('Theme')->generate_all_theme_css($c);
```

## Theme Definition Structure

Each theme is defined in the `theme_definitions.json` file with the following structure:

```json
{
  "theme_name": {
    "name": "Display Name",
    "description": "Theme description",
    "variables": {
      "primary-color": "#ffffff",
      "secondary-color": "#f9f9f9",
      "accent-color": "#FF9900",
      "text-color": "#000000",
      "link-color": "#0000FF",
      "link-hover-color": "#000099",
      "background-color": "#ffffff",
      "border-color": "#dddddd",
      "table-header-bg": "#f2f2f2",
      "warning-color": "#f39c12",
      "success-color": "#27ae60"
    },
    "special_styles": {
      "body": "background-image: url('../images/pattern.jpg');"
    }
  }
}
```

## Theme Mapping Structure

Site to theme mappings are stored in the `theme_mappings.json` file:

```json
{
  "sites": {
    "SiteName1": "theme_name1",
    "SiteName2": "theme_name2"
  }
}
```

## Backward Compatibility

The new theme system includes a legacy URL redirection mechanism to ensure backward compatibility with existing links:

- `/themeadmin` → `/admin/theme`
- `/themeadmin/update_theme` → `/admin/theme/update`
- `/themeadmin/edit_theme_css/[theme]` → `/admin/theme/edit/[theme]`
- `/themeadmin/wysiwyg_editor/[theme]` → `/admin/theme/edit/[theme]`

## Future Enhancements

Planned enhancements for the theme system:

1. Theme import/export functionality
2. Visual theme editor with live preview
3. Theme inheritance for creating derived themes
4. User-specific theme preferences