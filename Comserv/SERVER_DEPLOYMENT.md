# Comserv Server Deployment Guide

This guide explains how to deploy the Comserv application on a server.

## Prerequisites

- Perl 5.10 or higher
- MySQL or MariaDB
- Basic system utilities (curl, bash)

## Deployment Steps

1. **Copy the application files to the server**

   Copy the entire Comserv directory to your server.

2. **Make the startup script executable**

   ```bash
   chmod +x /path/to/Comserv/script/start_server.sh
   ```

3. **Start the application**

   ```bash
   cd /path/to/Comserv
   ./script/start_server.sh
   ```

   The startup script will:
   - Check for and install missing dependencies
   - Configure the application for the server environment
   - Start the application server

4. **For production deployment**

   For a production environment, you may want to use a process manager like Supervisor:

   ```bash
   # Example supervisor configuration
   [program:comserv]
   command=/path/to/Comserv/script/start_server.sh
   directory=/path/to/Comserv
   user=www-data
   autostart=true
   autorestart=true
   redirect_stderr=true
   stdout_logfile=/var/log/comserv.log
   ```

## Troubleshooting

If you encounter issues:

1. **Check the application logs**

   ```bash
   tail -f /path/to/Comserv/logs/application.log
   ```

2. **Verify dependencies**

   ```bash
   cd /path/to/Comserv
   perl -MModule::Find -e 'print join("\n", findallmod Catalyst)'
   ```

3. **Manual dependency installation**

   ```bash
   cd /path/to/Comserv
   cpanm --local-lib=local --installdeps .
   ```

## Application Resilience

The application has been designed to be resilient to missing dependencies:

- Email functionality will work if email modules are available, or gracefully degrade if they're not
- Session storage will use the best available option, falling back to simpler mechanisms if needed
- The application will start even if some non-critical modules are missing

This ensures that the application will run in various server environments, even if not all dependencies can be installed.