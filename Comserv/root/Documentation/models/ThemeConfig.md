# ThemeConfig Model

## Overview
The ThemeConfig model manages theme configuration for the Comserv application. It handles loading, storing, and retrieving theme settings.

## Key Features
- Manages theme settings for different sites
- Provides methods to get and set theme configurations
- Handles theme inheritance and overrides
- Supports theme switching and customization

## Methods
- `get_all_themes`: Returns a list of all available themes
- `get_site_theme`: Gets the theme for a specific site
- `set_site_theme`: Sets the theme for a specific site
- `get_theme_config`: Gets the configuration for a specific theme

## Database Interactions
This model interacts with the following database tables:
- site_themes
- theme_configs
- theme_variables

## Related Files
- Theme templates in `/root/static/themes/`
- Theme CSS in `/root/static/css/themes/`