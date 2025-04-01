# Theme System Consolidation

## Overview

This document explains the consolidation of the theme system in the Comserv application. The theme system has been simplified to follow a cleaner MVC pattern and reduce duplication.

## Current Structure

The theme system now consists of the following components:

1. **Model**: `Comserv::Model::ThemeConfig`
   - Handles all theme data operations
   - Manages theme definitions and mappings
   - Generates CSS files

2. **Controller**: `Comserv::Controller::Admin::Theme`
   - Provides all theme management actions
   - Handles theme selection, editing, and creation
   - Includes legacy URL redirection for backward compatibility

3. **Configuration Files**:
   - `/comserv/Comserv/root/static/config/theme_definitions.json` - Theme definitions
   - `/comserv/Comserv/root/static/config/theme_mappings.json` - Site to theme mappings

4. **CSS Files**:
   - `/comserv/Comserv/root/static/css/themes/` - Generated theme CSS files

## Deprecated Files

The following files have been deprecated and replaced with empty stubs to prevent errors:

1. `Comserv::Controller::Admin::ThemeController.pm`
2. `Comserv::Controller::Admin::ThemeEditor.pm`

These files now contain only a package declaration and a return statement to prevent errors when old code tries to load them.

## Utility Files

The `Comserv::Util::ThemeManager.pm` utility has been deprecated, with its functionality moved to the `Comserv::Model::ThemeConfig` model.

## How to Use the Theme System

### Setting a Theme for a Site

```perl
$c->model('ThemeConfig')->set_site_theme($c, $site_name, $theme_name);
```

### Getting a Site's Theme

```perl
my $theme = $c->model('ThemeConfig')->get_site_theme($c, $site_name);
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

$c->model('ThemeConfig')->create_theme($c, $theme_name, $theme_data);
```

### Generating CSS Files

```perl
$c->model('ThemeConfig')->generate_all_theme_css($c);
```

## URLs

The theme system is accessible through the following URLs:

- `/admin/theme` - Theme management interface
- `/admin/theme/update` - Update theme for a site
- `/admin/theme/edit/[theme]` - Edit theme CSS
- `/admin/theme/create_custom` - Create a custom theme

Legacy URLs are automatically redirected to the new URLs:

- `/themeadmin` → `/admin/theme`
- `/themeadmin/update_theme` → `/admin/theme/update`
- `/themeadmin/edit_theme_css/[theme]` → `/admin/theme/edit/[theme]`
- `/themeadmin/wysiwyg_editor/[theme]` → `/admin/theme/edit/[theme]`