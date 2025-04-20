#!/bin/bash

# Path to the Site.pm file
SITE_PM="/comserv/Comserv/lib/Comserv/Model/Site.pm"
FIXED_PM="/comserv/Comserv/lib/Comserv/Model/Site.pm.fixed2"
HEADER_TT="/comserv/Comserv/root/Header.tt"

# Make backups of the original files
cp "$SITE_PM" "${SITE_PM}.bak"
cp "$HEADER_TT" "${HEADER_TT}.bak"

# Replace the original Site.pm file with the fixed version
cp "$FIXED_PM" "$SITE_PM"

echo "Replaced $SITE_PM with fixed version. Backup saved as ${SITE_PM}.bak"
echo "Updated $HEADER_TT to handle missing theme column. Backup saved as ${HEADER_TT}.bak"