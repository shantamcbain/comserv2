# Site Configuration Troubleshooting Guide

This guide provides solutions for common issues encountered when configuring sites in the Comserv system.

## Common Issues and Solutions

### 1. Site Shows "Under Construction" Page

**Symptoms:**
- The site is configured in the database
- Accessing the domain shows the default "under construction" page

**Possible Causes and Solutions:**

a) **Incorrect home_view in Site table:**
   - The home_view field must match the controller name exactly
   - Solution: Update the home_view field in the Site table
   ```sql
   UPDATE Site SET home_view = 'CorrectControllerName' WHERE site_code = 'YourSiteCode';
   ```

b) **Domain not properly mapped:**
   - The domain might not be in the SiteDomain table or might have a typo
   - Solution: Check and update the domain entry
   ```sql
   SELECT * FROM SiteDomain WHERE domain LIKE '%yourdomain%';
   UPDATE SiteDomain SET domain = 'correct-domain.com' WHERE domain = 'typo-domain.com';
   ```

c) **Controller namespace mismatch:**
   - The namespace in the controller might not match the controller name
   - Solution: Update the namespace configuration in the controller
   ```perl
   # Change this:
   __PACKAGE__->config(namespace => 'incorrectname');
   
   # To this:
   __PACKAGE__->config(namespace => 'CorrectName');
   ```

### 2. "Page Not Found" Error

**Symptoms:**
- Accessing the site shows "The page you requested could not be found: /SiteName"

**Possible Causes and Solutions:**

a) **Controller namespace capitalization mismatch:**
   - The namespace in the controller doesn't match the capitalization used in the URL
   - Solution: Ensure the namespace matches exactly what's used in the URL
   ```perl
   # If the URL shows /SiteName, use:
   __PACKAGE__->config(namespace => 'SiteName');
   ```

b) **Controller not loaded:**
   - The controller might not be properly loaded by Catalyst
   - Solution: Check for syntax errors in the controller file and ensure it's in the correct directory

c) **Missing template:**
   - The template file might not exist or might be in the wrong location
   - Solution: Ensure the template exists at the path specified in the controller

### 3. Missing CSS or JavaScript

**Symptoms:**
- The site loads but appears unstyled or has JavaScript errors

**Possible Causes and Solutions:**

a) **Theme not configured:**
   - The site might not have a theme mapping
   - Solution: Add the site to the theme_mappings.json file
   ```json
   {
     "YourSiteName": "default"
   }
   ```

b) **Static files not accessible:**
   - The static files might not be in the correct location
   - Solution: Ensure static files are in the correct directory and accessible

### 4. Database Connection Issues

**Symptoms:**
- Error messages related to database connections
- Site fails to load with database errors

**Possible Causes and Solutions:**

a) **Database credentials:**
   - Check the database connection settings in the configuration file
   - Solution: Update the database credentials if needed

b) **Database schema:**
   - The database schema might not be up to date
   - Solution: Run database migrations or updates

### 5. Logging and Debugging

If you're having trouble identifying the issue:

a) **Check application logs:**
   ```bash
   tail -n 100 /home/shanta/PycharmProjects/comserv/Comserv/logs/application.log
   ```

b) **Enable debug mode:**
   - Set debug mode in the application configuration
   - Check the stash debug messages in the templates

c) **Add additional logging:**
   - Add more logging statements to the controller to track the flow
   ```perl
   $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'method_name', "Detailed message");
   ```

## Quick Reference for Site Configuration

### Database Tables

1. **Site Table:**
   - site_id: Unique identifier for the site
   - site_code: Code for the site (should match controller name)
   - name: Internal name for the site
   - display_name: Name displayed to users
   - home_view: Controller to use for the site's home page

2. **SiteDomain Table:**
   - domain_id: Unique identifier for the domain
   - site_id: Foreign key to the Site table
   - domain: The domain name (e.g., example.com)

### Controller Configuration

```perl
# Controller namespace must match the controller name with the same capitalization
__PACKAGE__->config(namespace => 'SiteName');

# Index method should set the correct template
sub index :Path :Args(0) {
    my ($self, $c) = @_;
    
    # Set the template
    $c->stash(
        template => 'SiteName/index.tt',
        title => 'Site Title',
    );
}
```

### Theme Configuration

The theme_mappings.json file maps sites to themes:

```json
{
  "SiteName": "theme_name"
}
```

## Contact Support

If you've tried all the troubleshooting steps and still can't resolve the issue, contact the system administrator or development team for further assistance.