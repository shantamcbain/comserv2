---
title: API Credentials Documentation Fix
description: Fixed API credentials documentation routing and consolidated documentation files
roles: admin,developer
category: changelog
date: 2025-06-15
author: Shanta
---

# API Credentials Documentation Fix

**Date:** June 15, 2025  
**Author:** Shanta  
**Category:** Documentation

## Overview

Fixed issues with the API credentials documentation routing and consolidated duplicate documentation files.

## Changes Made

- Consolidated API credentials documentation from `/Documentation/admin/api_credentials.tt` into `/Documentation/api_credentials.tt`
- Updated all links in the ApiCredentials controller to point to the correct documentation path
- Enhanced the API credentials documentation with more detailed information about each service
- Added documentation for additional services: Proxmox, Stripe, Mailchimp, and Twilio
- Improved the documentation structure with better organization and navigation
- Added troubleshooting and best practices sections

## Why This Change Was Needed

Users were encountering a "Page not found" error when trying to access the API credentials documentation through the API Credentials management interface. This was due to a routing issue where links were pointing to `/Documentation/admin/api_credentials`, but the Documentation controller was not properly handling this path.

## Technical Details

The Documentation controller in Comserv is designed to look for documentation files directly under the Documentation directory or in specific subdirectories like "roles". The admin subdirectory was not being properly handled, causing the 404 errors.

Rather than modifying the controller routing logic, we chose to consolidate the documentation into a single file at the root Documentation directory, which is the standard location for documentation files in the system.

## Related Files

- `/Documentation/api_credentials.tt` - Updated main documentation file
- `/ApiCredentials/index.tt` - Updated links to point to the correct documentation path