# WeaverBeck Site Setup Documentation

## Issue Summary
The weaverbeck.com domain was not being properly recognized by the system. While the site was configured in the database, accessing weaverbeck.com was showing the default "under construction" page instead of the WeaverBeck site content.

## Root Cause Analysis
The issue was caused by a namespace mismatch in the WeaverBeck controller. The controller was configured with a lowercase namespace (`weaverbeck`), but the system was trying to access it with the capitalized path (`/WeaverBeck`).

## Solution
We fixed the issue by updating the namespace configuration in the WeaverBeck controller to match the capitalized format that the system was using:

```perl
# Before:
__PACKAGE__->config(namespace => 'weaverbeck');

# After:
__PACKAGE__->config(namespace => 'WeaverBeck');
```

This change ensures that the controller can be properly accessed when the system routes to `/WeaverBeck`.

## Configuration Requirements
For a site to work properly in the system, the following configurations must be in place:

1. **Site Table Entry**:
   - The site must be registered in the Site table with a unique site_id
   - The site_code should match the controller name (e.g., "WeaverBeck")
   - The home_view field should be set to the controller name (e.g., "WeaverBeck")

2. **SiteDomain Table Entry**:
   - The domain (e.g., "weaverbeck.com") must be registered in the SiteDomain table
   - The site_id in the SiteDomain table must match the site_id in the Site table

3. **Controller Configuration**:
   - The controller namespace must match the capitalized controller name
   - Example: `__PACKAGE__->config(namespace => 'WeaverBeck');`

4. **Theme Configuration**:
   - The site must have a theme mapping in the theme_mappings.json file

## Troubleshooting Steps
If a site is not displaying correctly, check the following:

1. Verify the site entry in the Site table:
   ```sql
   SELECT * FROM Site WHERE site_code = 'YourSiteName';
   ```

2. Verify the domain entry in the SiteDomain table:
   ```sql
   SELECT * FROM SiteDomain WHERE domain = 'yourdomain.com';
   ```

3. Check that the home_view field in the Site table matches the controller name:
   ```sql
   SELECT home_view FROM Site WHERE site_code = 'YourSiteName';
   ```

4. Verify the controller namespace configuration:
   ```perl
   # Should be:
   __PACKAGE__->config(namespace => 'YourSiteName');
   ```

5. Check the application logs for any errors related to the site or controller.

## Additional Notes
- The capitalization of the controller name and namespace is important
- The home_view field in the Site table must match the controller name exactly
- The site_code in the Site table should match the controller name