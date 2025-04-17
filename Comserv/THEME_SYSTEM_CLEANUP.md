# Theme System Cleanup

After implementing the new theme system, the following files can be safely deleted:

## Files to Delete

1. **Old ThemeController file (if it exists):**
   ```
   /comserv/Comserv/lib/Comserv/Controller/Admin/ThemeController.pm
   ```

2. **Old ThemeEditor controller (replaced by our new Theme controller):**
   ```
   /comserv/Comserv/lib/Comserv/Controller/Admin/ThemeEditor.pm
   ```

3. **Old ThemeManager utility (replaced by our new ThemeConfig model):**
   ```
   /comserv/Comserv/lib/Comserv/Util/ThemeManager.pm
   ```

4. **ThemeUtils utility (functionality now included in Theme controller):**
   ```
   /comserv/Comserv/lib/Comserv/Util/ThemeUtils.pm
   ```

5. **Temporary template files (if they exist):**
   ```
   /comserv/Comserv/root/admin/theme/new_index.tt
   /comserv/Comserv/root/admin/theme/new_edit_css.tt
   /comserv/Comserv/root/admin/theme/index.tt.new
   /comserv/Comserv/root/admin/theme/edit_css.tt.new
   ```

6. **Migration scripts (if they exist):**
   ```
   /comserv/Comserv/script/migrate_theme_templates.sh
   /comserv/Comserv/script/migrate_theme_controllers.sh
   /comserv/Comserv/script/cleanup_theme_system.sh
   /comserv/Comserv/script/make_migration_scripts_executable.sh
   /comserv/Comserv/script/delete_old_theme_files.sh
   /comserv/Comserv/script/delete_themecontroller.sh
   ```

## Verification Before Deletion

Before deleting these files, make sure the new theme system is working correctly:

1. Test the theme selection functionality
2. Test the theme editing functionality
3. Test the custom theme creation
4. Test the legacy URL redirection

## How to Delete

You can delete these files using the `rm` command:

```bash
# Delete old controller files
rm /comserv/Comserv/lib/Comserv/Controller/Admin/ThemeController.pm
rm /comserv/Comserv/lib/Comserv/Controller/Admin/ThemeEditor.pm

# Delete old utility file
rm /comserv/Comserv/lib/Comserv/Util/ThemeManager.pm

# Delete temporary template files
rm /comserv/Comserv/root/admin/theme/new_*.tt
rm /comserv/Comserv/root/admin/theme/*.new

# Delete migration scripts
rm /comserv/Comserv/script/migrate_theme_*.sh
rm /comserv/Comserv/script/cleanup_theme_system.sh
rm /comserv/Comserv/script/make_migration_scripts_executable.sh
```

## New Theme System Structure

The new theme system consists of the following components:

1. **Model:**
   - `Comserv::Model::ThemeConfig` - Handles theme configuration and CSS generation

2. **Controller:**
   - `Comserv::Controller::Admin::Theme` - Handles all theme-related actions

3. **Templates:**
   - `/comserv/Comserv/root/admin/theme/index.tt` - Theme management interface
   - `/comserv/Comserv/root/admin/theme/edit_css.tt` - Theme CSS editor

4. **Configuration Files:**
   - `/comserv/Comserv/root/static/config/theme_definitions.json` - Theme definitions
   - `/comserv/Comserv/root/static/config/theme_mappings.json` - Site to theme mappings

5. **CSS Files:**
   - `/comserv/Comserv/root/static/css/themes/` - Generated theme CSS files