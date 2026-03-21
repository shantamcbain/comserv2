# Server IP Display Enhancement

**Date:** May 31, 2025  
**Author:** Shanta  
**Status:** Completed

## Overview

This update adds the server's hostname and IP address to the page header for admin users. This information helps administrators verify which server is handling the request, which is particularly useful in proxy environments.

## Changes

1. Created a new utility module `Comserv::Util::SystemInfo` with functions to retrieve server information:
   - `get_server_hostname()` - Returns the server's hostname
   - `get_server_ip()` - Returns the server's IP address using multiple fallback methods
   - `get_system_info()` - Returns a hash with hostname, IP, OS, and Perl version

2. Modified the Root controller's `auto` method to:
   - Load the server information
   - Add the server hostname and IP to the stash

3. Updated the `pagetop.tt` template to display:
   - Domain (the domain in the request URL)
   - Client IP (the IP address of the client making the request)
   - Server hostname (the hostname of the server running the application)
   - Server IP (the IP address of the server running the application)

## Technical Details

The server IP detection uses multiple methods to ensure reliability:
1. First tries resolving the hostname via `Socket`
2. If that fails, parses the output of `ifconfig` or `ip addr` to find non-loopback interfaces
3. As a last resort, creates a UDP socket connection to a public DNS server (8.8.8.8) and determines the local IP from the socket information

## Testing

This change has been tested in the following environments:
- Direct access to the application server
- Access through a proxy server
- Multiple browsers and client devices

## Benefits

This enhancement helps administrators:
- Verify that requests are being routed to the correct server
- Diagnose proxy configuration issues
- Confirm load balancing is working correctly
- Identify which physical or virtual server is handling a request