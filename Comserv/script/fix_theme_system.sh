#!/bin/bash

# Make scripts executable
echo "Making scripts executable..."
chmod +x /comserv/Comserv/script/*.pl
chmod +x /comserv/Comserv/script/*.sh

# Generate theme CSS files
echo "Generating theme CSS files..."
cd /comserv/Comserv
perl script/generate_theme_css.pl

# Fix permissions on theme files
echo "Fixing permissions on theme files..."
chmod 664 /comserv/Comserv/root/static/config/theme_*.json
chmod -R 775 /comserv/Comserv/root/static/css/themes/

echo "Theme system fix complete!"