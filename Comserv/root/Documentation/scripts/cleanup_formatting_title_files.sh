#!/bin/bash

# Script to clean up all documentation-related log files in the Comserv directory
# Created as part of the fix for the Documentation controller logging issue
# This script removes various log files that are accidentally created in the Comserv directory
# including "Formatted title result", "Categorized as controller", and other similar files

# Set the project root directory
PROJECT_ROOT="/home/shanta/PycharmProjects/comserv2"
LOG_DIR="$PROJECT_ROOT/Comserv/logs"
LOG_FILE="$LOG_DIR/cleanup_formatting_title_files.log"

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Log start of script
log_message "Starting cleanup of documentation-related log files"
log_message "Project root: $PROJECT_ROOT"

# Find all log-like files in the Comserv directory
log_message "Searching for files..."
FILES=$(find "$PROJECT_ROOT/Comserv" -maxdepth 1 -type f \
    -name "Formatting title from*" -o \
    -name "Formatted title result*" -o \
    -name "Categorized as controller*" -o \
    -name "Categorized as model*" -o \
    -name "Category*has*pages" -o \
    -name "Starting Documentation*" -o \
    -name "Documentation system initialized*" -o \
    -name "Added*to*category*")

# Count the number of files found
FILE_COUNT=$(echo "$FILES" | grep -v "^$" | wc -l)
log_message "Found $FILE_COUNT files to clean up"

# If no files found, exit
if [ "$FILE_COUNT" -eq 0 ]; then
    log_message "No files to clean up. Exiting."
    exit 0
fi

# Log the list of files to be removed
log_message "Files to be removed:"
echo "$FILES" | while read -r file; do
    if [ -n "$file" ]; then
        log_message "  - $(basename "$file")"
    fi
done

# Remove the files
log_message "Removing files..."
echo "$FILES" | while read -r file; do
    if [ -n "$file" ]; then
        if rm "$file"; then
            log_message "  - Removed: $(basename "$file")"
        else
            log_message "  - Failed to remove: $(basename "$file")"
        fi
    fi
done

# Log completion
log_message "Cleanup completed successfully"
log_message "See $LOG_FILE for details"

echo "Cleanup script completed. See $LOG_FILE for details."
