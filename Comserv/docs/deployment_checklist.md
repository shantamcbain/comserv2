# Deployment Checklist

This document provides a checklist for deploying the Comserv application to ensure all dependencies and configurations are properly set up.

## Pre-Deployment Checks

### 1. Dependency Verification

Before deploying the application, ensure all required Perl modules are installed:

```bash
# Install cpanm if not already installed
sudo cpan App::cpanminus

# Install all dependencies from cpanfile
cd /path/to/comserv
sudo cpanm --installdeps .

# Verify critical dependencies manually
perl -e 'eval "use Net::CIDR"; print $@ ? "Net::CIDR is NOT installed\n" : "Net::CIDR is installed\n"'
```

If any modules show as not installed, install them manually:

```bash
sudo cpanm Net::CIDR
# Add other missing modules as needed
```

### 2. Configuration Files

Ensure all required configuration files exist and have correct permissions:

- [ ] `/opt/comserv/Comserv/db_config.json` - Database configuration
- [ ] `/opt/comserv/Comserv/config/network_map.json` - Network map configuration

### 3. Database Setup

Verify database connections:

```bash
# Test database connections
cd /opt/comserv/Comserv
perl -MComserv::Model::DBEncy -e 'print "DBEncy connection OK\n" if Comserv::Model::DBEncy->new->schema'
perl -MComserv::Model::DBForager -e 'print "DBForager connection OK\n" if Comserv::Model::DBForager->new->schema'
```

## Deployment Steps

### 1. Stop Running Services

```bash
sudo systemctl stop comserv-starman
```

### 2. Update Code

```bash
cd /opt/comserv
git pull origin main  # or your deployment branch
```

### 3. Install Dependencies

```bash
cd /opt/comserv/Comserv
sudo cpanm --installdeps .
```

### 4. Run Database Migrations (if needed)

```bash
cd /opt/comserv/Comserv
perl script/comserv_migration.pl upgrade
```

### 5. Test Application

```bash
# Test with development server
cd /opt/comserv/Comserv
CATALYST_DEBUG=1 perl script/comserv_server.pl -r
```

Verify the application starts without errors. Press Ctrl+C to stop the test server.

### 6. Start Production Server

```bash
sudo systemctl start comserv-starman
```

### 7. Verify Deployment

```bash
# Check if Starman is running
sudo systemctl status comserv-starman

# Check application logs for errors
tail -f /opt/comserv/logs/application.log
```

## Troubleshooting

### Common Issues

1. **Missing Perl Modules**

   If you see errors about missing modules:
   
   ```
   Can't locate Module/Name.pm in @INC
   ```
   
   Install the missing module:
   
   ```bash
   sudo cpanm Module::Name
   ```

2. **Database Connection Issues**

   Check the database configuration in `/opt/comserv/Comserv/db_config.json` and ensure the database server is running and accessible.

3. **Permission Issues**

   Ensure the application has proper permissions to read/write to its directories:
   
   ```bash
   sudo chown -R www-data:www-data /opt/comserv/Comserv/logs
   sudo chown -R www-data:www-data /opt/comserv/Comserv/root/static/uploads
   ```

4. **Starman vs Development Server Discrepancies**

   If the application works with `comserv_server.pl` but not with Starman, it may be due to:
   
   - Different environment variables
   - Different user permissions
   - Lazy loading vs eager loading of modules
   
   Check the Starman service configuration and logs for specific errors.