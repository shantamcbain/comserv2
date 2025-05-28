# Cloudflare SiteName Domain Mappings

**Date:** 2025-07-15  
**Author:** System Administrator  
**Type:** Enhancement  

## Description

Added functionality to display SiteName domain mappings in the Cloudflare DNS Management interface. This enhancement allows users to see the mapping between site names and their associated domains, making it easier to manage DNS records for specific sites.

## Changes

1. Added a new section to the Cloudflare DNS Management interface that displays SiteName domain mappings
2. Updated the CloudflareAPI controller to fetch site names and their associated domains from the Site and SiteDomain tables
3. Enhanced the template to display all domains associated with each site

## Files Modified

- `/Comserv/lib/Comserv/Controller/CloudflareAPI.pm`
- `/Comserv/root/cloudflare/index.tt`

## Files Created

- `/Comserv/root/Documentation/changelog/2025-07-15-cloudflare-sitename-domain-mappings.md`

## How to Use

1. Navigate to the Cloudflare DNS Management interface
2. Scroll down to the "SiteName Domain Mappings" section
3. View the list of site names and all their associated domains
4. Click on the "Manage DNS" button to manage DNS records for a specific domain

## Technical Details

- The SiteName domain mappings are fetched from the `Site` and `SiteDomain` tables in the database
- The mappings are displayed in a table format with columns for site name, domains, and actions
- All domains associated with a site are displayed in a compact list
- If a site has no associated domains, a message is displayed indicating that no domain is configured
- The "Manage DNS" button is disabled for sites that have no associated domains
- The first domain in the list is used as the primary domain for DNS management