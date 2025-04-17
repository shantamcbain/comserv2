# Proxy Troubleshooting Guide

**Last Updated:** April 9, 2025  
**Author:** Shanta  
**Status:** Active

## Overview

This guide provides information on how to troubleshoot proxy-related issues in the Comserv application, particularly when dealing with connections to production servers through proxy configurations.

## Server Information Display

As of version 0.023.0 of the pagetop.tt template, administrators can now see server information at the top of every page. This information includes:

1. The hostname from the request URI
2. The client's IP address

This feature is only visible to administrators and users with debug mode enabled.

## How to Use the Server Information Display

### Identifying Connection Paths

The server information display helps you identify which path your connection is taking:

#### When accessing through the proxy:
- **Server:** helpdesk.computersystemconsulting.ca
- **IP:** [Your external client IP]

#### When accessing directly:
- **Server:** 172.30.131.126:3000
- **IP:** [Your internal network IP]

This difference makes it immediately clear which path the connection is taking.

### Common Proxy Issues and Solutions

#### Issue: Unable to access the application through the proxy

**Symptoms:**
- The application works when accessed directly via IP but not through the domain name
- You see connection timeout errors

**Troubleshooting steps:**
1. Check the server information display to confirm you're attempting to connect through the proxy
2. Verify the proxy configuration in your web server (Apache/Nginx)
3. Check firewall rules to ensure the proxy server can reach the application server
4. Verify DNS settings to ensure the domain resolves to the correct proxy server

#### Issue: Authentication problems when using the proxy

**Symptoms:**
- You can log in when accessing directly but not through the proxy
- Session appears to be lost when navigating between pages

**Troubleshooting steps:**
1. Check session cookie settings to ensure they work with the proxy domain
2. Verify that the proxy is correctly forwarding authentication headers
3. Check for any IP-based restrictions in the application configuration

## Proxy Configuration Example

The current production setup uses the following proxy configuration:

- **Public URL:** helpdesk.computersystemconsulting.ca
- **Internal Application Server:** http://172.30.131.126:3000/

### Apache Proxy Configuration Example

```apache
<VirtualHost *:80>
    ServerName helpdesk.computersystemconsulting.ca
    
    ProxyPreserveHost On
    ProxyPass / http://172.30.131.126:3000/
    ProxyPassReverse / http://172.30.131.126:3000/
    
    # Forward real client IP
    RequestHeader set X-Forwarded-For %{REMOTE_ADDR}s
    RequestHeader set X-Forwarded-Proto http
</VirtualHost>
```

## Related Documentation

- [Server Administration Guide](admin_guide.md)
- [Network Configuration Guide](network_configuration.md)
- [Pagetop Server Information Display Changelog](changelog/2025-04-pagetop-hostname-display.md)