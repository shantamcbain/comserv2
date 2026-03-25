#!/bin/bash

# Fix Production Deployment Script
# This script addresses the "Can't locate Comserv.pm" issue in production

echo "=== Comserv Production Deployment Fix ==="
echo "This script will help fix the missing Comserv.pm issue in production"
echo ""

# Define paths
PRODUCTION_PATH="/opt/comserv/Comserv"
DEV_PATH="/home/shanta/PycharmProjects/comserv2/Comserv"

echo "Production path: $PRODUCTION_PATH"
echo "Development path: $DEV_PATH"
echo ""

# Check if we're running this on the production server
if [ -d "$PRODUCTION_PATH" ]; then
    echo "✓ Production directory found: $PRODUCTION_PATH"
    
    # Check if lib directory exists
    if [ ! -d "$PRODUCTION_PATH/lib" ]; then
        echo "✗ Missing lib directory in production"
        echo "Creating lib directory..."
        mkdir -p "$PRODUCTION_PATH/lib"
        echo "✓ Created lib directory"
    else
        echo "✓ lib directory exists"
    fi
    
    # Check if Comserv.pm exists in lib
    if [ ! -f "$PRODUCTION_PATH/lib/Comserv.pm" ]; then
        echo "✗ Missing Comserv.pm in production lib directory"
        
        # Check if we have the development version available
        if [ -f "$DEV_PATH/lib/Comserv.pm" ]; then
            echo "✓ Found development version of Comserv.pm"
            echo "Copying Comserv.pm to production..."
            cp "$DEV_PATH/lib/Comserv.pm" "$PRODUCTION_PATH/lib/"
            echo "✓ Copied Comserv.pm to production"
        else
            echo "✗ Development version not found at $DEV_PATH/lib/Comserv.pm"
            echo "Please ensure the development environment is properly set up"
            exit 1
        fi
    else
        echo "✓ Comserv.pm exists in production lib directory"
    fi
    
    # Check if Comserv directory structure exists in lib
    if [ ! -d "$PRODUCTION_PATH/lib/Comserv" ]; then
        echo "✗ Missing Comserv module directory in production"
        echo "Creating Comserv module directory structure..."
        
        if [ -d "$DEV_PATH/lib/Comserv" ]; then
            echo "Copying entire Comserv module directory..."
            cp -r "$DEV_PATH/lib/Comserv" "$PRODUCTION_PATH/lib/"
            echo "✓ Copied Comserv module directory to production"
        else
            echo "✗ Development Comserv module directory not found"
            exit 1
        fi
    else
        echo "✓ Comserv module directory exists"
    fi
    
    # Check PSGI file
    if [ ! -f "$PRODUCTION_PATH/comserv.psgi" ]; then
        echo "✗ Missing comserv.psgi in production"
        
        if [ -f "$DEV_PATH/comserv.psgi" ]; then
            echo "Copying comserv.psgi to production..."
            cp "$DEV_PATH/comserv.psgi" "$PRODUCTION_PATH/"
            echo "✓ Copied comserv.psgi to production"
        else
            echo "✗ Development comserv.psgi not found"
            exit 1
        fi
    else
        echo "✓ comserv.psgi exists in production"
    fi
    
    # Set proper permissions
    echo "Setting proper permissions..."
    chown -R www-data:www-data "$PRODUCTION_PATH" 2>/dev/null || echo "Note: Could not set www-data ownership (may need sudo)"
    chmod -R 755 "$PRODUCTION_PATH"
    chmod 644 "$PRODUCTION_PATH/lib/Comserv.pm"
    chmod 755 "$PRODUCTION_PATH/comserv.psgi"
    echo "✓ Permissions set"
    
    # Test the PSGI file
    echo ""
    echo "Testing PSGI file syntax..."
    cd "$PRODUCTION_PATH"
    if perl -c comserv.psgi 2>/dev/null; then
        echo "✓ PSGI file syntax is OK"
    else
        echo "✗ PSGI file has syntax errors"
        echo "Running detailed syntax check..."
        perl -c comserv.psgi
        exit 1
    fi
    
    echo ""
    echo "=== Deployment Fix Complete ==="
    echo "The Comserv.pm module should now be available in production."
    echo "You can now restart Starman:"
    echo "  sudo systemctl restart starman"
    echo "  # or"
    echo "  sudo service starman restart"
    
else
    echo "✗ Production directory not found: $PRODUCTION_PATH"
    echo ""
    echo "This script should be run on the production server where Comserv is deployed."
    echo "If you're running this from a different location, please:"
    echo "1. Copy this script to the production server"
    echo "2. Copy the entire Comserv development directory to the production server"
    echo "3. Run this script on the production server"
    echo ""
    echo "Alternative manual steps:"
    echo "1. Ensure $PRODUCTION_PATH/lib/Comserv.pm exists"
    echo "2. Ensure $PRODUCTION_PATH/lib/Comserv/ directory exists with all modules"
    echo "3. Ensure $PRODUCTION_PATH/comserv.psgi exists"
    echo "4. Set proper permissions"
    echo "5. Restart Starman"
fi