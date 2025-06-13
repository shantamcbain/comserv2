# Cloudflare API Integration Enhancement

**Date:** July 1, 2025  
**Author:** System Administrator  
**Type:** Feature Enhancement  

## Overview

This update enhances the Cloudflare API integration by adding support for the Application ID and implementing role-based access control (RBAC) for Cloudflare API operations. These changes improve security and allow for more granular control over who can access and modify Cloudflare settings for different domains.

## Changes

### 1. Added Application ID Support

- Added a new `application_id` field to the Cloudflare section of the API credentials configuration
- Updated the CloudflareManager to use the Application ID when making API requests
- Modified the zone ID lookup process to use the Application ID for better authentication
- Updated the API Credentials management interface to include the Application ID field

### 2. Implemented Role-Based Access Control

- CSC (Computer System Consulting) admins now have unlimited access to all Cloudflare API functions
- SiteName admins only have access to domains associated with their SiteName
- Added domain-user association checking to enforce access restrictions
- Enhanced permission checking to support different levels of access based on user roles

### 3. Technical Implementation Details

- Created a new template for the API Credentials management interface
- Updated the CloudflareManager utility to support the new RBAC model
- Added methods to check domain-user associations
- Improved error handling and logging for better troubleshooting

## How to Use

### Setting Up Application ID

1. Log in as an administrator
2. Navigate to API Credentials Management
3. Enter your Cloudflare Application ID in the appropriate field
4. Save the changes

### Understanding Access Control

- **CSC Admins**: Have full access to all Cloudflare functions for all domains
- **SiteName Admins**: Can only manage DNS and cache for domains associated with their SiteName
- **Editors**: Can only edit DNS records for domains they have access to
- **Viewers**: Can only view DNS records without making changes

## Technical Notes

The Application ID is used in API requests to Cloudflare to identify the application making the request. This is different from the API token, which is used for authentication. The Application ID helps with rate limiting and provides better tracking of API usage.

The zone ID for each domain is now retrieved dynamically from the Cloudflare API using the domain name and Application ID, rather than being stored in the configuration file.