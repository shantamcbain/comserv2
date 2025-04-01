# Theme System README

## Overview

This document provides instructions for fixing and maintaining the theme system in the Comserv application.

## Recent Fixes

We've made the following improvements to the theme system:

1. Updated the `theme_definitions.json` file to include all the original themes (default, csc, apis, usbm, dark)
2. Enhanced the ThemeManager's `get_all_themes` method to load themes from the theme_definitions.json file
3. Improved the `validate_theme` method to be more lenient with theme names
4. Created a script to generate CSS files for all themes

## How to Fix Missing Themes

If you notice that some themes are missing from the theme selection dropdown, follow these steps:

1. Make sure the `theme_definitions.json` file contains all the required themes:
   ```
   /comserv/Comserv/root/static/config/theme_definitions.json
   ```

2. Make sure the `theme_mappings.json` file contains the correct mappings:
   ```
   /comserv/Comserv/root/static/config/theme_mappings.json
   ```

3. Run the script to generate CSS files for all themes:
   ```
   cd /comserv/Comserv
   perl script/generate_theme_css.pl
   ```

4. Restart the application to apply the changes.

## Theme System Architecture

The theme system consists of the following components:

1. **Theme Definitions**: JSON file that defines all available themes and their properties
   - Located at `/comserv/Comserv/root/static/config/theme_definitions.json`

2. **Theme Mappings**: JSON file that maps sites to themes
   - Located at `/comserv/Comserv/root/static/config/theme_mappings.json`

3. **CSS Files**: CSS files for each theme
   - Located in `/comserv/Comserv/root/static/css/themes/` directory

4. **ThemeManager**: Perl module that manages themes
   - Located at `/comserv/Comserv/lib/Comserv/Util/ThemeManager.pm`

5. **Theme Controller**: Controller for the theme management interface
   - Located at `/comserv/Comserv/lib/Comserv/Controller/Admin/Theme.pm`

## Adding a New Theme

To add a new theme:

1. Add the theme definition to `theme_definitions.json`
2. Run the `generate_theme_css.pl` script to generate the CSS file
3. Restart the application

## Troubleshooting

If you encounter issues with the theme system:

1. Check the application logs for errors
2. Verify that all theme files exist and have the correct permissions
3. Make sure the JSON files are valid and contain all required themes
4. Run the `generate_theme_css.pl` script to regenerate all theme CSS files

## Permissions

Make sure the following files and directories have the correct permissions:

1. `/comserv/Comserv/root/static/config/theme_definitions.json` (readable by the web server)
2. `/comserv/Comserv/root/static/config/theme_mappings.json` (readable and writable by the web server)
3. `/comserv/Comserv/root/static/css/themes/` directory (readable and writable by the web server)

You can use the following command to set the correct permissions:

```
chmod 664 /comserv/Comserv/root/static/config/theme_*.json
chmod 775 /comserv/Comserv/root/static/css/themes/
```