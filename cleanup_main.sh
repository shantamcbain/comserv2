#!/bin/bash

# Cleanup script for main branch - remove malformed files

echo "Cleaning up malformed files in main branch..."

cd /home/shanta/PycharmProjects/comserv2

# Remove files with "Formatting title from:" prefix
find Comserv -name "Formatting title from*" -delete

# Remove files with "Added ... to ... category" pattern  
find Comserv -name "Added *" -delete

# Remove other malformed files
find Comserv -name "Categorized as *" -delete
find Comserv -name "Category *" -delete
find Comserv -name "Pages in *" -delete
find Comserv -name "Starting Documentation*" -delete

echo "Cleanup completed. Removed malformed files."
echo "Files remaining:"
find Comserv -maxdepth 1 -type f | wc -l