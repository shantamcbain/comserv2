#!/bin/bash

# Script to set up the directory structure for the new documentation system

# Base directory
BASE_DIR="/home/shanta/PycharmProjects/comserv/Comserv/root/Documentation"

# Create main directories
mkdir -p "$BASE_DIR/docs/user"
mkdir -p "$BASE_DIR/docs/admin"
mkdir -p "$BASE_DIR/docs/developer"
mkdir -p "$BASE_DIR/docs/site/mcoop"
mkdir -p "$BASE_DIR/docs/module"
mkdir -p "$BASE_DIR/docs/changelog"
mkdir -p "$BASE_DIR/docs/templates"
mkdir -p "$BASE_DIR/templates/components"
mkdir -p "$BASE_DIR/templates/categories"
mkdir -p "$BASE_DIR/config"
mkdir -p "$BASE_DIR/assets"

echo "Directory structure created successfully!"
echo ""
echo "New structure:"
echo "- $BASE_DIR/docs/ (All documentation files)"
echo "  ├── user/ (User-related documentation)"
echo "  ├── admin/ (Admin-related documentation)"
echo "  ├── developer/ (Developer-related documentation)"
echo "  ├── site/ (Site-specific documentation)"
echo "  │   └── mcoop/ (MCOOP site documentation)"
echo "  ├── module/ (Module-specific documentation)"
echo "  ├── changelog/ (Changelog entries)"
echo "  └── templates/ (Documentation templates)"
echo "- $BASE_DIR/templates/ (Template files for documentation display)"
echo "  ├── components/ (Reusable template components)"
echo "  └── categories/ (Category-specific templates)"
echo "- $BASE_DIR/config/ (Configuration files)"
echo "- $BASE_DIR/assets/ (Documentation assets)"
echo ""
echo "Next steps:"
echo "1. Run the migration script to migrate existing documentation"
echo "2. Update the documentation controller to work with the new structure"
echo "3. Test the new documentation system"